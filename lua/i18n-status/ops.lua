---@class I18nStatusOps
local M = {}

local filetypes = require("i18n-status.filetypes")
local fs = require("i18n-status.fs")
local json = require("i18n-status.json")
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
  return filetypes.is_source_filetype(vim.bo[bufnr].filetype)
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
---@return string|nil key
---@return string|nil namespace
---@return string|nil key_path
---@return boolean explicit_namespace
---@return string|nil error
local function normalize_key(input, fallback_ns)
  local key = vim.trim(input)
  local first_colon = key:find(":", 1, true)
  if first_colon and key:find(":", first_colon + 1, true) then
    return nil, nil, nil, false, "new key can only contain one ':' separator"
  end

  local explicit_ns = first_colon ~= nil
  local ns = explicit_ns and key:sub(1, first_colon - 1) or fallback_ns
  local key_path = explicit_ns and key:sub(first_colon + 1) or key
  if not ns or ns == "" then
    return nil, nil, nil, explicit_ns, "namespace is empty"
  end
  if key_path == "" or key_path:match("^%.") or key_path:match("%.$") or key_path:match("%.%.") then
    return nil, nil, nil, explicit_ns, "invalid key path"
  end
  if not ns:match("^[%w_%-%.]+$") then
    return nil, nil, nil, explicit_ns, "invalid namespace format"
  end
  if not key_path:match("^[%w_%-%.]+$") then
    return nil, nil, nil, explicit_ns, "invalid key path format"
  end

  return ns .. ":" .. key_path, ns, key_path, explicit_ns, nil
end

---@param bufnr integer
---@param old_key string
---@param new_key string
---@param new_ns string
---@param explicit_ns boolean
---@param fallback_ns string
---@return table[]|nil edits
---@return string|nil error
local function plan_buffer_rename(bufnr, old_key, new_key, new_ns, explicit_ns, fallback_ns)
  local items = rpc_scan_extract(bufnr, fallback_ns)
  local edits = {}
  for _, item in ipairs(items) do
    if item.key == old_key then
      if item.refactorable ~= true then
        return nil,
          string.format(
            "cannot safely rename computed translation reference in buffer %d at line %d",
            bufnr,
            item.lnum + 1
          )
      end
      local new_raw = new_key
      if not item.raw:find(":", 1, true) then
        if explicit_ns and item.namespace ~= new_ns then
          new_raw = new_key
        else
          new_raw = new_key:match("^[^:]+:(.+)$") or new_key
        end
      end
      local end_lnum = item.end_lnum
      if
        type(item.lnum) ~= "number"
        or type(item.col) ~= "number"
        or type(end_lnum) ~= "number"
        or type(item.end_col) ~= "number"
      then
        return nil, string.format("invalid translation reference range in buffer %d", bufnr)
      end
      local ok_old, old_chunks =
        pcall(vim.api.nvim_buf_get_text, bufnr, item.lnum, item.col, end_lnum, item.end_col, {})
      if not ok_old or type(old_chunks) ~= "table" then
        return nil, string.format("failed to read translation reference in buffer %d", bufnr)
      end
      local old_text = table.concat(old_chunks, "\n")
      local quote = old_text:sub(1, 1)
      if #old_text < 2 or (quote ~= '"' and quote ~= "'" and quote ~= "`") or old_text:sub(-1) ~= quote then
        return nil, string.format("translation reference is not a direct literal in buffer %d", bufnr)
      end
      table.insert(edits, {
        lnum = item.lnum,
        col = item.col,
        end_lnum = end_lnum,
        end_col = item.end_col,
        old_text = old_text,
        new_text = vim.json.encode(new_raw),
      })
    end
  end
  table.sort(edits, function(a, b)
    if a.lnum == b.lnum then
      return a.col > b.col
    end
    return a.lnum > b.lnum
  end)

  return edits, nil
end

---@param bufnr integer
---@param edits table[]
---@return string[] edit_errors
local function apply_buffer_rename(bufnr, edits)
  local edit_errors = {}
  for _, edit in ipairs(edits) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local ok_old, old_chunks =
        pcall(vim.api.nvim_buf_get_text, bufnr, edit.lnum, edit.col, edit.end_lnum, edit.end_col, {})
      local current_text = ok_old and type(old_chunks) == "table" and table.concat(old_chunks, "\n") or nil
      if current_text ~= edit.old_text then
        table.insert(
          edit_errors,
          string.format("buf=%d line=%d error=translation reference changed before apply", bufnr, edit.lnum + 1)
        )
      else
        local ok_set, set_err =
          pcall(vim.api.nvim_buf_set_text, bufnr, edit.lnum, edit.col, edit.end_lnum, edit.end_col, { edit.new_text })
        if not ok_set then
          table.insert(
            edit_errors,
            string.format("buf=%d line=%d col=%d error=%s", bufnr, edit.lnum + 1, edit.col + 1, tostring(set_err))
          )
        end
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

  local new_key, new_ns, new_path, explicit_ns, normalize_err = normalize_key(new_key_input, fallback_ns)
  if not new_key or not new_ns or not new_path then
    return false, normalize_err or "invalid new key"
  end
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

  local buffer_plans = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_target_rename_buf(buf) then
      local fb = resources.fallback_namespace_for_buf(buf)
      local edits, plan_err = plan_buffer_rename(buf, old_key, new_key, new_ns, explicit_ns, fb)
      if not edits then
        return false, plan_err or "failed to plan source rename"
      end
      if #edits > 0 then
        table.insert(buffer_plans, { bufnr = buf, edits = edits })
      end
    end
  end

  local file_cache = {}

  local function file_state(path)
    if not file_cache[path] then
      local data, style = resources.read_json_table(path)
      if not data then
        return nil, (style and style.error) or "unknown"
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
    local sanitized_path, sanitize_err = fs.sanitize_path(path, base_dir)
    if not sanitized_path then
      return nil,
        string.format("resource path for language '%s' is outside project root: %s", lang, sanitize_err or "unknown")
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
    local same_file = fs.normalize_path(old_file, root) == fs.normalize_path(new_file, root)

    local dir_ok, dir_err = fs.ensure_dir_within(fs.dirname(new_file), base_dir)
    if not dir_ok then
      return false,
        string.format("failed to prepare resource directory for language '%s': %s", lang, dir_err or "unknown")
    end

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
      local set_ok, set_err = json.set_nested(new_state.data, new_path_in_file, old_value)
      if not set_ok then
        return false, string.format("%s (%s)", set_err or "failed to set key", lang)
      end
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
      local valid, validation_err = resources.validate_json_write(path, entry.data, entry.style, {
        base_dir = base_dir,
      })
      if not valid then
        return false, string.format("failed to validate %s: %s", path, validation_err or "unknown")
      end
    end
  end

  for path, entry in pairs(file_cache) do
    if entry.dirty then
      local dir_ok, dir_err = fs.ensure_dir_within(fs.dirname(path), base_dir)
      if not dir_ok then
        return false, string.format("failed to prepare resource directory for %s: %s", path, dir_err or "unknown")
      end
      local write_ok, write_err = resources.write_json_table(path, entry.data, entry.style, {
        base_dir = base_dir,
        start_dir = root,
      })
      if not write_ok then
        return false, string.format("failed to write %s: %s", path, write_err or "unknown")
      end
    end
  end

  local buffer_edit_errors = {}

  for _, plan in ipairs(buffer_plans) do
    local edit_errors = apply_buffer_rename(plan.bufnr, plan.edits)
    for _, edit_err in ipairs(edit_errors) do
      table.insert(buffer_edit_errors, edit_err)
    end
  end

  for _, plan in ipairs(buffer_plans) do
    core.refresh_now(plan.bufnr, opts.config)
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
