---@class I18nStatusResourceDiscovery
local M = {}

local util = require("i18n-status.util")

local uv = vim.uv

local WATCH_MAX_FILES = 200
local WATCH_PATHS_CACHE_TTL_MS = 1000

---@type table<string, { paths: string[], signature: string, updated_at: integer }>
local watch_paths_cache = {}

---@param path string|nil
---@return string|nil
function M.normalize_path(path)
  if not path or path == "" then
    return path
  end
  local real = uv.fs_realpath(path)
  local normalized = real or path
  normalized = normalized:gsub("\\", "/")
  return normalized
end

---@param path string|nil
---@param root string|nil
---@return boolean
function M.path_under(path, root)
  if not path or path == "" or not root or root == "" then
    return false
  end
  if path == root then
    return true
  end
  local prefix = root
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  return path:sub(1, #prefix) == prefix
end

---@param paths string[]
---@return string
local function common_ancestor(paths)
  if not paths or #paths == 0 then
    return ""
  end
  local common = paths[1]
  for i = 2, #paths do
    local parts1 = vim.split(common, "/", { plain = true })
    local parts2 = vim.split(paths[i], "/", { plain = true })
    local min_len = math.min(#parts1, #parts2)
    local new_common = {}
    for j = 1, min_len do
      if parts1[j] == parts2[j] then
        table.insert(new_common, parts1[j])
      else
        break
      end
    end
    common = table.concat(new_common, "/")
    if common == "" then
      return ""
    end
  end
  return common
end

---@param start_dir string
---@param roots table|nil
---@return string
function M.project_root(start_dir, roots)
  if not start_dir or start_dir == "" then
    return ""
  end
  local git_root = util.find_git_root(start_dir)
  if git_root and git_root ~= "" then
    return git_root
  end
  local paths = { start_dir }
  for _, root in ipairs(roots or {}) do
    if root and root.path and root.path ~= "" then
      table.insert(paths, root.path)
    end
  end
  local common = common_ancestor(paths)
  if common == "" then
    return start_dir
  end
  return common
end

---@param root string
---@return string[]
function M.list_dirs(root)
  local dirs = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return dirs
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" then
      table.insert(dirs, name)
    end
  end
  return dirs
end

---@param root string
---@return string[]
function M.list_json_files(root)
  local files = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return files
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" and name:sub(-5) == ".json" then
      table.insert(files, util.path_join(root, name))
    end
  end
  return files
end

---@param start_dir string
---@return table
function M.resolve_roots(start_dir)
  local roots = {}
  local i18next = util.find_up(start_dir, { "locales", "public/locales" })
  if i18next then
    table.insert(roots, { kind = "i18next", path = i18next })
  end
  local messages = util.find_up(start_dir, { "messages" })
  if messages then
    table.insert(roots, { kind = "next-intl", path = messages })
  end
  return roots
end

---@param roots table
---@return string|nil
function M.roots_key(roots)
  if not roots or #roots == 0 then
    return nil
  end
  local parts = {}
  for _, root in ipairs(roots) do
    parts[#parts + 1] = root.kind .. ":" .. root.path
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

---@param roots table
---@param start_dir string
---@return string
function M.compute_cache_key(roots, start_dir)
  local key = M.roots_key(roots)
  if key then
    return key
  end
  return "__none__:" .. (start_dir or "")
end

---@param roots table
---@param opts? { force?: boolean }
---@return string[]
function M.watch_paths(roots, opts)
  opts = opts or {}
  local force = opts.force == true
  local key = M.roots_key(roots) or "__none__"
  local now = uv.now()
  local cached = watch_paths_cache[key]
  if not force and cached and (now - cached.updated_at) < WATCH_PATHS_CACHE_TTL_MS then
    return cached.paths
  end

  local paths = {}
  local seen = {}
  local watched_files = 0

  ---@param path string|nil
  local function add(path)
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end

  for _, root in ipairs(roots or {}) do
    add(root.path)
    for _, dir in ipairs(M.list_dirs(root.path)) do
      local lang_root = util.path_join(root.path, dir)
      add(lang_root)
      if watched_files < WATCH_MAX_FILES then
        for _, file in ipairs(M.list_json_files(lang_root)) do
          add(file)
          watched_files = watched_files + 1
          if watched_files >= WATCH_MAX_FILES then
            break
          end
        end
      end
    end

    if root.kind == "next-intl" and watched_files < WATCH_MAX_FILES then
      for _, file in ipairs(M.list_json_files(root.path)) do
        add(file)
        watched_files = watched_files + 1
        if watched_files >= WATCH_MAX_FILES then
          break
        end
      end
    end
  end

  table.sort(paths)
  watch_paths_cache[key] = {
    paths = paths,
    signature = table.concat(paths, "|"),
    updated_at = now,
  }
  return paths
end

---@param roots table
---@param opts? { force?: boolean }
---@return string|nil
function M.compute_structural_signature(roots, opts)
  opts = opts or {}
  local force = opts.force == true
  if not roots or #roots == 0 then
    return nil
  end

  local key = M.roots_key(roots) or "__none__"
  local now = uv.now()
  local cached = watch_paths_cache[key]
  if not force and cached and (now - cached.updated_at) < WATCH_PATHS_CACHE_TTL_MS then
    return cached.signature
  end

  M.watch_paths(roots, { force = force })
  local refreshed = watch_paths_cache[key]
  return refreshed and refreshed.signature or nil
end

---@param roots table
---@param key string
---@param watcher table
---@return boolean
function M.cache_valid_structural(roots, key, watcher)
  local stored = watcher.signature(key)
  if not stored then
    return false
  end
  local current = M.compute_structural_signature(roots)
  return current == stored
end

---@param roots table
---@param path string
---@return { kind: string, root: string, lang: string, namespace: string|nil, is_root: boolean }|nil
function M.resource_info_from_roots(roots, path)
  if not path or path == "" then
    return nil
  end

  local norm_path = M.normalize_path(path)
  if not norm_path then
    return nil
  end

  for _, root in ipairs(roots or {}) do
    local root_path = M.normalize_path(root.path)
    if root_path and M.path_under(norm_path, root_path) then
      if norm_path == root_path then
        break
      end

      local rel = norm_path:sub(#root_path + 2)
      if rel:sub(-5) ~= ".json" then
        break
      end

      local parts = vim.split(rel, "/", { plain = true })
      if root.kind == "i18next" then
        if #parts == 2 then
          return {
            kind = root.kind,
            root = root_path,
            lang = parts[1],
            namespace = parts[2]:sub(1, -6),
            is_root = false,
          }
        end
      elseif root.kind == "next-intl" then
        if #parts == 1 then
          return {
            kind = root.kind,
            root = root_path,
            lang = parts[1]:sub(1, -6),
            namespace = nil,
            is_root = true,
          }
        end
        if #parts == 2 then
          return {
            kind = root.kind,
            root = root_path,
            lang = parts[1],
            namespace = parts[2]:sub(1, -6),
            is_root = false,
          }
        end
      end

      break
    end
  end

  return nil
end

function M.clear_watch_paths_cache()
  watch_paths_cache = {}
end

return M
