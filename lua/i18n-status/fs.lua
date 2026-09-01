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

---@param candidate string
---@param base_dir string|nil
---@return string
local function absolute_path(candidate, base_dir)
  if is_absolute_path(candidate) then
    return normalize_path_value(collapse_path(candidate))
  end
  return normalize_path_value(collapse_path(vim.fs.joinpath(base_dir or vim.fn.getcwd(), candidate)))
end

---@param err string|nil
---@return boolean
local function is_not_found_error(err)
  return type(err) == "string" and err:find("ENOENT", 1, true) ~= nil
end

---Resolve a path through its longest existing parent.
---@param path string
---@return string|nil
---@return string|nil
local function resolve_from_existing_parent(path)
  local cursor = normalize_path_value(path)
  local missing_parts = {}

  while cursor and cursor ~= "" do
    local real_path = uv.fs_realpath(cursor)
    if real_path then
      local stat = uv.fs_stat(real_path)
      if #missing_parts > 0 and (not stat or stat.type ~= "directory") then
        return nil, "existing path parent is not a directory"
      end

      local resolved = normalize_path_value(real_path)
      for index = #missing_parts, 1, -1 do
        resolved = normalize_path_value(collapse_path(vim.fs.joinpath(resolved, missing_parts[index])))
      end
      return resolved, nil
    end

    local lstat, lstat_err = uv.fs_lstat(cursor)
    if lstat then
      return nil, "failed to resolve existing path component"
    end
    if lstat_err and not is_not_found_error(lstat_err) then
      return nil, "failed to inspect path component: " .. tostring(lstat_err)
    end

    local parent = vim.fs.dirname(cursor)
    local name = vim.fs.basename(cursor)
    if not parent or parent == cursor or not name or name == "" then
      return nil, "failed to resolve an existing path parent"
    end
    missing_parts[#missing_parts + 1] = name
    cursor = parent
  end

  return nil, "failed to resolve an existing path parent"
end

---@param target string
---@param base string
---@return boolean
local function is_within_base(target, base)
  if target == base then
    return true
  end
  local prefix = base
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  return target:sub(1, #prefix) == prefix
end

---Resolve a path through its longest existing parent without applying a containment policy.
---@param path string
---@param base_dir string|nil
---@return string|nil
---@return string|nil
function M.canonical_path(path, base_dir)
  if type(path) ~= "string" or path == "" then
    return nil, "path is empty"
  end
  return resolve_from_existing_parent(absolute_path(path, base_dir))
end

---@param path string|nil
---@param root string|nil
---@return boolean
function M.path_under(path, root)
  if type(path) ~= "string" or path == "" or type(root) ~= "string" or root == "" then
    return false
  end

  local resolved_path = M.canonical_path(path, nil)
  local resolved_root = M.canonical_path(root, nil)
  return resolved_path ~= nil and resolved_root ~= nil and is_within_base(resolved_path, resolved_root)
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

  local normalized_base = absolute_path(normalize_separator(base_dir), nil)
  local real_base = uv.fs_realpath(normalized_base)
  local base_stat = real_base and uv.fs_stat(real_base) or nil
  if not real_base or not base_stat or base_stat.type ~= "directory" then
    return nil, "base directory does not exist"
  end

  real_base = normalize_path_value(real_base)
  local abs_path = absolute_path(normalize_separator(path), normalized_base)
  local resolved_path, resolve_err = resolve_from_existing_parent(abs_path)
  if not resolved_path then
    return nil, resolve_err
  end
  if not is_within_base(resolved_path, real_base) then
    return nil, "path is outside base directory"
  end

  return resolved_path, nil
end

---Require an existing directory whose canonical path stays inside a base directory.
---@param path string
---@param base_dir string
---@return boolean
---@return string|nil
function M.ensure_dir_within(path, base_dir)
  local sanitized_path, sanitize_err = M.sanitize_path(path, base_dir)
  if not sanitized_path then
    return false, sanitize_err
  end

  local stat = uv.fs_stat(sanitized_path)
  if not stat or stat.type ~= "directory" then
    return false, "resource directory does not exist"
  end

  local verified_path, verify_err = M.sanitize_path(sanitized_path, base_dir)
  if not verified_path then
    return false, verify_err
  end
  if verified_path ~= sanitized_path then
    return false, "directory path changed while it was being created"
  end
  return true, nil
end

return M
