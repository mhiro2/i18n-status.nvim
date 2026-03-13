---@class I18nStatusJson
local M = {}

---@param json string
---@return table|nil
---@return string|nil
function M.json_decode(json)
  local ok, result = pcall(vim.json.decode, json)
  if not ok then
    return nil, result
  end
  return result, nil
end

---@param text string|nil
---@return string
function M.detect_indent(text)
  if not text or text == "" then
    return "  "
  end
  for line in text:gmatch("[^\n]+") do
    local indent = line:match("^(%s+)%S")
    if indent and indent ~= "" then
      if indent:find("\t") then
        return "\t"
      end
      return indent
    end
  end
  return "  "
end

---@param tbl table
---@return boolean
---@return integer
local function is_array(tbl)
  local max = 0
  local count = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= "number" then
      return false, 0
    end
    if key > max then
      max = key
    end
    count = count + 1
  end
  if max == 0 then
    return true, 0
  end
  if count ~= max then
    return false, 0
  end
  return true, max
end

---@param value any
---@param indent_unit string
---@param level integer
---@return string
local function encode_pretty(value, indent_unit, level)
  if type(value) == "table" then
    local array, length = is_array(value)
    local indent = string.rep(indent_unit, level)
    local next_indent = string.rep(indent_unit, level + 1)
    if array then
      if length == 0 then
        return "[]"
      end
      local parts = { "[" }
      for i = 1, length do
        local line = next_indent .. encode_pretty(value[i], indent_unit, level + 1)
        if i < length then
          line = line .. ","
        end
        parts[#parts + 1] = line
      end
      parts[#parts + 1] = indent .. "]"
      return table.concat(parts, "\n")
    end

    local keys = {}
    for key, _ in pairs(value) do
      if type(key) == "string" then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys)
    if #keys == 0 then
      return "{}"
    end

    local parts = { "{" }
    for index, key in ipairs(keys) do
      local encoded_key = vim.json.encode(key)
      local encoded_value = encode_pretty(value[key], indent_unit, level + 1)
      local line = next_indent .. encoded_key .. ": " .. encoded_value
      if index < #keys then
        line = line .. ","
      end
      parts[#parts + 1] = line
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
  end
  return vim.json.encode(value)
end

---@param value any
---@param indent_unit string|nil
---@return string
function M.json_encode_pretty(value, indent_unit)
  local unit = indent_unit or "  "
  return encode_pretty(value, unit, 0)
end

---@param tbl table
---@param key_path string
---@param value any
function M.set_nested(tbl, key_path, value)
  local parts = vim.split(key_path, ".", { plain = true })
  local current = tbl
  for i = 1, #parts - 1 do
    local key = parts[i]
    if type(current[key]) ~= "table" then
      current[key] = {}
    end
    current = current[key]
  end
  current[parts[#parts]] = value
end

return M
