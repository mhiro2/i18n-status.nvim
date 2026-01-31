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
  return vim.fs.dirname(path) or "."
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
      local encoded_key = vim.json.encode(k)
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
  return vim.trim(text)
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
    -- Ensure git_root ends with / for consistent substring calculation
    local normalized_root = git_root
    if normalized_root:sub(-1) ~= "/" then
      normalized_root = normalized_root .. "/"
    end
    -- Skip past the normalized root (including the /)
    local relative = path:sub(#normalized_root + 1)
    return relative
  end

  -- Fallback to full path if no git root found
  return path
end

---Normalize and validate a file path for security
---Checks for null bytes, resolves to real path, and ensures it's within base_dir
---@param path string The path to validate
---@param base_dir string The base directory that the path must be within
---@return string|nil normalized_path Normalized path if valid, nil if invalid
---@return string|nil error Error message if validation fails
function M.sanitize_path(path, base_dir)
  if not path or path == "" then
    return nil, "path is empty"
  end
  if not base_dir or base_dir == "" then
    return nil, "base directory is empty"
  end

  -- Check for null bytes (security risk)
  if path:find("\0") then
    return nil, "path contains null byte"
  end

  local normalized_path = path:gsub("\\", "/")
  local normalized_base = base_dir:gsub("\\", "/")
  local real_base = uv.fs_realpath(normalized_base)
  if not real_base then
    return nil, "base directory does not exist"
  end
  real_base = real_base:gsub("\\", "/")
  if real_base:sub(-1) ~= "/" then
    real_base = real_base .. "/"
  end
  local base_hint = normalized_base
  if base_hint:sub(-1) ~= "/" then
    base_hint = base_hint .. "/"
  end

  local function is_within_base(target, base)
    if target == base:sub(1, -2) then
      return true
    end
    return target:sub(1, #base) == base
  end

  local abs_path
  local function is_absolute_path(candidate)
    if vim.fs and vim.fs.isabsolute then
      return vim.fs.isabsolute(candidate)
    end
    if candidate:sub(1, 1) == "/" then
      return true
    end
    if candidate:match("^%a:[/\\]") then
      return true
    end
    return candidate:sub(1, 2) == "\\\\"
  end

  local function normalize_path(candidate)
    if vim.fs and vim.fs.normalize then
      return vim.fs.normalize(candidate)
    end
    local normalized = candidate:gsub("\\", "/")
    local prefix = ""
    local rest = normalized
    local drive = normalized:match("^%a:[/]")
    if drive then
      prefix = drive
      rest = normalized:sub(4)
    elseif normalized:sub(1, 2) == "//" then
      prefix = "//"
      rest = normalized:sub(3)
    elseif normalized:sub(1, 1) == "/" then
      prefix = "/"
      rest = normalized:sub(2)
    end
    local parts = {}
    for part in rest:gmatch("[^/]+") do
      if part ~= "." and part ~= "" then
        if part == ".." then
          if #parts > 0 and parts[#parts] ~= ".." then
            table.remove(parts)
          elseif prefix == "" then
            table.insert(parts, part)
          end
        else
          table.insert(parts, part)
        end
      end
    end
    local joined = table.concat(parts, "/")
    if prefix ~= "" then
      if joined ~= "" then
        return prefix .. joined
      end
      return prefix
    end
    return joined
  end

  if is_absolute_path(normalized_path) then
    abs_path = normalize_path(normalized_path)
  else
    abs_path = normalize_path(M.path_join(base_hint, normalized_path))
  end
  abs_path = abs_path:gsub("\\", "/")

  local real_path = uv.fs_realpath(abs_path)
  if real_path then
    real_path = real_path:gsub("\\", "/")
    if not is_within_base(real_path, real_base) then
      return nil, "path is outside base directory"
    end
    return real_path, nil
  end

  if not is_within_base(abs_path, real_base) and not is_within_base(abs_path, base_hint) then
    return nil, "path is outside base directory"
  end

  return abs_path, nil
end

return M
