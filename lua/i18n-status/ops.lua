---@class I18nStatusOps
local M = {}

local util = require("i18n-status.util")
local resources = require("i18n-status.resources")
local state = require("i18n-status.state")
local core = require("i18n-status.core")
local scan = require("i18n-status.scan")

---@param bufnr integer
---@return string[]
local function rpc_scan_extract(bufnr, fallback_ns)
  return scan.extract(bufnr, {
    fallback_namespace = fallback_ns,
  })
end

---@param bufnr integer
---@return boolean
local function is_target_rename_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" and buftype ~= "nofile" then
    return false
  end
  if not vim.bo[bufnr].modifiable then
    return false
  end
  return util.is_source_filetype(vim.bo[bufnr].filetype)
end

---@param tbl table
---@param key_path string
---@return any
local function get_nested(tbl, key_path)
  local parts = vim.split(key_path, ".", { plain = true })
  local cur = tbl
  for _, key in ipairs(parts) do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[key]
  end
  return cur
end

---@param tbl table
---@param key_path string
---@return boolean
local function delete_nested(tbl, key_path)
  local parts = vim.split(key_path, ".", { plain = true })
  local cur = tbl
  for i = 1, #parts - 1 do
    local key = parts[i]
    if type(cur[key]) ~= "table" then
      return false
    end
    cur = cur[key]
  end
  if cur[parts[#parts]] == nil then
    return false
  end
  cur[parts[#parts]] = nil
  return true
end

---@param input string
---@param fallback_ns string
---@return string, string, string, boolean
local function normalize_key(input, fallback_ns)
  local key = vim.trim(input)
  local ns = key:match("^(.-):")
  local explicit_ns = ns ~= nil
  if not ns then
    ns = fallback_ns
    key = ns .. ":" .. key
  end
  local key_path = key:match("^[^:]+:(.+)$") or ""
  return key, ns, key_path, explicit_ns
end

---@param bufnr integer
---@param old_key string
---@param new_key string
---@param new_ns string
---@param explicit_ns boolean
---@param fallback_ns string
---@return string[] edit_errors
local function rename_in_buffer(bufnr, old_key, new_key, new_ns, explicit_ns, fallback_ns)
  local items = rpc_scan_extract(bufnr, fallback_ns)
  local edits = {}
  local edit_errors = {}
  for _, item in ipairs(items) do
    if item.key == old_key then
      local new_raw = new_key
      if not item.raw:find(":", 1, true) then
        if explicit_ns and item.namespace ~= new_ns then
          new_raw = new_key
        else
          new_raw = new_key:match("^[^:]+:(.+)$") or new_key
        end
      end
      table.insert(edits, {
        lnum = item.lnum,
        col = item.col,
        end_col = item.end_col,
        new_raw = new_raw,
      })
    end
  end
  table.sort(edits, function(a, b)
    if a.lnum == b.lnum then
      return a.col > b.col
    end
    return a.lnum > b.lnum
  end)
  for _, edit in ipairs(edits) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local quote = '"'
      local ok_old, old_chunks =
        pcall(vim.api.nvim_buf_get_text, bufnr, edit.lnum, edit.col, edit.lnum, edit.end_col, {})
      if ok_old and type(old_chunks) == "table" then
        local old_text = old_chunks[1] or ""
        local old_quote = old_text:sub(1, 1)
        if old_quote == '"' or old_quote == "'" or old_quote == "`" then
          quote = old_quote
        end
      end
      local new_text = quote .. edit.new_raw .. quote
      local ok_set, set_err =
        pcall(vim.api.nvim_buf_set_text, bufnr, edit.lnum, edit.col, edit.lnum, edit.end_col, { new_text })
      if not ok_set then
        table.insert(
          edit_errors,
          string.format("buf=%d line=%d col=%d error=%s", bufnr, edit.lnum + 1, edit.col + 1, tostring(set_err))
        )
      end
    end
  end
  return edit_errors
end

---@param cache table|nil
---@param project I18nStatusProjectState|nil
---@return string[]
local function active_languages(cache, project)
  local langs = {}
  if cache and cache.languages then
    for _, lang in ipairs(cache.languages) do
      table.insert(langs, lang)
    end
  end
  if #langs == 0 and project and project.primary_lang then
    table.insert(langs, project.primary_lang)
  end
  return langs
end

---@param errors string[]
---@return string
local function summarize_edit_errors(errors)
  local max_count = 3
  local count = math.min(#errors, max_count)
  local summary = {}
  for i = 1, count do
    summary[#summary + 1] = errors[i]
  end
  if #errors > max_count then
    summary[#summary + 1] = string.format("+%d more", #errors - max_count)
  end
  return table.concat(summary, "; ")
end

---@param opts { item: I18nStatusResolved, source_buf?: integer, new_key: string, config: I18nStatusConfig }
---@return boolean, string?
function M.rename(opts)
  if not opts or not opts.item or not opts.new_key or not opts.config then
    return false, "invalid arguments"
  end

  local item = opts.item
  local source_buf = opts.source_buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(source_buf) then
    return false, "source buffer is invalid"
  end

  -- Prevent renaming missing keys
  if item.status == "×" then
    return false, "Primary language definition not found"
  end

  local fallback_ns = item.namespace or resources.fallback_namespace_for_buf(source_buf)
  local old_key = item.key
  local new_key_input = vim.trim(opts.new_key)
  if new_key_input == "" then
    return false, "new key is empty"
  end

  local new_key, new_ns, new_path, explicit_ns = normalize_key(new_key_input, fallback_ns)
  if new_key == old_key then
    return true
  end

  local old_ns = old_key:match("^(.-):") or fallback_ns
  local old_path = old_key:match("^[^:]+:(.+)$") or ""
  local root = resources.start_dir(source_buf)
  local cache = resources.ensure_index(root)
  local base_dir = resources.project_root(root, cache.roots)
  if not base_dir or base_dir == "" then
    base_dir = root
  end
  local project = state.set_languages(cache.key, cache.languages)
  state.set_buf_project(source_buf, cache.key)
  local langs = active_languages(cache, project)
  if #langs == 0 then
    return false, "no languages detected"
  end

  local file_cache = {}

  local function file_state(path)
    if not file_cache[path] then
      local data, style = resources.read_json_table(path)
      if not data then
        return nil, style.error or "unknown"
      end
      file_cache[path] = { data = data, style = style, dirty = false }
    end
    return file_cache[path]
  end

  ---@param path string
  ---@param lang string
  ---@return string|nil
  ---@return string|nil
  local function sanitize_resource_path(path, lang)
    local sanitized_path, sanitize_err = util.sanitize_path(path, base_dir)
    if not sanitized_path then
      return nil,
        string.format(
          "resource path for language '%s' is outside project root: %s",
          lang,
          sanitize_err or "unknown"
        )
    end
    return sanitized_path, nil
  end

  for _, lang in ipairs(langs) do
    local info = item.hover and item.hover.values and item.hover.values[lang]
    local old_file_raw = (info and info.file) or resources.namespace_path(root, lang, old_ns)
    if not old_file_raw then
      return false,
        string.format(
          "Cannot find resource file for language '%s'. Expected file in namespace '%s'. "
            .. "Please check your i18n configuration and ensure resource files exist.",
          lang,
          old_ns or "default"
        )
    end
    local old_file, old_file_err = sanitize_resource_path(old_file_raw, lang)
    if not old_file then
      return false, old_file_err
    end
    local old_is_root = resources.is_next_intl_root_file(root, lang, old_file)
    local new_file_raw = old_is_root and old_file or resources.namespace_path(root, lang, new_ns)
    if not new_file_raw then
      return false,
        string.format(
          "Cannot find resource file for language '%s'. Expected file in namespace '%s'. "
            .. "Please check your i18n configuration and ensure resource files exist.",
          lang,
          new_ns or "default"
        )
    end
    local new_file, new_file_err = sanitize_resource_path(new_file_raw, lang)
    if not new_file then
      return false, new_file_err
    end
    local same_file = util.normalize_path(old_file, root) == util.normalize_path(new_file, root)

    util.ensure_dir(util.dirname(new_file))

    local old_state, old_err = file_state(old_file)
    if not old_state then
      return false,
        string.format(
          "Failed to parse JSON file '%s': %s. "
            .. "The file may contain syntax errors. Please validate the JSON syntax.",
          old_file,
          old_err
        )
    end
    local new_state = old_state
    if not same_file then
      local state_new, new_err = file_state(new_file)
      if not state_new then
        return false,
          string.format(
            "Failed to parse JSON file '%s': %s. "
              .. "The file may contain syntax errors. Please validate the JSON syntax.",
            new_file,
            new_err
          )
      end
      new_state = state_new
    end

    local old_path_in_file = resources.key_path_for_file(old_ns, old_path, root, lang, old_file)
    local new_path_in_file = resources.key_path_for_file(new_ns, new_path, root, lang, new_file)

    local old_value_from_data = get_nested(old_state.data, old_path_in_file)
    local old_value = old_value_from_data
    if old_value == nil and info and not info.missing then
      old_value = info.value
    end
    local should_create = old_value_from_data ~= nil or (info and not info.missing and info.value ~= nil)
    if should_create then
      local existing = get_nested(new_state.data, new_path_in_file)
      if existing ~= nil then
        return false, "target key already exists (" .. lang .. ")"
      end
    end

    if should_create then
      if old_value == nil then
        old_value = ""
      end
      util.set_nested(new_state.data, new_path_in_file, old_value)
      new_state.dirty = true
    end
    if same_file then
      if delete_nested(new_state.data, old_path_in_file) then
        new_state.dirty = true
      end
    else
      if delete_nested(old_state.data, old_path_in_file) then
        old_state.dirty = true
      end
    end
  end

  for path, entry in pairs(file_cache) do
    if entry.dirty then
      util.ensure_dir(util.dirname(path))
      local write_ok, write_err = resources.write_json_table(path, entry.data, entry.style, { start_dir = root })
      if not write_ok then
        return false, string.format("failed to write %s: %s", path, write_err or "unknown")
      end
    end
  end

  local updated_bufs = {}
  local buffer_edit_errors = {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_target_rename_buf(buf) then
      local fb = resources.fallback_namespace_for_buf(buf)
      local edit_errors = rename_in_buffer(buf, old_key, new_key, new_ns, explicit_ns, fb)
      for _, edit_err in ipairs(edit_errors) do
        table.insert(buffer_edit_errors, edit_err)
      end
      table.insert(updated_bufs, buf)
    end
  end

  for _, buf in ipairs(updated_bufs) do
    core.refresh_now(buf, opts.config)
  end

  if #buffer_edit_errors > 0 then
    return false,
      "resource files were renamed, but failed to update some open buffers: " .. summarize_edit_errors(
        buffer_edit_errors
      )
  end

  return true
end

return M
