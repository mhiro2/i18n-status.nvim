---@class I18nStatusBlinkSource
---@field private config table|nil
local Source = {}
Source.__index = Source

---@class I18nStatusBlinkCompat
local M = {}

local next_intl_key = require("i18n-status.next_intl_key")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")
local state = require("i18n-status.state")

local SUPPORTED_FILETYPES = {
  javascript = true,
  typescript = true,
  javascriptreact = true,
  typescriptreact = true,
}

---@param key string
---@param value string|nil
---@return boolean
local function is_missing_value(key, value)
  if value == nil or value == "" then
    return true
  end
  if value == key then
    return true
  end
  local key_path = key:match("^[^:]+:(.+)$")
  if key_path and value == key_path then
    return true
  end
  return false
end

---@class I18nStatusCompletionArg
---@field prefix string Text typed inside the string literal before the cursor
---@field member_call boolean Whether the translator is called as a member (`i18n.t(...)`)

---Find the translation call whose first string argument contains the end of `before`, the line
---text up to the cursor. Strings, template interpolations, and comments are tracked so that `t(`
---inside strings or comments, closed arguments such as `t("a") + "`, and calls like
---`axios.get("` do not count. Quotes directly after a word (`Don't` in JSX text) and `//` after a
---URL scheme are text, not delimiters.
---@param before string
---@return I18nStatusCompletionArg|nil
local function translation_arg_at(before)
  local quote, quote_start = nil, nil
  ---@type boolean|nil Member flag of a `t(` that is still waiting for its first argument
  local pending = nil
  ---@type boolean|nil Member flag of the call whose first argument is the open string
  local arg_member = nil
  -- Brace depth of the code and, per open `${`, the depth at which its template resumes.
  local depth = 0
  local templates = {}
  local i, n = 1, #before
  while i <= n do
    local c = before:sub(i, i)
    local prev = i > 1 and before:sub(i - 1, i - 1) or ""
    if quote then
      if c == "\\" then
        i = i + 1
      elseif c == quote then
        quote, arg_member = nil, nil
      elseif quote == "`" and before:sub(i, i + 1) == "${" then
        quote, arg_member, pending = nil, nil, nil
        depth = depth + 1
        templates[#templates + 1] = depth
        i = i + 1
      end
    elseif before:sub(i, i + 1) == "//" and not before:sub(1, i - 1):match("%a:$") then
      return nil
    elseif before:sub(i, i + 1) == "/*" then
      local close = before:find("*/", i + 2, true)
      if not close then
        return nil
      end
      i = close + 1
    elseif c == "`" or ((c == '"' or c == "'") and not prev:match("[%w_$]")) then
      quote, quote_start = c, i
      arg_member, pending = pending, nil
    elseif c == "}" and templates[#templates] == depth then
      templates[#templates] = nil
      depth = depth - 1
      quote, arg_member, pending = "`", nil, nil
    else
      local call_end = c == "t" and not prev:match("[%w_$]") and select(2, before:find("^t%s*%(", i))
      if call_end then
        pending = prev == "."
        i = call_end
      elseif not c:match("%s") then
        pending = nil
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
        end
      end
    end
    i = i + 1
  end
  if not quote or arg_member == nil then
    return nil
  end
  return { prefix = before:sub(quote_start + 1), member_call = arg_member }
end

---@param ctx table|nil
---@return integer, integer, string
local function current_position(ctx)
  local row, col
  if ctx and ctx.cursor then
    if type(ctx.cursor) == "number" then
      col = ctx.cursor
    elseif type(ctx.cursor) == "table" then
      row = ctx.cursor[1] or ctx.cursor.row
      col = ctx.cursor[2] or ctx.cursor.col
    end
  end
  if not row or not col then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row = row or cursor[1]
    col = col or cursor[2]
  end
  local line = (ctx and type(ctx.line) == "string") and ctx.line or vim.api.nvim_get_current_line()
  return row - 1, col, line
end

---Locate the translation argument being completed. A missing context (manual invocation) completes
---every key without a translation call.
---@param ctx table|nil
---@return boolean complete
---@return I18nStatusCompletionArg|nil arg
local function completion_target(ctx)
  if not ctx or next(ctx) == nil then
    return true, nil
  end
  local _, col, line = current_position(ctx)
  local arg = translation_arg_at(line:sub(1, col))
  return arg ~= nil, arg
end

local MAX_COMPLETION_ITEMS = 100

---@param ctx table|nil
---@return table[] items
---@return boolean truncated true when matching keys were left out by the item limit
---@return boolean filtered true when keys were filtered by the typed text
local function get_completion_items(ctx)
  local complete, arg = completion_target(ctx)
  if not complete then
    return {}, false, false
  end

  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local project = state.set_languages(cache.key, cache.languages)
  state.set_buf_project(bufnr, cache.key)
  local primary = (project and project.primary_lang) or cache.languages[1]
  local entries = cache.index[primary] or {}
  local prefix = arg and arg.prefix or ""
  local explicit_ns = false
  local ns = nil
  ---@type { namespace: string|nil }|nil
  local next_intl_translator = nil

  if arg then
    local row, col = current_position(ctx)
    local hint, reason = resources.namespace_hint(start_dir)
    local fallback_ns = reason == "single" and hint or nil
    local ctx_result = scan.translation_context_at(bufnr, row, {
      fallback_namespace = fallback_ns,
      col = col,
      callee = "t",
      member_call = arg.member_call,
    })
    if ctx_result.shadowed then
      return {}, false, false
    end
    local policy = ctx_result.source_key_policy
    if prefix:find(":", 1, true) then
      ns = prefix:match("^(.-):")
      explicit_ns = true
    elseif
      ctx_result.found_hook
      and ctx_result.framework == "next_intl"
      and (policy == "namespace_relative" or policy == "canonical")
    then
      next_intl_translator = { namespace = policy == "namespace_relative" and ctx_result.namespace or nil }
    else
      ns = ctx_result.found_hook and ctx_result.namespace or fallback_ns
    end
  end

  local function build_documentation(key)
    local lines = {}
    local primary_entry = entries[key]
    local primary_value = primary_entry and primary_entry.value or nil
    local primary_text = is_missing_value(key, primary_value) and "(missing)" or tostring(primary_value)
    table.insert(lines, primary .. ": " .. primary_text)
    for _, lang in ipairs(cache.languages or {}) do
      if lang ~= primary then
        local lang_entry = (cache.index[lang] or {})[key]
        local value = lang_entry and lang_entry.value or nil
        local text = is_missing_value(key, value) and "(missing)" or tostring(value)
        table.insert(lines, lang .. ": " .. text)
      end
    end
    return table.concat(lines, "\n")
  end

  ---@param key string
  ---@return string|nil
  local function source_key_for(key)
    if next_intl_translator then
      return (next_intl_key.source_key(next_intl_translator.namespace, key))
    end
    if ns and key:sub(1, #ns + 1) ~= ns .. ":" then
      return nil
    end
    if ns and not explicit_ns then
      return key:match("^[^:]+:(.+)$") or key
    end
    return key
  end

  -- Collect every key matching the typed text before applying the limit, so the kept items do
  -- not depend on table iteration order.
  local needle = prefix:lower()
  local candidates = {}
  for key, entry in pairs(entries) do
    local insert_key = key ~= "__error__" and source_key_for(key) or nil
    if insert_key and insert_key:lower():find(needle, 1, true) then
      candidates[#candidates + 1] = {
        key = key,
        insert_key = insert_key,
        sort_text = (is_missing_value(key, entry.value) and "0" or "1") .. key,
      }
    end
  end
  table.sort(candidates, function(a, b)
    return a.sort_text < b.sort_text
  end)

  local items = {}
  for index = 1, math.min(#candidates, MAX_COMPLETION_ITEMS) do
    local candidate = candidates[index]
    items[index] = {
      label = candidate.insert_key,
      insertText = candidate.insert_key,
      sortText = candidate.sort_text,
      kind = vim.lsp.protocol.CompletionItemKind.Text,
      documentation = build_documentation(candidate.key),
      detail = "🌐 " .. candidate.key,
      labelDetails = { description = "i18n" },
    }
  end
  return items, #candidates > MAX_COMPLETION_ITEMS, needle ~= ""
end

-- Backwards compatible: nvim-cmp style completion
---@param ctx table
---@param callback fun(items: table[])
function M.complete(ctx, callback)
  callback((get_completion_items(ctx)))
end

-- BLINK.CMP SOURCE PROTOCOL IMPLEMENTATION

---@param config table|nil
---@return I18nStatusBlinkSource
function Source.new(config)
  local self = setmetatable({}, Source)
  self.config = config or {}
  return self
end

---@param ctx table
---@param callback fun(items: table[])
function Source:complete(ctx, callback)
  callback((get_completion_items(ctx)))
end

---@param ctx table
---@param callback fun(response: table|nil)
function Source:get_completions(ctx, callback)
  local items, truncated, filtered = get_completion_items(ctx)
  -- Typing more only narrows the matches, which a complete list already holds; deleting typed
  -- text can match keys that the current filter left out.
  callback({
    items = items,
    is_incomplete_forward = truncated,
    is_incomplete_backward = truncated or filtered,
  })
end

---@return string[]
function Source:get_trigger_characters()
  return { '"', "'", "`", ":" }
end

---@return boolean
function Source:enabled()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  return SUPPORTED_FILETYPES[ft] == true
end

---@param ctx table
---@return boolean
function Source:is_available(ctx)
  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if not SUPPORTED_FILETYPES[ft] then
    return false
  end
  local row, col, line = current_position(ctx or {})
  return (completion_target({ cursor = { row, col }, line = line }))
end

---@param _ctx table
---@param _item table
---@param callback fun()
---@param default_implementation fun()
function Source:execute(_ctx, _item, callback, default_implementation)
  -- No special execution needed for i18n keys
  if default_implementation then
    default_implementation()
  end
  callback()
end

-- Export both old style (M) and new style (Source)
M.Source = Source
M.new = Source.new

return M
