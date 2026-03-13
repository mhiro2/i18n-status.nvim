---@class I18nStatusResourceWatchService
local M = {}

local fs = require("i18n-status.fs")
local watcher = require("i18n-status.watcher")

local uv = vim.uv

local WATCH_MAX_FILES = 200
local WATCH_PATHS_CACHE_TTL_MS = 1000

---@param resources I18nStatusResources
---@param roots I18nStatusResourceRoots
---@return I18nStatusResourceWatchService
function M.new(resources, roots)
  local service = {}

  ---@type table<string, { paths: string[], updated_at: integer }>
  local watch_paths_cache = {}

  ---@param key string|nil
  local function mark_cache_dirty(key)
    watch_paths_cache = {}
    if key then
      local cache = resources.caches[key]
      if cache then
        cache.dirty = true
        cache.checked_at = 0
      end
      return
    end
    for _, cache in pairs(resources.caches) do
      cache.dirty = true
      cache.checked_at = 0
    end
  end

  ---@param root_list I18nStatusRootInfo[]
  ---@return string|nil
  local function roots_key(root_list)
    if not root_list or #root_list == 0 then
      return nil
    end
    local parts = {}
    for _, root in ipairs(root_list or {}) do
      parts[#parts + 1] = root.kind .. ":" .. root.path
    end
    table.sort(parts)
    return table.concat(parts, "|")
  end

  ---@param root_list I18nStatusRootInfo[]
  ---@param opts? { force?: boolean }
  ---@return string[]
  local function watch_paths(root_list, opts)
    opts = opts or {}
    local force = opts.force == true
    local key = roots_key(root_list) or "__none__"
    local now = uv.now()
    local cached = watch_paths_cache[key]
    if not force and cached and (now - cached.updated_at) < WATCH_PATHS_CACHE_TTL_MS then
      return cached.paths
    end

    local paths = {}
    local seen = {}
    local watched_files = 0

    local function add(path)
      if path and path ~= "" and not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end

    for _, root in ipairs(root_list or {}) do
      add(root.path)
      for _, dir in ipairs(roots.list_dirs(root.path)) do
        local lang_root = fs.path_join(root.path, dir)
        add(lang_root)
        if watched_files < WATCH_MAX_FILES then
          for _, file in ipairs(roots.list_json_files(lang_root)) do
            add(file)
            watched_files = watched_files + 1
            if watched_files >= WATCH_MAX_FILES then
              break
            end
          end
        end
      end

      if roots.is_next_intl_kind(root.kind) and watched_files < WATCH_MAX_FILES then
        for _, file in ipairs(roots.list_json_files(root.path)) do
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
      updated_at = now,
    }
    return paths
  end

  ---@param start_dir string
  ---@param on_change fun(event: table|nil)
  ---@param opts? { debounce_ms?: integer, _skip_refcount?: boolean, roots?: I18nStatusRootInfo[], cache_key?: string }
  ---@return string|nil
  function service.start_watch(start_dir, on_change, opts)
    opts = opts or {}
    if not start_dir or start_dir == "" then
      return
    end

    local root_list = opts.roots
    local key = opts.cache_key
    if root_list then
      root_list = roots.normalize_roots(root_list)
      if not key and #root_list > 0 then
        key = roots.compute_cache_key(root_list, start_dir)
      end
    else
      key, root_list = service.resolve_watch_target(start_dir)
    end
    if not key or not root_list or #root_list == 0 then
      if key then
        watcher.stop(key)
      end
      return
    end

    local paths = watch_paths(root_list)
    if #paths == 0 then
      if not opts._skip_refcount then
        watcher.inc_refcount(key)
      end
      return key
    end

    local rescan_paths = {}
    for _, root in ipairs(root_list) do
      rescan_paths[root.path] = true
    end

    watcher.start(key, {
      paths = paths,
      rescan_paths = rescan_paths,
      on_change = on_change,
      debounce_ms = opts.debounce_ms or 200,
      skip_refcount = opts._skip_refcount,
      restart_fn = function()
        service.start_watch(start_dir, on_change, {
          debounce_ms = opts.debounce_ms,
          _skip_refcount = true,
        })
      end,
    })

    return key
  end

  ---@param start_dir string
  ---@return string|nil
  ---@return I18nStatusRootInfo[]
  function service.resolve_watch_target(start_dir)
    if not start_dir or start_dir == "" then
      return nil, {}
    end
    local normalized_start = fs.normalize_path(start_dir) or start_dir
    local root_list = roots.resolve_roots_sync(normalized_start)
    if #root_list == 0 then
      return nil, root_list
    end
    return roots.compute_cache_key(root_list, normalized_start), root_list
  end

  ---@param key string|nil
  function service.stop_watch(key)
    watcher.stop(key)
  end

  ---@param key string|nil
  ---@return boolean
  function service.stop_watch_for_buffer(key)
    return watcher.stop_for_buffer(key)
  end

  ---@param path string|nil
  function service.mark_dirty(path)
    if not path or path == "" then
      mark_cache_dirty(nil)
      return
    end

    local normalized_path = path:gsub("\\", "/")
    local matched = false
    for key, cache in pairs(resources.caches) do
      if cache.roots then
        for _, root in ipairs(cache.roots) do
          local root_path = (root.path or ""):gsub("\\", "/")
          if root_path:sub(-1) ~= "/" then
            root_path = root_path .. "/"
          end
          if normalized_path:sub(1, #root_path) == root_path then
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

  ---@param start_dir string
  ---@return string|nil
  function service.get_watcher_key(start_dir)
    local key = service.resolve_watch_target(start_dir)
    return key
  end

  return service
end

return M
