---@class I18nStatusResources
local M = {
  reader = nil,
  caches = {},
  last_cache_key = nil,
}

local util = require("i18n-status.util")
local watcher = require("i18n-status.watcher")
local resource_io = require("i18n-status.resource_io")
local discovery = require("i18n-status.resource_discovery")
local resource_index = require("i18n-status.resource_index")

---@class I18nStatusResourceItem
---@field value string|nil
---@field file string|nil
---@field priority integer

---@class I18nStatusFileEntry
---@field lang string
---@field key string
---@field priority integer

---@class I18nStatusFileMeta
---@field lang string
---@field namespace string|nil

---@class I18nStatusResourceError
---@field lang string
---@field file string
---@field error string

---@class I18nStatusRootInfo
---@field path string
---@field kind "i18next"|"next_intl"

---@class I18nStatusCache
---@field key string|nil
---@field index table<string, table<string, I18nStatusResourceItem>>
---@field files table<string, integer>
---@field languages string[]
---@field roots I18nStatusRootInfo[]
---@field errors I18nStatusResourceError[]
---@field namespaces string[]
---@field dirty boolean
---@field checked_at integer
---@field structural_signature string|nil
---@field entries_by_key table<string, table<string, table>>
---@field file_entries table<string, I18nStatusFileEntry[]>
---@field file_meta table<string, I18nStatusFileMeta>
---@field file_errors table<string, {error: string, mtime: integer}>

local uv = vim.uv
local CACHE_VALIDATE_INTERVAL_MS = 1000

---@return I18nStatusCache|nil
local function current_cache()
  if M.last_cache_key then
    return M.caches[M.last_cache_key]
  end
  return nil
end

---@param key string|nil
local function mark_cache_dirty(key)
  discovery.clear_watch_paths_cache()
  if key then
    local cache = M.caches[key]
    if cache then
      cache.dirty = true
      cache.checked_at = 0
    end
    return
  end
  for _, cache in pairs(M.caches) do
    cache.dirty = true
    cache.checked_at = 0
  end
end

---@param list string[]|nil
---@param value string
---@return boolean
local function contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

---@param bufnr integer|nil
---@return string
function M.start_dir(bufnr)
  local target = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(target)
  if name and name ~= "" then
    local dir = util.dirname(name)
    while dir and dir ~= "" and dir ~= "/" and not util.is_dir(dir) do
      local parent = util.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
    if dir and dir ~= "" and util.is_dir(dir) then
      return dir
    end
  end
  return vim.fn.getcwd()
end

---@param start_dir string
---@param roots table|nil
---@return string
function M.project_root(start_dir, roots)
  if not start_dir or start_dir == "" then
    return ""
  end
  local root_list = roots or M.roots(start_dir)
  return discovery.project_root(start_dir, root_list)
end

---@param path string
---@return table|nil
---@return table
function M.read_json_table(path)
  return resource_io.read_json_table(path)
end

---@param path string
---@param data table
---@param style table|nil
---@param opts table|nil
function M.write_json_table(path, data, style, opts)
  local io_opts = vim.tbl_extend("force", opts or {}, { mark_dirty = M.mark_dirty })
  resource_io.write_json_table(path, data, style, io_opts)
end

---@param roots table
---@return table
function M.build_index(roots)
  return resource_index.build_index(roots)
end

---@param start_dir string
---@return table
function M.ensure_index(start_dir)
  local roots = discovery.resolve_roots(start_dir)
  local key = discovery.compute_cache_key(roots, start_dir)
  local cache = M.caches[key]
  if cache and not cache.dirty then
    M.last_cache_key = key
    local watching = watcher.is_watching(key)
    if watching then
      local now = uv.now()
      if (now - (cache.checked_at or 0)) < CACHE_VALIDATE_INTERVAL_MS then
        return cache
      end
      cache.checked_at = now
      if discovery.cache_valid_structural(roots, key, watcher) then
        return cache
      end
    else
      if resource_index.cache_still_valid(cache, roots) then
        return cache
      end
    end
  end

  local built = resource_index.build_index(roots)
  built.key = key
  built.namespaces = resource_index.collect_namespaces(built.index)
  built.checked_at = uv.now()
  built.dirty = false
  built.structural_signature = discovery.compute_structural_signature(roots)
  M.caches[key] = built
  M.last_cache_key = key
  return built
end

---@param cache_key string
---@param paths string[]
---@param opts table|nil
---@return boolean
---@return boolean|nil
function M.apply_changes(cache_key, paths, opts)
  opts = opts or {}
  local cache = M.caches[cache_key]
  if not cache then
    return false, true
  end

  return resource_index.apply_changes(cache, paths, {
    allow_rebuild = opts.allow_rebuild,
    cache_key = cache_key,
    set_signature = watcher.set_signature,
  })
end

---@param start_dir string
---@return table
function M.roots(start_dir)
  local cache = M.ensure_index(start_dir)
  return cache.roots or {}
end

---@param start_dir string
---@param lang string
---@param namespace string
---@return string|nil
function M.namespace_path(start_dir, lang, namespace)
  local roots = M.roots(start_dir)
  for _, root in ipairs(roots) do
    if root.kind == "i18next" then
      return util.path_join(root.path, lang, namespace .. ".json")
    end
    if root.kind == "next-intl" then
      local root_file = util.path_join(root.path, lang .. ".json")
      if util.file_exists(root_file) then
        return root_file
      end
      return util.path_join(root.path, lang, namespace .. ".json")
    end
  end
  return nil
end

---@param lang string
---@param key string
---@return I18nStatusResourceItem|nil
function M.get(lang, key)
  local cache = current_cache()
  if not cache or not cache.index or not cache.index[lang] then
    return nil
  end
  return cache.index[lang][key]
end

---@return string[]
function M.languages()
  local cache = current_cache()
  return (cache and cache.languages) or {}
end

---@param start_dir string
---@return string[]
function M.namespaces(start_dir)
  local cache = M.ensure_index(start_dir)
  if not cache.namespaces then
    cache.namespaces = resource_index.collect_namespaces(cache.index)
  end
  return cache.namespaces or {}
end

---@param start_dir string
---@return string|nil, string, string[]
function M.namespace_hint(start_dir)
  local namespaces = M.namespaces(start_dir)
  if #namespaces == 1 then
    return namespaces[1], "single", namespaces
  end
  if #namespaces == 0 then
    return nil, "none", namespaces
  end
  return nil, "ambiguous", namespaces
end

---@param start_dir string
---@return string, string
function M.fallback_namespace(start_dir)
  local hint, reason, namespaces = M.namespace_hint(start_dir)
  if hint then
    return hint, reason
  end
  local fallback = nil
  if contains(namespaces, "translation") then
    fallback = "translation"
  elseif namespaces[1] then
    fallback = namespaces[1]
  else
    fallback = "common"
  end
  return fallback, reason
end

---@param bufnr integer
---@return string
function M.fallback_namespace_for_buf(bufnr)
  local start_dir = M.start_dir(bufnr)
  return M.fallback_namespace(start_dir)
end

---@param start_dir string
---@param path string
---@return { kind: string, root: string, lang: string, namespace: string|nil, is_root: boolean }|nil
function M.resource_info(start_dir, path)
  local roots = M.roots(start_dir)
  return discovery.resource_info_from_roots(roots, path)
end

---@param bufnr integer
---@return { kind: string, root: string, lang: string, namespace: string|nil, is_root: boolean }|nil
function M.resource_info_for_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then
    return nil
  end
  local start_dir = M.start_dir(bufnr)
  return M.resource_info(start_dir, path)
end

---@param start_dir string
---@param lang string
---@param path string
---@return boolean
function M.is_next_intl_root_file(start_dir, lang, path)
  for _, root in ipairs(M.roots(start_dir)) do
    if root.kind == "next-intl" then
      local candidate = util.path_join(root.path, lang .. ".json")
      if candidate == path then
        return true
      end
    end
  end
  return false
end

---@param namespace string
---@param key_path string
---@param start_dir string
---@param lang string
---@param path string
---@return string
function M.key_path_for_file(namespace, key_path, start_dir, lang, path)
  if M.is_next_intl_root_file(start_dir, lang, path) then
    if key_path == "" then
      return namespace
    end
    return namespace .. "." .. key_path
  end
  return key_path
end

---@param start_dir string
---@param on_change fun(event: table|nil)
---@param opts table|nil
---@return string|nil
function M.start_watch(start_dir, on_change, opts)
  if not start_dir or start_dir == "" then
    return
  end

  local roots = discovery.resolve_roots(start_dir)
  local key = discovery.compute_cache_key(roots, start_dir)
  if #roots == 0 then
    watcher.stop(key)
    return
  end

  local paths = discovery.watch_paths(roots)
  if #paths == 0 then
    if not (opts and opts._skip_refcount) then
      watcher.inc_refcount(key)
    end
    return key
  end

  local rescan_paths = {}
  for _, root in ipairs(roots) do
    rescan_paths[root.path] = true
  end

  watcher.start(key, {
    paths = paths,
    rescan_paths = rescan_paths,
    on_change = on_change,
    debounce_ms = (opts and opts.debounce_ms) or 200,
    skip_refcount = opts and opts._skip_refcount,
    restart_fn = function()
      M.start_watch(start_dir, on_change, {
        debounce_ms = opts and opts.debounce_ms,
        _skip_refcount = true,
      })
    end,
  })

  return key
end

---@param key string|nil
function M.stop_watch(key)
  watcher.stop(key)
end

---@param key string|nil
---@return boolean
function M.stop_watch_for_buffer(key)
  return watcher.stop_for_buffer(key)
end

---@param path string|nil
function M.mark_dirty(path)
  if not path or path == "" then
    mark_cache_dirty(nil)
    return
  end

  local normalized_path = discovery.normalize_path(path)
  if not normalized_path then
    mark_cache_dirty(nil)
    return
  end

  local matched = false
  for key, cache in pairs(M.caches) do
    if cache.roots then
      for _, root in ipairs(cache.roots) do
        local root_path = discovery.normalize_path(root.path)
        if root_path and discovery.path_under(normalized_path, root_path) then
          mark_cache_dirty(key)
          matched = true
          break
        end
      end
    end
  end
  if not matched then
    mark_cache_dirty(nil)
  end
end

---@param reader fun(path: string): string|nil
function M.set_reader(reader)
  M.reader = reader
  resource_io.set_reader(reader)
end

---@param start_dir string
---@return string|nil
function M.get_watcher_key(start_dir)
  if not start_dir or start_dir == "" then
    return nil
  end
  local roots = discovery.resolve_roots(start_dir)
  if #roots == 0 then
    return nil
  end
  return discovery.compute_cache_key(roots, start_dir)
end

return M
