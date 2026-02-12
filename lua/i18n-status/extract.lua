---@class I18nStatusExtract
local M = {}

local core = require("i18n-status.core")
local hardcoded = require("i18n-status.hardcoded")
local key_write = require("i18n-status.key_write")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")

local EXTRACT_NS = vim.api.nvim_create_namespace("i18n-status-extract")
local EXTRACT_TRACK_NS = vim.api.nvim_create_namespace("i18n-status-extract-track")
local PREVIEW_MAX_LEN = 40

---@class I18nStatusExtractWindowState
---@field winid integer|nil
---@field cursor integer[]|nil
---@field view table|nil

---@param bufnr integer
---@return integer|nil
local function window_for_buf(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == bufnr then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---@param text string
---@return string
local function prompt_preview(text)
  local normalized = vim.trim((text or ""):gsub("%s+", " "))
  if normalized == "" then
    normalized = "<empty>"
  end
  if #normalized > PREVIEW_MAX_LEN then
    normalized = normalized:sub(1, PREVIEW_MAX_LEN - 3) .. "..."
  end
  return normalized:gsub('"', '\\"')
end

---@param item I18nStatusHardcodedItem
---@return string
local function prompt_for_item(item)
  local preview = prompt_preview(item.text)
  return string.format('Extract "%s" (%d:%d): ', preview, item.lnum + 1, item.col + 1)
end

---@param bufnr integer
local function clear_extract_highlight(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, EXTRACT_NS, 0, -1)
  end
end

---@param bufnr integer
local function clear_extract_tracking(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, EXTRACT_TRACK_NS, 0, -1)
  end
end

---@param bufnr integer
---@param item I18nStatusHardcodedItem
local function highlight_item(bufnr, item)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  clear_extract_highlight(bufnr)
  if item.end_lnum == item.lnum then
    vim.api.nvim_buf_add_highlight(bufnr, EXTRACT_NS, "Visual", item.lnum, item.col, item.end_col)
    return
  end
  vim.api.nvim_buf_add_highlight(bufnr, EXTRACT_NS, "Visual", item.lnum, item.col, -1)
  for row = item.lnum + 1, item.end_lnum - 1 do
    vim.api.nvim_buf_add_highlight(bufnr, EXTRACT_NS, "Visual", row, 0, -1)
  end
  vim.api.nvim_buf_add_highlight(bufnr, EXTRACT_NS, "Visual", item.end_lnum, 0, item.end_col)
end

---@param bufnr integer
---@return I18nStatusExtractWindowState
local function capture_window_state(bufnr)
  local winid = window_for_buf(bufnr)
  if not winid then
    return { winid = nil, cursor = nil, view = nil }
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local view = vim.api.nvim_win_call(winid, function()
    return vim.fn.winsaveview()
  end)
  return { winid = winid, cursor = cursor, view = view }
end

---@param state I18nStatusExtractWindowState
local function restore_window_state(state)
  if not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  if state.view then
    pcall(vim.api.nvim_win_call, state.winid, function()
      vim.fn.winrestview(state.view)
    end)
  end
  if state.cursor then
    pcall(vim.api.nvim_win_set_cursor, state.winid, state.cursor)
  end
end

---@param state I18nStatusExtractWindowState
---@param item I18nStatusHardcodedItem
local function focus_item(state, item)
  if not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local row = item.lnum + 1
  pcall(vim.api.nvim_win_set_cursor, state.winid, { row, item.col })
  pcall(vim.api.nvim_win_call, state.winid, function()
    local win_h = vim.api.nvim_win_get_height(state.winid)
    local view = vim.fn.winsaveview()
    view.topline = math.max(1, row - math.floor(win_h / 2))
    view.lnum = row
    view.col = item.col
    vim.fn.winrestview(view)
  end)
end

---@class I18nStatusExtractTrackedItem
---@field mark_id integer
---@field text string

---@param bufnr integer
---@param items I18nStatusHardcodedItem[]
---@return I18nStatusExtractTrackedItem[]
local function create_tracked_items(bufnr, items)
  local tracked = {}
  for _, item in ipairs(items) do
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, EXTRACT_TRACK_NS, item.lnum, item.col, {
      end_row = item.end_lnum,
      end_col = item.end_col,
    })
    table.insert(tracked, {
      mark_id = mark_id,
      text = item.text,
    })
  end
  return tracked
end

---@param bufnr integer
---@param mark_id integer
---@return I18nStatusHardcodedItem|nil
local function item_from_mark(bufnr, mark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, EXTRACT_TRACK_NS, mark_id, { details = true })
  if #mark < 3 then
    return nil
  end
  local details = mark[3]
  if type(details) ~= "table" or type(details.end_row) ~= "number" or type(details.end_col) ~= "number" then
    return nil
  end
  return {
    lnum = mark[1],
    col = mark[2],
    end_lnum = details.end_row,
    end_col = details.end_col,
    text = "",
    kind = "jsx_text",
  }
end

---@param key string
---@return string|nil namespace
---@return string|nil key_path
local function split_key(key)
  local namespace = key:match("^(.-):")
  local key_path = key:match("^[^:]+:(.+)$")
  if not namespace or namespace == "" or not key_path or key_path == "" then
    return nil, nil
  end
  return namespace, key_path
end

---@param key string
---@param default_ns string
---@return string|nil
---@return string|nil
local function normalize_key_input(key, default_ns)
  if not key or vim.trim(key) == "" then
    return nil, "empty key"
  end
  local trimmed = vim.trim(key)
  local colon_pos = trimmed:find(":")
  local second_colon = colon_pos and trimmed:find(":", colon_pos + 1)
  if second_colon then
    return nil, "key can only contain one ':' separator"
  end
  local full_key = trimmed
  if not colon_pos then
    if not default_ns or default_ns == "" then
      return nil, "namespace is required"
    end
    full_key = default_ns .. ":" .. trimmed
  end
  local namespace, key_path = split_key(full_key)
  if not namespace or not key_path then
    return nil, "invalid key format"
  end
  if key_path:match("^%.") or key_path:match("%.$") or key_path:match("%.%.") then
    return nil, "invalid key path"
  end
  if not namespace:match("^[%w_%-%.]+$") then
    return nil, "invalid namespace format"
  end
  if not key_path:match("^[%w_%-%.]+$") then
    return nil, "invalid key path format"
  end
  return full_key, nil
end

---@param value string
---@param separator string
---@return string|nil
local function ascii_slug(value, separator)
  local normalized = (value or ""):gsub("%$", "")
  for i = 1, #normalized do
    if normalized:byte(i) > 127 then
      return nil
    end
  end
  local parts = {}
  local lowered = normalized:lower()
  for token in lowered:gmatch("[a-z0-9]+") do
    table.insert(parts, token)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, separator)
end

---@param full_key string
---@param used table<string, boolean>
---@param separator string
---@return string
local function ensure_unique_key(full_key, used, separator)
  local resolved_separator = separator ~= "" and separator or "-"
  if not used[full_key] then
    return full_key
  end
  local namespace, key_path = split_key(full_key)
  if not namespace or not key_path then
    return full_key
  end
  local n = 0
  while true do
    local candidate = string.format("%s:%s%s%d", namespace, key_path, resolved_separator, n)
    if not used[candidate] then
      return candidate
    end
    n = n + 1
  end
end

---@param cache table|nil
---@return table<string, boolean>
local function collect_existing_keys(cache)
  local keys = {}
  if not cache or not cache.index then
    return keys
  end
  for _, entries in pairs(cache.index) do
    for key, _ in pairs(entries or {}) do
      if key ~= "__error__" then
        keys[key] = true
      end
    end
  end
  return keys
end

---@param bufnr integer
---@param item I18nStatusHardcodedItem
---@param fallback_ns string
---@param used_keys table<string, boolean>
---@param extract_cfg I18nStatusExtractConfig|nil
---@return string
local function suggest_key(bufnr, item, fallback_ns, used_keys, extract_cfg)
  local separator = ((extract_cfg and extract_cfg.key_separator) or "-")
  local ctx = scan.translation_context_at(bufnr, item.lnum, { fallback_namespace = fallback_ns })
  local namespace = ctx.namespace or fallback_ns or "common"
  local segment = ascii_slug(item.text, separator)
  if not segment then
    segment = "key"
  end
  local full_key = string.format("%s:%s", namespace, segment)
  return ensure_unique_key(full_key, used_keys, separator)
end

---@param bufnr integer
---@param summary table
---@param cfg I18nStatusConfig
local function finish(bufnr, summary, cfg)
  if summary.replaced > 0 then
    core.refresh(bufnr, cfg, 0, { force = true })
    core.refresh_all(cfg)
  end
  local message = string.format(
    "i18n-status extract: detected=%d replaced=%d skipped=%d failed=%d",
    summary.detected,
    summary.replaced,
    summary.skipped,
    summary.failed
  )
  local level = summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify(message, level)
end

---@param bufnr integer
---@param cfg I18nStatusConfig
---@param opts? { range?: { start_line?: integer, end_line?: integer } }
function M.run(bufnr, cfg, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local fallback_ns = resources.fallback_namespace(start_dir)
  local extract_cfg = (cfg and cfg.extract) or {}
  local items = hardcoded.extract(bufnr, {
    range = opts.range,
    min_length = extract_cfg.min_length,
    exclude_components = extract_cfg.exclude_components,
  })
  if #items == 0 then
    vim.notify("i18n-status extract: no hardcoded text found", vim.log.levels.INFO)
    return
  end

  local languages = cache and cache.languages or {}
  if #languages == 0 then
    vim.notify("i18n-status extract: no languages detected", vim.log.levels.WARN)
    return
  end

  local primary_lang = (cfg and cfg.primary_lang) or languages[1]
  local summary = {
    detected = #items,
    replaced = 0,
    skipped = 0,
    failed = 0,
  }
  local used_keys = collect_existing_keys(cache)
  local ordered = {}
  for _, item in ipairs(items) do
    table.insert(ordered, item)
  end
  table.sort(ordered, function(a, b)
    if a.lnum == b.lnum then
      return a.col < b.col
    end
    return a.lnum < b.lnum
  end)
  local tracked = create_tracked_items(bufnr, ordered)
  local win_state = capture_window_state(bufnr)

  local function cleanup_visual_state()
    clear_extract_highlight(bufnr)
    clear_extract_tracking(bufnr)
    restore_window_state(win_state)
  end

  local function run_loop(index)
    if index > #tracked then
      cleanup_visual_state()
      finish(bufnr, summary, cfg)
      return
    end

    local tracked_item = tracked[index]
    local item = item_from_mark(bufnr, tracked_item.mark_id)
    if not item then
      summary.failed = summary.failed + 1
      run_loop(index + 1)
      return
    end
    item.text = tracked_item.text

    local context = scan.translation_context_at(bufnr, item.lnum, { fallback_namespace = fallback_ns })
    local namespace = context.namespace or fallback_ns or "common"
    local t_func = context.t_func or "t"
    local suggested = suggest_key(bufnr, item, fallback_ns, used_keys, extract_cfg)
    focus_item(win_state, item)
    highlight_item(bufnr, item)
    local prompt = prompt_for_item(item)

    vim.ui.input({ prompt = prompt, default = suggested }, function(input)
      if input == nil or vim.trim(input) == "" then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.skipped = summary.skipped + 1
        run_loop(index + 1)
        return
      end

      local full_key, err = normalize_key_input(input, namespace)
      if not full_key then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.skipped = summary.skipped + 1
        vim.notify("i18n-status extract: " .. err, vim.log.levels.WARN)
        run_loop(index + 1)
        return
      end
      local separator = ((extract_cfg and extract_cfg.key_separator) or "-")
      full_key = ensure_unique_key(full_key, used_keys, separator)
      local key_ns, key_path = split_key(full_key)
      if not key_ns or not key_path then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.failed = summary.failed + 1
        run_loop(index + 1)
        return
      end

      local translations = {}
      for _, lang in ipairs(languages) do
        translations[lang] = lang == primary_lang and item.text or ""
      end

      local success_count, failed_langs =
        key_write.write_translations(key_ns, key_path, translations, start_dir, languages)
      if success_count == 0 then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.failed = summary.failed + 1
        run_loop(index + 1)
        return
      end

      local primary_failed = false
      for _, lang in ipairs(failed_langs) do
        if lang == primary_lang then
          primary_failed = true
          break
        end
      end
      if primary_failed then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.failed = summary.failed + 1
        run_loop(index + 1)
        return
      end

      local replacement = string.format('{%s("%s")}', t_func, full_key)
      local replaced, replace_err =
        pcall(vim.api.nvim_buf_set_text, bufnr, item.lnum, item.col, item.end_lnum, item.end_col, { replacement })
      if not replaced then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
        summary.failed = summary.failed + 1
        vim.notify(
          "i18n-status extract: failed to update buffer text (" .. tostring(replace_err) .. ")",
          vim.log.levels.WARN
        )
        run_loop(index + 1)
        return
      end
      pcall(vim.api.nvim_buf_del_extmark, bufnr, EXTRACT_TRACK_NS, tracked_item.mark_id)
      used_keys[full_key] = true
      if #failed_langs > 0 then
        summary.failed = summary.failed + 1
      end
      summary.replaced = summary.replaced + 1
      run_loop(index + 1)
    end)
  end

  local initial_context = scan.translation_context_at(bufnr, 0, { fallback_namespace = fallback_ns })
  if initial_context.has_any_hook then
    run_loop(1)
    return
  end

  vim.ui.input({ prompt = "No translation hook found in this file. Continue? (y/N): " }, function(answer)
    if not answer or answer:lower() ~= "y" then
      cleanup_visual_state()
      vim.notify("i18n-status extract: cancelled", vim.log.levels.INFO)
      return
    end
    run_loop(1)
  end)
end

return M
