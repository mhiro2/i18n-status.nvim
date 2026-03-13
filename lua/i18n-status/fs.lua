---@class I18nStatusFs
local M = {}

local uv = vim.uv

---@param path string
---@return string
local function normalize_separator(path)
  return path:gsub("\\", "/")
end

---@param path string
---@return string
local function normalize_path_value(path)
  local normalized = normalize_separator(path)
  if vim.fs and vim.fs.normalize then
    normalized = vim.fs.normalize(normalized)
  end
  return normalized
end

---@param candidate string
---@return boolean
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

---@param candidate string
---@return string
local function collapse_path(candidate)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(candidate)
  end

  local normalized = normalize_separator(candidate)
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

---@param path string|nil
---@param base_dir string|nil
---@return string|nil
function M.normalize_path(path, base_dir)
  if type(path) ~= "string" then
    return nil
  end
  if path == "" then
    return path
  end

  local real = uv.fs_realpath(path)
  if real then
    return normalize_separator(real)
  end

  if type(base_dir) == "string" and base_dir ~= "" then
    local sanitized, err = M.sanitize_path(path, base_dir)
    if sanitized and not err then
      return sanitized
    end
  end

  return normalize_separator(path)
end

---@param list string[]
---@param seen table<string, boolean>
---@param value string|nil
local function push_candidate(list, seen, value)
  if type(value) ~= "string" or value == "" then
    return
  end
  local normalized = normalize_path_value(value)
  if seen[normalized] then
    return
  end
  seen[normalized] = true
  table.insert(list, normalized)
end

---@param path string|nil
---@param root string|nil
---@return boolean
function M.path_under(path, root)
  if type(path) ~= "string" or path == "" or type(root) ~= "string" or root == "" then
    return false
  end

  local path_candidates = {}
  local root_candidates = {}
  local seen_path = {}
  local seen_root = {}

  push_candidate(path_candidates, seen_path, path)
  push_candidate(path_candidates, seen_path, uv.fs_realpath(path))
  push_candidate(root_candidates, seen_root, root)
  push_candidate(root_candidates, seen_root, uv.fs_realpath(root))

  for _, candidate_path in ipairs(path_candidates) do
    for _, candidate_root in ipairs(root_candidates) do
      if candidate_path == candidate_root then
        return true
      end
      local prefix = candidate_root
      if prefix:sub(-1) ~= "/" then
        prefix = prefix .. "/"
      end
      if candidate_path:sub(1, #prefix) == prefix then
        return true
      end
    end
  end

  return false
end

---@param ... string
---@return string
function M.path_join(...)
  return vim.fs.joinpath(...)
end

---@param path string
---@return string
function M.dirname(path)
  if type(path) ~= "string" or path == "" then
    return "."
  end
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
---@return string|nil
function M.shorten_path(path)
  if path == nil or path == vim.NIL then
    return nil
  end
  if type(path) ~= "string" then
    return nil
  end
  if path == "" then
    return path
  end

  local file_dir = M.dirname(path)
  local git_root = M.find_git_root(file_dir)
  if git_root then
    local normalized_root = git_root
    if normalized_root:sub(-1) ~= "/" then
      normalized_root = normalized_root .. "/"
    end
    return path:sub(#normalized_root + 1)
  end

  return path
end

---@param target string
---@param base string
---@return boolean
local function is_within_base(target, base)
  if target == base:sub(1, -2) then
    return true
  end
  return target:sub(1, #base) == base
end

---Normalize and validate a file path for security.
---@param path string
---@param base_dir string
---@return string|nil normalized_path
---@return string|nil err
function M.sanitize_path(path, base_dir)
  if not path or path == "" then
    return nil, "path is empty"
  end
  if not base_dir or base_dir == "" then
    return nil, "base directory is empty"
  end
  if path:find("\0") then
    return nil, "path contains null byte"
  end

  local normalized_path = normalize_separator(path)
  local normalized_base = normalize_separator(base_dir)
  local real_base = uv.fs_realpath(normalized_base)
  if not real_base then
    return nil, "base directory does not exist"
  end

  real_base = normalize_separator(real_base)
  if real_base:sub(-1) ~= "/" then
    real_base = real_base .. "/"
  end

  local base_hint = normalized_base
  if base_hint:sub(-1) ~= "/" then
    base_hint = base_hint .. "/"
  end

  local abs_path
  if is_absolute_path(normalized_path) then
    abs_path = collapse_path(normalized_path)
  else
    abs_path = collapse_path(M.path_join(base_hint, normalized_path))
  end
  abs_path = normalize_separator(abs_path)

  local real_path = uv.fs_realpath(abs_path)
  if real_path then
    real_path = normalize_separator(real_path)
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
