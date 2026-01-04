---@class I18nStatusUtil
local M = {}

local uv = vim.uv or vim.loop

---@param tbl table
---@return table
local function deep_copy(tbl)
  if type(tbl) ~= "table" then
    return tbl
  end
  local out = {}
  for k, v in pairs(tbl) do
    if type(v) == "table" then
      out[k] = deep_copy(v)
    else
      out[k] = v
    end
  end
  return out
end

---@param base table
---@param extra table
---@return table
function M.tbl_deep_merge(base, extra)
  -- Deep copy base to avoid mutating it
  local out = deep_copy(base)
  for k, v in pairs(extra or {}) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = M.tbl_deep_merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

---@param ... string
---@return string
function M.path_join(...)
  return vim.fs.joinpath(...)
end

---@param path string
---@return string
function M.dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

---@param path string
---@return boolean
function M.file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

---@param path string
---@return boolean
function M.is_dir(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param path string
---@return string|nil
function M.read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

---@param path string
---@return boolean
function M.ensure_dir(path)
  if M.is_dir(path) then
    return true
  end
  return vim.fn.mkdir(path, "p") == 1
end

---@param tbl table
---@param key_path string
---@param value any
function M.set_nested(tbl, key_path, value)
  local parts = vim.split(key_path, ".", { plain = true })
  local cur = tbl
  for i = 1, #parts - 1 do
    local key = parts[i]
    if type(cur[key]) ~= "table" then
      cur[key] = {}
    end
    cur = cur[key]
  end
  cur[parts[#parts]] = value
end

---@param path string
---@return integer|nil
function M.file_mtime(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return nil
  end
  local nsec = stat.mtime.nsec or 0
  return stat.mtime.sec * 1000000000 + nsec
end

---@param json string
---@return table|nil
---@return string|nil
function M.json_decode(json)
  local ok, result = pcall(vim.fn.json_decode, json)
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
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" then
      return false, 0
    end
    if k > max then
      max = k
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
        table.insert(parts, line)
      end
      table.insert(parts, indent .. "]")
      return table.concat(parts, "\n")
    end

    local keys = {}
    for k, _ in pairs(value) do
      if type(k) == "string" then
        table.insert(keys, k)
      end
    end
    table.sort(keys)
    if #keys == 0 then
      return "{}"
    end
    local parts = { "{" }
    for i, k in ipairs(keys) do
      local encoded_key = vim.fn.json_encode(k)
      local encoded_value = encode_pretty(value[k], indent_unit, level + 1)
      local line = next_indent .. encoded_key .. ": " .. encoded_value
      if i < #keys then
        line = line .. ","
      end
      table.insert(parts, line)
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  end
  return vim.fn.json_encode(value)
end

---@param value any
---@param indent_unit string|nil
---@return string
function M.json_encode_pretty(value, indent_unit)
  local unit = indent_unit or "  "
  return encode_pretty(value, unit, 0)
end

---@param tbl table
---@param prefix string
---@param out table
---@return table
local function flatten_into(tbl, prefix, out)
  for k, v in pairs(tbl) do
    local key = prefix ~= "" and (prefix .. "." .. k) or k
    if type(v) == "table" then
      flatten_into(v, key, out)
    else
      out[key] = v
    end
  end
  return out
end

---@param tbl table
---@return table
function M.flatten_table(tbl)
  return flatten_into(tbl, "", {})
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
  for k, _ in pairs(a) do
    if not b[k] then
      return false
    end
  end
  for k, _ in pairs(b) do
    if not a[k] then
      return false
    end
  end
  return true
end

---@param start_dir string
---@param targets string[]
---@return string|nil
function M.find_up(start_dir, targets)
  local dir = start_dir
  while dir and dir ~= "/" do
    for _, target in ipairs(targets) do
      local candidate = M.path_join(dir, target)
      if M.is_dir(candidate) then
        return candidate
      end
    end
    local parent = M.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---@param bufnr integer
---@return integer, integer
function M.visible_range(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return 1, vim.api.nvim_buf_line_count(bufnr)
  end
  local win = wins[1]
  local top = vim.fn.line("w0", win)
  local bottom = vim.fn.line("w$", win)
  return top, bottom
end

---@param text string
---@return string
function M.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param start_dir string
---@return string|nil
function M.find_git_root(start_dir)
  local dir = start_dir
  while dir and dir ~= "/" do
    local git_dir = M.path_join(dir, ".git")
    if M.is_dir(git_dir) or M.file_exists(git_dir) then
      return dir
    end
    local parent = M.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---@param path string
---@return string
function M.shorten_path(path)
  if not path or path == "" then
    return path
  end

  -- Try to find git root from the file's directory
  local file_dir = M.dirname(path)
  local git_root = M.find_git_root(file_dir)

  if git_root then
    -- Convert to relative path from git root
    local relative = path:sub(#git_root + 2) -- +2 to skip the trailing /
    return relative
  end

  -- Fallback to full path if no git root found
  return path
end

return M
