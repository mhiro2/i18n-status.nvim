---@class I18nStatusKeyWrite
local M = {}

local resources = require("i18n-status.resources")
local util = require("i18n-status.util")

---Write a single translation value to a language file.
---@param namespace string
---@param key_path string
---@param lang string
---@param value string
---@param start_dir string
---@return boolean
function M.write_single_translation(namespace, key_path, lang, value, start_dir)
  local path = resources.namespace_path(start_dir, lang, namespace)
  if not path then
    return false
  end

  if not util.ensure_dir(util.dirname(path)) then
    return false
  end

  local data, style = resources.read_json_table(path)
  if not data then
    return false
  end

  local path_in_file = resources.key_path_for_file(namespace, key_path, start_dir, lang, path)
  util.set_nested(data, path_in_file, value)
  resources.write_json_table(path, data, style)
  return true
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
  local success_count = 0
  local failed_langs = {}

  for _, lang in ipairs(languages) do
    local value = translations[lang] or ""
    if M.write_single_translation(namespace, key_path, lang, value, start_dir) then
      success_count = success_count + 1
    else
      table.insert(failed_langs, lang)
    end
  end

  return success_count, failed_langs
end

return M
