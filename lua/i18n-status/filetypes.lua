---@class I18nStatusFiletypes
local M = {}

---@type table<string, string>
local FILETYPE_TO_LANG = {
  javascript = "javascript",
  javascriptreact = "jsx",
  typescript = "typescript",
  typescriptreact = "tsx",
}

---@type table<string, boolean>
local SOURCE_FILETYPES = {
  javascript = true,
  javascriptreact = true,
  typescript = true,
  typescriptreact = true,
}

---@type table<string, boolean>
local RESOURCE_FILETYPES = {
  json = true,
  jsonc = true,
}

---@param ft string|nil
---@return string
function M.lang_for_filetype(ft)
  if type(ft) ~= "string" then
    return ""
  end
  return FILETYPE_TO_LANG[ft] or ""
end

---@param ft string|nil
---@return boolean
function M.is_source_filetype(ft)
  return type(ft) == "string" and SOURCE_FILETYPES[ft] == true
end

---@param ft string|nil
---@return boolean
function M.is_resource_filetype(ft)
  return type(ft) == "string" and RESOURCE_FILETYPES[ft] == true
end

return M
