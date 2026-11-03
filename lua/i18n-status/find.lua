---@class I18nStatusFind
local M = {}

local actions = require("i18n-status.actions")
local filetypes = require("i18n-status.filetypes")
local key_spelling = require("i18n-status.key_spelling")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")
local state = require("i18n-status.state")
local treesitter = require("i18n-status.treesitter")

local FIND_NS = vim.api.nvim_create_namespace("i18n-status-find")
local MAX_RESULTS = 200
local PREVIEW_WIDTH = 60

-- Lower scores sort first.
local SCORE_VALUE_EXACT = 0
local SCORE_VALUE_PARTIAL = 1
local SCORE_KEY = 2

---@class I18nStatusFindResult
---@field key string Canonical `namespace:path` key
---@field namespace string
---@field framework string|nil Framework of the resource that defines the key
---@field score integer
---@field match_lang string|nil Language whose value matched; nil when only the key name matched
---@field values table<string, string>
---@field files table<string, string>

---Unicode-aware lowercase text for case-insensitive matching.
---@param text string
---@return string
local function normalize(text)
  return vim.fn.tolower(vim.trim(text))
end

---@param value string
---@param width integer
---@return string
local function preview(value, width)
  local text = value:gsub("%s+", " ")
  if vim.fn.strdisplaywidth(text) > width then
    text = vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

---Search keys whose name or translated value contains `query` (case-insensitive).
---Exact value matches rank first, then partial value matches, then key name matches. Within a rank,
---matches in the primary language come first, then keys in alphabetical order.
---@param cache I18nStatusCache
---@param query string
---@param primary_lang string|nil
---@return I18nStatusFindResult[]
function M.search(cache, query, primary_lang)
  local needle = normalize(query or "")
  if needle == "" then
    return {}
  end

  ---@type table<string, I18nStatusFindResult>
  local by_key = {}
  local languages = vim.deepcopy(cache.languages or {})
  table.sort(languages, function(a, b)
    if (a == primary_lang) ~= (b == primary_lang) then
      return a == primary_lang
    end
    return a < b
  end)

  for _, lang in ipairs(languages) do
    for key, entry in pairs((cache.index or {})[lang] or {}) do
      if key ~= "__error__" then
        local result = by_key[key]
        if not result then
          result = {
            key = key,
            namespace = key:match("^(.-):") or "",
            framework = entry.framework,
            score = math.huge,
            match_lang = nil,
            values = {},
            files = {},
          }
          by_key[key] = result
        end
        local value = type(entry.value) == "string" and entry.value or nil
        result.values[lang] = value
        result.files[lang] = entry.file
        if value then
          local normalized = normalize(value)
          local score = normalized == needle and SCORE_VALUE_EXACT
            or (normalized:find(needle, 1, true) and SCORE_VALUE_PARTIAL)
            or nil
          -- Languages are visited primary first, so ties keep the primary match.
          if score and score < result.score then
            result.score = score
            result.match_lang = lang
          end
        end
      end
    end
  end

  local results = {}
  for key, result in pairs(by_key) do
    if result.score > SCORE_KEY and vim.fn.tolower(key):find(needle, 1, true) then
      result.score = SCORE_KEY
    end
    if result.score <= SCORE_KEY then
      results[#results + 1] = result
    end
  end
  table.sort(results, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    local a_primary = a.match_lang == primary_lang
    local b_primary = b.match_lang == primary_lang
    if a_primary ~= b_primary then
      return a_primary
    end
    return a.key < b.key
  end)
  return results
end

---@param result I18nStatusFindResult
---@param primary_lang string|nil
---@return string
function M.format_result(result, primary_lang)
  local parts = { result.key }
  local primary_value = primary_lang and result.values[primary_lang]
  parts[#parts + 1] =
    string.format("%s: %s", primary_lang or "?", primary_value and preview(primary_value, PREVIEW_WIDTH) or "(missing)")
  if result.match_lang and result.match_lang ~= primary_lang then
    parts[#parts + 1] =
      string.format("%s: %s", result.match_lang, preview(result.values[result.match_lang], PREVIEW_WIDTH))
  end
  return table.concat(parts, "  │  ")
end

---@param value string
---@param quote string
---@return string
local function escape_for_quote(value, quote)
  local escaped = value:gsub("\\", "\\\\"):gsub(quote, "\\" .. quote)
  if quote == "`" then
    escaped = escaped:gsub("%${", "\\${")
  end
  return escaped
end

---@class I18nStatusFindTarget
---@field bufnr integer
---@field win integer
---@field mark integer

---@param target I18nStatusFindTarget
local function release_target(target)
  if vim.api.nvim_buf_is_valid(target.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, target.bufnr, FIND_NS, target.mark)
  end
end

---@param bufnr integer
---@return boolean
local function can_insert(bufnr)
  return filetypes.is_source_filetype(vim.bo[bufnr].filetype) and vim.bo[bufnr].modifiable
end

---@param a_row integer
---@param a_col integer
---@param b_row integer
---@param b_col integer
---@return boolean
local function before_or_at(a_row, a_col, b_row, b_col)
  return a_row < b_row or (a_row == b_row and a_col <= b_col)
end

---Direct string literal passed as the first argument of a translation call, when the cursor is
---between its quotes (or on the closing quote).
---@param bufnr integer
---@param row integer
---@param col integer
---@return table|nil
local function literal_at(bufnr, row, col)
  for _, item in ipairs(scan.extract(bufnr)) do
    if
      item.refactorable
      and not before_or_at(row, col, item.lnum, item.col)
      and before_or_at(row, col, item.end_lnum, item.end_col - 1)
    then
      return item
    end
  end
  return nil
end

---Quote of the string literal around (row, col), read from the buffer's Tree-sitter tree so that
---strings opened on earlier lines count. Without a parser only the line text is checked.
---@param bufnr integer
---@param row integer
---@param col integer
---@param before string Line text up to the cursor
---@return string|nil
local function quote_at(bufnr, row, col, before)
  local lang = treesitter.parser_lang_for_filetype(vim.bo[bufnr].filetype)
  local parser = lang and treesitter.has_parser(lang) and vim.treesitter.get_parser(bufnr, lang, { error = false })
  if not parser then
    return key_spelling.open_quote_at(before)
  end
  parser:parse()
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = true })
  while node do
    local node_type = node:type()
    if node_type == "template_substitution" then
      return nil
    end
    if node_type == "string" or node_type == "template_string" then
      local start_row, start_col, end_row, end_col = node:range()
      local after_open = not before_or_at(row, col, start_row, start_col)
      local before_close = before_or_at(row, col, end_row, end_col - 1)
      if not (after_open and before_close) then
        return nil
      end
      return node_type == "template_string" and "`" or vim.treesitter.get_node_text(node, bufnr):sub(1, 1)
    end
    node = node:parent()
  end
  return nil
end

---@param key string
---@param spelling I18nStatusKeySpelling|nil
---@param spelling_err string|nil
---@return string|nil
---@return string|nil error
local function spell(key, spelling, spelling_err)
  if not spelling then
    return nil, spelling_err
  end
  return key_spelling.source_key(spelling, key, { qualify_other_namespaces = true })
end

---Insert `result.key` at the tracked cursor position, spelled for the translator that owns it.
---Inside the string literal argument of a translation call the string contents are replaced.
---Inside another string only the key is inserted. Elsewhere a call to the translator in scope is
---inserted, or the key's full path when none is in scope.
---@param target I18nStatusFindTarget
---@param result I18nStatusFindResult
---@return boolean
---@return string|nil error
function M.insert(target, result)
  local bufnr = target.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) or not can_insert(bufnr) then
    return false, "the source buffer is no longer editable"
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, FIND_NS, target.mark, {})
  if not ok or type(pos) ~= "table" or #pos < 2 then
    return false, "the insert position is no longer available"
  end
  local row, col = pos[1], pos[2]
  local hint, reason = resources.namespace_hint(resources.start_dir(bufnr))
  local fallback_ns = reason == "single" and hint or nil

  local start_row, start_col, end_row, end_col = row, col, row, col
  local text, err
  local literal = literal_at(bufnr, row, col)
  if literal then
    start_row, start_col = literal.lnum, literal.col + 1
    end_row, end_col = literal.end_lnum, literal.end_col - 1
    local quote = vim.api.nvim_buf_get_text(bufnr, literal.lnum, literal.col, literal.lnum, start_col, {})[1]
    text, err = spell(result.key, key_spelling.for_item(literal, fallback_ns))
    text = text and escape_for_quote(text, quote)
  else
    local before = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):sub(1, col)
    -- The scanner misses calls in source that does not parse yet, such as an unclosed `t("`.
    local arg = key_spelling.translation_arg_at(before)
    local quote = arg and arg.quote or quote_at(bufnr, row, col, before)
    local context = (arg or not quote)
      and scan.translation_context_at(bufnr, row, {
        fallback_namespace = fallback_ns,
        col = col,
        callee = arg and "t" or nil,
        member_call = arg and arg.member_call or false,
      })
    if context and context.shadowed then
      return false, "the translation function at the cursor is shadowed"
    end
    local translator = context and not context.ambiguous and context.found_hook and context.t_func or nil
    if arg then
      -- Replace what was typed after the opening quote.
      start_col = arg.quote_col + 1
      text, err = spell(result.key, key_spelling.for_context(context, fallback_ns))
      text = text and escape_for_quote(text, quote)
    elseif quote then
      text = escape_for_quote(key_spelling.root_key(result.key, result.framework), quote)
    elseif translator then
      text, err = spell(result.key, key_spelling.for_context(context, fallback_ns))
      text = text and string.format('%s("%s")', translator, escape_for_quote(text, '"'))
    else
      text = key_spelling.root_key(result.key, result.framework)
    end
  end
  if not text then
    return false, err
  end

  vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, { text })
  if vim.api.nvim_win_is_valid(target.win) and vim.api.nvim_win_get_buf(target.win) == bufnr then
    pcall(vim.api.nvim_win_set_cursor, target.win, { start_row + 1, start_col + #text })
  end
  return true, nil
end

---@param result I18nStatusFindResult
---@return boolean
function M.open(result)
  local values = {}
  for lang, file in pairs(result.files) do
    values[lang] = { value = result.values[lang], file = file }
  end
  return actions.jump_to_definition({ key = result.key, hover = { values = values } }, { lang = result.match_lang })
end

---@class I18nStatusFindOptions
---@field query string|nil Search text; prompts when empty
---@field action 'insert'|'open'|nil Defaults to insert in editable source buffers and open elsewhere

---@param bufnr integer
---@param opts I18nStatusFindOptions|nil
function M.run(bufnr, opts)
  opts = opts or {}
  local query = opts.query and vim.trim(opts.query) or ""
  if query == "" then
    vim.ui.input({ prompt = "Find translation: " }, function(input)
      if input and vim.trim(input) ~= "" then
        M.run(bufnr, vim.tbl_extend("force", opts, { query = input }))
      end
    end)
    return
  end

  local action = opts.action or (can_insert(bufnr) and "insert" or "open")
  if action == "insert" and not can_insert(bufnr) then
    vim.notify("i18n-status find: keys can only be inserted into editable JS/TS buffers", vim.log.levels.WARN)
    return
  end

  local cache = resources.ensure_index(resources.start_dir(bufnr))
  local project = state.set_languages(cache.key, cache.languages)
  local primary = (project and project.primary_lang) or (cache.languages or {})[1]
  local results = M.search(cache, query, primary)
  if #results == 0 then
    vim.notify(string.format("i18n-status find: no keys match '%s'", query), vim.log.levels.INFO)
    return
  end
  if #results > MAX_RESULTS then
    vim.notify(
      string.format("i18n-status find: showing the first %d of %d matches", MAX_RESULTS, #results),
      vim.log.levels.INFO
    )
    results = vim.list_slice(results, 1, MAX_RESULTS)
  end

  ---@type I18nStatusFindTarget|nil
  local target = nil
  if action == "insert" then
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    target = {
      bufnr = bufnr,
      win = win,
      mark = vim.api.nvim_buf_set_extmark(bufnr, FIND_NS, cursor[1] - 1, cursor[2], {}),
    }
  end

  vim.ui.select(results, {
    prompt = string.format("i18n keys matching '%s'", query),
    kind = "i18n-status.find",
    format_item = function(result)
      return M.format_result(result, primary)
    end,
  }, function(choice)
    if not choice then
      if target then
        release_target(target)
      end
      return
    end
    if not target then
      M.open(choice)
      return
    end
    local inserted, err = M.insert(target, choice)
    release_target(target)
    if not inserted then
      vim.notify("i18n-status find: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

return M
