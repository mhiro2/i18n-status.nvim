---@class I18nStatusResourceCache
local M = {}

local fs = require("i18n-status.fs")
local watcher = require("i18n-status.watcher")
local rpc = require("i18n-status.rpc")
local uv = vim.uv

local CACHE_VALIDATE_INTERVAL_MS = 1000

---@param resources I18nStatusResources
---@param roots I18nStatusResourceRoots
---@return I18nStatusResourceCache
function M.new(resources, roots)
  local service = {}

  ---@param cache I18nStatusCache
  ---@return boolean
  local function cache_files_unchanged(cache)
    local expected_files = roots.collect_resource_files(cache.roots or {})
    local expected_map = {}
    for _, file in ipairs(expected_files) do
      expected_map[file] = true
      local cached_mtime = cache.files and cache.files[file]
      if cached_mtime == nil then
        return false
      end
      local current_mtime = fs.file_mtime(file)
      if current_mtime == nil or current_mtime ~= cached_mtime then
        return false
      end
    end

    for cached_path, _ in pairs(cache.files or {}) do
      if not expected_map[cached_path] then
        return false
      end
    end

    return true
  end

  ---@param result I18nStatusCache
  ---@return I18nStatusCache
  local function normalize_index_result(result)
    local normalized_files = {}
    for path, mtime in pairs(result.files or {}) do
      local normalized = fs.normalize_path(path) or path
      normalized_files[normalized] = mtime
    end
    result.files = normalized_files

    for _, entries in pairs(result.index or {}) do
      for _, entry in pairs(entries or {}) do
        if entry then
          if entry.value == vim.NIL then
            entry.value = nil
          end
          if entry.file == vim.NIL then
            entry.file = nil
          else
            entry.file = fs.normalize_path(entry.file) or entry.file
          end
        end
      end
    end
    for _, entry in ipairs(result.errors or {}) do
      if entry.file and entry.file ~= vim.NIL then
        entry.file = fs.normalize_path(entry.file) or entry.file
      end
    end
    return result
  end

  ---@return I18nStatusCache
  local function empty_index_result()
    return {
      index = {},
      files = {},
      languages = {},
      errors = {},
      namespaces = {},
    }
  end

  ---@param root_list I18nStatusRootInfo[]
  ---@return I18nStatusCache
  function service.build_index(root_list)
    local result, err = rpc.request_sync("resource/buildIndex", {
      roots = root_list,
    })
    if err or not result then
      return empty_index_result()
    end
    return normalize_index_result(result)
  end

  ---@param root_list I18nStatusRootInfo[]
  ---@param cb fun(result: I18nStatusCache)
  function service.build_index_async(root_list, cb)
    rpc.request("resource/buildIndex", {
      roots = root_list,
    }, function(err, result)
      if err or not result then
        cb(empty_index_result())
        return
      end
      cb(normalize_index_result(result))
    end)
  end

  ---@param cache I18nStatusCache
  local function rebuild_aux_indexes(cache)
    cache.entries_by_key = {}
    cache.file_entries = {}
    cache.file_meta = {}
    cache.file_errors = cache.file_errors or {}

    for lang, entries in pairs(cache.index or {}) do
      cache.entries_by_key[lang] = cache.entries_by_key[lang] or {}
      for key, entry in pairs(entries or {}) do
        local file = fs.normalize_path(entry and entry.file)
        if file then
          cache.entries_by_key[lang][key] = cache.entries_by_key[lang][key] or {}
          table.insert(cache.entries_by_key[lang][key], {
            value = entry.value,
            file = file,
            priority = entry.priority or 0,
          })
          cache.file_entries[file] = cache.file_entries[file] or {}
          table.insert(cache.file_entries[file], {
            lang = lang,
            key = key,
            priority = entry.priority or 0,
          })
          if not cache.file_meta[file] then
            local info = roots.resource_info_from_roots(cache.roots or {}, file)
            if info then
              cache.file_meta[file] = {
                kind = info.kind,
                root = info.root,
                lang = info.lang,
                namespace = info.namespace,
                is_root = info.is_root,
              }
            end
          end
        end
      end
    end

    local new_file_errors = {}
    for _, entry in ipairs(cache.errors or {}) do
      if entry.file and entry.file ~= "" then
        local mtime = (cache.files and cache.files[entry.file]) or 0
        new_file_errors[entry.file] = { error = entry.error, mtime = mtime }
      end
    end
    for path, info in pairs(cache.file_errors or {}) do
      if not new_file_errors[path] then
        new_file_errors[path] = info
      end
    end
    cache.file_errors = new_file_errors
  end

  ---@param target table
  ---@param source table
  local function overwrite_table(target, source)
    for key in pairs(target) do
      target[key] = nil
    end
    for key, value in pairs(source) do
      target[key] = value
    end
  end

  ---@param key string
  ---@param cache I18nStatusCache|nil
  ---@return I18nStatusCache|nil
  local function cached_index_if_fresh(key, cache)
    if not cache or cache.dirty then
      return nil
    end
    resources.last_cache_key = key
    local watching = watcher.is_watching(key)
    if watching then
      local now = uv.now()
      if (now - (cache.checked_at or 0)) < CACHE_VALIDATE_INTERVAL_MS then
        return cache
      end
      cache.checked_at = now
      return cache
    end

    if cache_files_unchanged(cache) then
      cache.checked_at = uv.now()
      return cache
    end

    cache.dirty = true
    return nil
  end

  ---@param start_dir string
  ---@return string|nil
  ---@return I18nStatusCache|nil
  ---@return I18nStatusRootInfo[]
  local function watching_cache_for_start_dir(start_dir)
    local normalized_start = fs.normalize_path(start_dir) or start_dir
    local best_key = nil
    local best_cache = nil
    local best_roots = {}
    local best_len = -1

    for key, cache in pairs(resources.caches) do
      if cache and watcher.is_watching(key) and cache.roots and #cache.roots > 0 then
        for _, root in ipairs(cache.roots) do
          local root_path = fs.normalize_path(root.path)
          if
            root_path and (fs.path_under(normalized_start, root_path) or fs.path_under(root_path, normalized_start))
          then
            local root_len = #root_path
            if root_len > best_len then
              best_len = root_len
              best_key = key
              best_cache = cache
              best_roots = cache.roots
            end
          end
        end
      end
    end

    return best_key, best_cache, best_roots
  end

  ---@param key string
  ---@param cache I18nStatusCache|nil
  ---@param root_list I18nStatusRootInfo[]
  ---@param built I18nStatusCache
  ---@param opts? { rpc_cache_key?: string }
  ---@return I18nStatusCache
  local function store_built_index(key, cache, root_list, built, opts)
    built.key = key
    built.rpc_cache_key = (opts and opts.rpc_cache_key) or built.cache_key or key
    built.roots = root_list
    built.checked_at = uv.now()
    built.dirty = false
    rebuild_aux_indexes(built)

    if cache then
      overwrite_table(cache, built)
      resources.caches[key] = cache
      resources.last_cache_key = key
      return cache
    end

    resources.caches[key] = built
    resources.last_cache_key = key
    return built
  end

  ---@param start_dir string
  ---@param opts? { cooperative?: boolean }
  ---@return I18nStatusCache
  function service.ensure_index(start_dir, opts)
    opts = opts or {}
    start_dir = start_dir or vim.fn.getcwd()
    start_dir = fs.normalize_path(start_dir) or start_dir

    local key = nil
    local cache = nil
    local root_list = nil

    local watching_key, watching_cache, watching_roots = watching_cache_for_start_dir(start_dir)
    if watching_key and watching_cache then
      key = watching_key
      cache = watching_cache
      root_list = watching_roots
    else
      root_list = roots.resolve_roots_sync(start_dir)
      key = roots.compute_cache_key(root_list, start_dir)
      cache = resources.caches[key]
    end

    local reused = cached_index_if_fresh(key, cache)
    if reused then
      return reused
    end

    local co = coroutine.running()
    if opts.cooperative and co then
      pcall(coroutine.yield)
    end

    local built = resources.build_index(root_list)
    return store_built_index(key, cache, root_list, built)
  end

  ---@param start_dir string
  ---@param opts? { cooperative?: boolean }
  ---@param cb fun(cache: I18nStatusCache)
  function service.ensure_index_async(start_dir, opts, cb)
    opts = opts or {}
    start_dir = start_dir or vim.fn.getcwd()
    start_dir = fs.normalize_path(start_dir) or start_dir

    rpc.request("resource/resolveRoots", {
      start_dir = start_dir,
    }, function(roots_err, roots_result)
      local root_list = {}
      if not roots_err and roots_result and roots_result.roots then
        root_list = roots.normalize_roots(roots_result.roots)
      end

      local key = roots.compute_cache_key(root_list, start_dir)
      local cache = resources.caches[key]
      local reused = cached_index_if_fresh(key, cache)
      if reused then
        cb(reused)
        return
      end

      resources.build_index_async(root_list, function(built)
        cb(store_built_index(key, cache, root_list, built))
      end)
    end)
  end

  ---@param cache I18nStatusCache
  ---@param path string
  ---@param err string
  local function set_file_error(cache, path, err)
    cache.file_errors = cache.file_errors or {}
    cache.file_errors[path] = {
      error = err,
      mtime = fs.file_mtime(path) or 0,
    }
    local file_meta = cache.file_meta and cache.file_meta[path]
    local lang = (file_meta and file_meta.lang) or "unknown"
    local replaced = false
    cache.errors = cache.errors or {}
    for _, entry in ipairs(cache.errors) do
      if entry.file == path then
        entry.error = err
        entry.lang = lang
        replaced = true
        break
      end
    end
    if not replaced then
      table.insert(cache.errors, {
        lang = lang,
        file = path,
        error = err,
      })
    end
  end

  ---@param cache I18nStatusCache
  ---@param path string
  local function clear_file_error(cache, path)
    if cache.file_errors then
      cache.file_errors[path] = nil
    end
    if cache.errors then
      for i = #cache.errors, 1, -1 do
        if cache.errors[i].file == path then
          table.remove(cache.errors, i)
        end
      end
    end
  end

  ---@param cache_key string
  ---@param paths string[]
  ---@param opts { force?: boolean }|nil
  ---@return boolean
  ---@return boolean|nil
  function service.apply_changes(cache_key, paths, opts)
    opts = opts or {}
    local cache = resources.caches[cache_key]
    if not cache then
      return false, true
    end

    local changed_valid_json = false
    local rpc_paths = {}

    for _, raw_path in ipairs(paths or {}) do
      local path = fs.normalize_path(raw_path) or raw_path

      local stat = uv.fs_stat(path)
      if stat and stat.type == "directory" then
        return false, true
      end

      local within_root = false
      for _, root in ipairs(cache.roots or {}) do
        local root_path = fs.normalize_path(root.path)
        if root_path and fs.path_under(path, root_path) then
          within_root = true
          break
        end
      end
      if not within_root then
        return false, true
      end

      if path:sub(-5) ~= ".json" then
        return false, true
      end

      if stat and stat.type == "file" then
        local data, read_err = resources.read_json_table(path)
        if data then
          changed_valid_json = true
          rpc_paths[#rpc_paths + 1] = path
        else
          set_file_error(cache, path, (read_err and read_err.error) or "json parse error")
        end
      else
        changed_valid_json = true
        rpc_paths[#rpc_paths + 1] = path
      end
    end

    if changed_valid_json and #rpc_paths > 0 then
      local rpc_result, rpc_err = rpc.request_sync("resource/applyChanges", {
        cache_key = cache.rpc_cache_key or cache_key,
        paths = rpc_paths,
      })

      ---@param built I18nStatusCache
      ---@param rpc_key string
      local function finalize_built(built, rpc_key)
        local stored = store_built_index(cache_key, cache, cache.roots or {}, built, {
          rpc_cache_key = rpc_key,
        })
        for _, path in ipairs(rpc_paths) do
          clear_file_error(stored, path)
        end
      end

      if not rpc_err and rpc_result and rpc_result.success and not rpc_result.needs_rebuild and rpc_result.result then
        finalize_built(normalize_index_result(rpc_result.result), cache.rpc_cache_key or cache_key)
        return true, false
      end

      local built = resources.build_index(cache.roots or {})
      finalize_built(built, built.cache_key or cache.rpc_cache_key or cache_key)
    end

    return true, false
  end

  return service
end

return M
