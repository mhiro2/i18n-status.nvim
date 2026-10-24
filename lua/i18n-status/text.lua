---@class I18nStatusText
local M = {}

---@param full_key string
---@return string|nil namespace
---@return string|nil key_path
function M.split_i18n_key(full_key)
  if type(full_key) ~= "string" then
    return nil, nil
  end
  local namespace = full_key:match("^(.-):")
  local key_path = full_key:match("^[^:]+:(.+)$")
  if not namespace or namespace == "" or not key_path or key_path == "" then
    return nil, nil
  end
  return namespace, key_path
end

return M
