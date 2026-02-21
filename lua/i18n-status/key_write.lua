---@class I18nStatusKeyWrite
local M = {}

local resources = require("i18n-status.resources")
local util = require("i18n-status.util")

---@class I18nStatusKeyWriteEntry
---@field lang string
---@field path string
---@field data table
---@field original_data table
---@field style table|nil

---@param entries I18nStatusKeyWriteEntry[]
---@return string[]
local function all_failed_langs(entries)
  local failed = {}
  for _, entry in ipairs(entries) do
    table.insert(failed, entry.lang)
  end
  return failed
end

---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param base_dir string
---@param lang string
---@return I18nStatusKeyWriteEntry|nil
local function prepare_entry(namespace, key_path, translations, start_dir, base_dir, lang)
  local path = resources.namespace_path(start_dir, lang, namespace)
  if not path then
    return nil
  end

  local sanitized_path = util.sanitize_path(path, base_dir)
  if not sanitized_path then
    return nil
  end

  if not util.ensure_dir(util.dirname(sanitized_path)) then
    return nil
  end

  local data, style = resources.read_json_table(sanitized_path)
  if not data then
    return nil
  end

  local original_data = vim.deepcopy(data)
  local path_in_file = resources.key_path_for_file(namespace, key_path, start_dir, lang, sanitized_path)
  util.set_nested(data, path_in_file, translations[lang] or "")
  return {
    lang = lang,
    path = sanitized_path,
    data = data,
    original_data = original_data,
    style = style,
  }
end

---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param base_dir string
---@param languages string[]
---@return I18nStatusKeyWriteEntry[] entries
---@return string[] failed_langs
local function prepare_entries(namespace, key_path, translations, start_dir, base_dir, languages)
  local entries = {}
  local failed_langs = {}

  for _, lang in ipairs(languages) do
    local entry = prepare_entry(namespace, key_path, translations, start_dir, base_dir, lang)
    if entry then
      table.insert(entries, entry)
    else
      table.insert(failed_langs, lang)
    end
  end

  return entries, failed_langs
end

---@param committed I18nStatusKeyWriteEntry[]
local function rollback(committed)
  if #committed == 0 then
    return
  end
  ---@type string[]
  local rollback_failed = {}
  for i = #committed, 1, -1 do
    local entry = committed[i]
    local rollback_ok = resources.write_json_table(entry.path, entry.original_data, entry.style)
    if not rollback_ok then
      table.insert(rollback_failed, string.format("%s (%s)", entry.lang, entry.path))
    end
  end
  if #rollback_failed > 0 then
    vim.notify(
      "i18n-status: rollback failed for languages: " .. table.concat(rollback_failed, ", "),
      vim.log.levels.ERROR
    )
  end
end

---Write a single translation value to a language file.
---@param namespace string
---@param key_path string
---@param lang string
---@param value string
---@param start_dir string
---@return boolean
function M.write_single_translation(namespace, key_path, lang, value, start_dir)
  local success_count = M.write_translations(namespace, key_path, { [lang] = value }, start_dir, { lang })
  return success_count == 1
end

---Write translation values to all language files.
---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param languages string[]
---@return integer success_count
---@return string[] failed_langs
function M.write_translations(namespace, key_path, translations, start_dir, languages)
  if #languages == 0 then
    return 0, {}
  end

  local cache = resources.ensure_index(start_dir)
  local base_dir = resources.project_root(start_dir, cache and cache.roots or nil)
  if not base_dir or base_dir == "" then
    base_dir = start_dir
  end

  local entries, failed_langs = prepare_entries(namespace, key_path, translations, start_dir, base_dir, languages)
  if #failed_langs > 0 then
    return 0, failed_langs
  end

  local committed = {}
  for _, entry in ipairs(entries) do
    local write_ok = resources.write_json_table(entry.path, entry.data, entry.style)
    if not write_ok then
      rollback(committed)
      return 0, all_failed_langs(entries)
    end
    table.insert(committed, entry)
  end

  return #entries, {}
end

return M
