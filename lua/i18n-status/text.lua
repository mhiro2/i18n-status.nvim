---@class I18nStatusText
local M = {}

---@param text string
---@return string
function M.trim(text)
  return vim.trim(text)
end

---@param text string
---@return table<string, boolean>
function M.extract_placeholders(text)
  local placeholders = {}
  if not text or text == "" then
    return placeholders
  end
  for name in text:gmatch("{{%s*([%w_]+)%s*}}") do
    placeholders[name] = true
  end
  for name in text:gmatch("{%s*([%w_]+)%s*}") do
    placeholders[name] = true
  end
  return placeholders
end

---@param a table<string, boolean>
---@param b table<string, boolean>
---@return boolean
function M.placeholder_equal(a, b)
  for key, _ in pairs(a) do
    if not b[key] then
      return false
    end
  end
  for key, _ in pairs(b) do
    if not a[key] then
      return false
    end
  end
  return true
end

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
