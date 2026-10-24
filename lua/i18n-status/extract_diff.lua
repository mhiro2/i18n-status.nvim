---@class I18nStatusExtractDiff
local M = {}

local fs = require("i18n-status.fs")
local resources = require("i18n-status.resources")
local text_utils = require("i18n-status.text")

local split_key = text_utils.split_i18n_key

---@param start_dir string|nil
---@param lang string
---@param namespace string
---@param framework string|nil
---@param root_list I18nStatusRootInfo[]|nil
---@return string
local function display_resource_path(start_dir, lang, namespace, framework, root_list)
  if type(start_dir) ~= "string" or start_dir == "" then
    return string.format("%s/%s.json", lang, namespace)
  end

  local path = resources.namespace_path(start_dir, lang, namespace, framework, root_list)
  if not path then
    return string.format("%s/%s.json", lang, namespace)
  end

  return fs.shorten_path(path) or path
end

---@param candidate I18nStatusExtractCandidate
---@param languages string[]
---@param primary_lang string
---@param start_dir string|nil
---@param root_list I18nStatusRootInfo[]|nil
---@return string[]
function M.resource_diff_lines(candidate, languages, primary_lang, start_dir, root_list)
  if candidate.mode == "reuse" then
    return {
      "Resource diff:",
      "(reuse existing key: no resource changes)",
    }
  end

  local namespace, key_path = split_key(candidate.proposed_key or "")
  if not namespace or not key_path then
    return {
      "Resource diff:",
      "(invalid key)",
    }
  end

  local lines = { "Resource diff:" }
  for _, lang in ipairs(languages or {}) do
    local path = nil
    if type(start_dir) == "string" and start_dir ~= "" then
      path = resources.namespace_path(start_dir, lang, namespace, candidate.framework, root_list)
    end

    local key_in_file = key_path
    if path and type(start_dir) == "string" and start_dir ~= "" then
      key_in_file = resources.key_path_for_file(namespace, key_path, start_dir, lang, path, root_list)
    end

    local value = lang == primary_lang and (candidate.message or "") or ""
    lines[#lines + 1] = string.format(
      '%s: + "%s": %s',
      display_resource_path(start_dir, lang, namespace, candidate.framework, root_list),
      key_in_file,
      vim.json.encode(value)
    )
  end
  return lines
end

return M
