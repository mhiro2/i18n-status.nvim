---@class I18nStatusResources
local M = {
  reader = nil,
  caches = {},
  last_cache_key = nil,
}

local util = require("i18n-status.util")
local watcher = require("i18n-status.watcher")
local resource_io = require("i18n-status.resource_io")
local rpc = require("i18n-status.rpc")

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
---@field rpc_cache_key string|nil
---@field index table<string, table<string, I18nStatusResourceItem>>
---@field files table<string, integer>
---@field languages string[]
---@field roots I18nStatusRootInfo[]
---@field errors I18nStatusResourceError[]
---@field namespaces string[]
---@field dirty boolean
---@field checked_at integer

local uv = vim.uv
local CACHE_VALIDATE_INTERVAL_MS = 1000
local WATCH_MAX_FILES = 200
local WATCH_PATHS_CACHE_TTL_MS = 1000

---@type table<string, { paths: string[], signature: string, updated_at: integer }>
local watch_paths_cache = {}

---@return I18nStatusCache|nil
local function current_cache()
  if M.last_cache_key then
    return M.caches[M.last_cache_key]
  end
  return nil
end

---@param key string|nil
local function mark_cache_dirty(key)
  watch_paths_cache = {}
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

---@param roots table
---@param start_dir string
---@return string
local function compute_cache_key(roots, start_dir)
  if not roots or #roots == 0 then
    return "empty:" .. (start_dir or "")
  end
  local normalized = {}
  for _, root in ipairs(roots or {}) do
    normalized[#normalized + 1] = {
      kind = root.kind,
      path = root.path,
    }
  end
  table.sort(normalized, function(a, b)
    if a.kind == b.kind then
      return a.path < b.path
    end
    return a.kind < b.kind
  end)
  return vim.json.encode(normalized)
end

---@param roots table
---@return table
local function normalize_roots(roots)
  local normalized = {}
  for _, root in ipairs(roots or {}) do
    local root_path = util.normalize_path(root.path) or root.path
    normalized[#normalized + 1] = {
      kind = root.kind,
      path = root_path,
    }
  end
  table.sort(normalized, function(a, b)
    if a.kind == b.kind then
      return a.path < b.path
    end
    return a.kind < b.kind
  end)
  return normalized
end

---@param root string
---@return string[]
local function list_dirs(root)
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
      dirs[#dirs + 1] = name
    end
  end
  return dirs
end

---@param root string
---@return string[]
local function list_json_files(root)
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
      files[#files + 1] = util.path_join(root, name)
    end
  end
  return files
end

---@param path string
---@return integer|nil
local function file_mtime_ns(path)
  local stat = uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end
  local nsec = stat.mtime.nsec or 0
  return stat.mtime.sec * 1000000000 + nsec
end

---@param roots table
---@return string[]
local function collect_resource_files(roots)
  local files = {}
  local seen = {}

  local function add(path)
    local normalized = util.normalize_path(path) or path
    if normalized and normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      files[#files + 1] = normalized
    end
  end

  for _, root in ipairs(roots or {}) do
    local root_path = util.normalize_path(root.path) or root.path
    if root.kind == "i18next" then
      for _, dir in ipairs(list_dirs(root_path)) do
        local lang_root = util.path_join(root_path, dir)
        for _, file in ipairs(list_json_files(lang_root)) do
          add(file)
        end
      end
    elseif root.kind == "next-intl" or root.kind == "next_intl" then
      for _, file in ipairs(list_json_files(root_path)) do
        add(file)
      end
      for _, dir in ipairs(list_dirs(root_path)) do
        local lang_root = util.path_join(root_path, dir)
        for _, file in ipairs(list_json_files(lang_root)) do
          add(file)
        end
      end
    end
  end

  table.sort(files)
  return files
end

---@param cache I18nStatusCache
---@return boolean
local function cache_files_unchanged(cache)
  local expected_files = collect_resource_files(cache.roots or {})
  local expected_map = {}
  for _, file in ipairs(expected_files) do
    expected_map[file] = true
    local cached_mtime = cache.files and cache.files[file]
    if cached_mtime == nil then
      return false
    end
    local current_mtime = file_mtime_ns(file)
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

---@param roots table
---@return string|nil
local function roots_key(roots)
  if not roots or #roots == 0 then
    return nil
  end
  local parts = {}
  for _, root in ipairs(roots or {}) do
    parts[#parts + 1] = root.kind .. ":" .. root.path
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

---@param roots table
---@param opts? { force?: boolean }
---@return string[]
local function watch_paths(roots, opts)
  opts = opts or {}
  local force = opts.force == true
  local key = roots_key(roots) or "__none__"
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

  for _, root in ipairs(roots or {}) do
    add(root.path)
    for _, dir in ipairs(list_dirs(root.path)) do
      local lang_root = util.path_join(root.path, dir)
      add(lang_root)
      if watched_files < WATCH_MAX_FILES then
        for _, file in ipairs(list_json_files(lang_root)) do
          add(file)
          watched_files = watched_files + 1
          if watched_files >= WATCH_MAX_FILES then
            break
          end
        end
      end
    end

    if root.kind == "next-intl" or root.kind == "next_intl" then
      if watched_files < WATCH_MAX_FILES then
        for _, file in ipairs(list_json_files(root.path)) do
          add(file)
          watched_files = watched_files + 1
          if watched_files >= WATCH_MAX_FILES then
            break
          end
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
---@param path string
---@return table|nil
local function resource_info_from_roots(roots, path)
  if not path or path == "" then
    return nil
  end
  local normalized = path:gsub("\\", "/")
  for _, root in ipairs(roots or {}) do
    local root_path = root.path:gsub("\\", "/")
    if root_path:sub(-1) ~= "/" then
      root_path = root_path .. "/"
    end
    if normalized:sub(1, #root_path) == root_path then
      local relative = normalized:sub(#root_path + 1)
      if root.kind == "i18next" then
        -- i18next: locales/{lang}/{namespace}.json
        local lang, ns_file = relative:match("^([^/]+)/(.+)$")
        if lang and ns_file then
          local namespace = ns_file:gsub("%.json$", "")
          return {
            kind = root.kind,
            root = root.path,
            lang = lang,
            namespace = namespace,
            is_root = false,
          }
        end
      elseif root.kind == "next-intl" or root.kind == "next_intl" then
        -- next-intl: messages/{lang}.json or messages/{lang}/{namespace}.json
        local lang_only = relative:match("^([^/]+)%.json$")
        if lang_only then
          return {
            kind = root.kind,
            root = root.path,
            lang = lang_only,
            namespace = nil,
            is_root = true,
          }
        end
        local lang, ns_file = relative:match("^([^/]+)/(.+)$")
        if lang and ns_file then
          local namespace = ns_file:gsub("%.json$", "")
          return {
            kind = root.kind,
            root = root.path,
            lang = lang,
            namespace = namespace,
            is_root = false,
          }
        end
      end
    end
  end
  return nil
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
  start_dir = util.normalize_path(start_dir) or start_dir

  if not roots or #roots == 0 then
    local roots_result, roots_err = rpc.request_sync("resource/resolveRoots", {
      start_dir = start_dir,
    })
    if not roots_err and roots_result and roots_result.roots then
      roots = normalize_roots(roots_result.roots)
    else
      roots = roots or {}
    end
  end

  -- Find git root or use the parent of the first resource root
  local git_root = util.find_git_root(start_dir)
  if git_root then
    return git_root
  end

  local paths = { start_dir }
  for _, root in ipairs(roots or {}) do
    if root and root.path and root.path ~= "" then
      paths[#paths + 1] = root.path
    end
  end
  if #paths == 0 then
    return start_dir
  end
  if #paths == 1 then
    local dir = start_dir
    while dir and dir ~= "" and dir ~= "/" do
      if
        util.is_dir(util.path_join(dir, "locales"))
        or util.is_dir(util.path_join(dir, "messages"))
        or util.is_dir(util.path_join(dir, "public", "locales"))
        or util.is_dir(util.path_join(dir, "public", "messages"))
      then
        return dir
      end
      local parent = util.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
    return start_dir
  end

  local common = paths[1]
  for i = 2, #paths do
    local parts1 = vim.split(common, "/", { plain = true })
    local parts2 = vim.split(paths[i], "/", { plain = true })
    local min_len = math.min(#parts1, #parts2)
    local new_common = {}
    for j = 1, min_len do
      if parts1[j] == parts2[j] then
        new_common[#new_common + 1] = parts1[j]
      else
        break
      end
    end
    common = table.concat(new_common, "/")
    if common == "" then
      return start_dir
    end
  end
  return common
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
---@return boolean ok
---@return string|nil err
function M.write_json_table(path, data, style, opts)
  local io_opts = vim.tbl_extend("force", opts or {}, { mark_dirty = M.mark_dirty })
  return resource_io.write_json_table(path, data, style, io_opts)
end

---@param result table
---@return table
local function normalize_index_result(result)
  local normalized_files = {}
  for path, mtime in pairs(result.files or {}) do
    local normalized = util.normalize_path(path) or path
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
          entry.file = util.normalize_path(entry.file) or entry.file
        end
      end
    end
  end
  for _, entry in ipairs(result.errors or {}) do
    if entry.file and entry.file ~= vim.NIL then
      entry.file = util.normalize_path(entry.file) or entry.file
    end
  end
  return result
end

---@return table
local function empty_index_result()
  return {
    index = {},
    files = {},
    languages = {},
    errors = {},
    namespaces = {},
  }
end

---@param roots table
---@return table
function M.build_index(roots)
  local result, err = rpc.request_sync("resource/buildIndex", {
    roots = roots,
  })
  if err or not result then
    return empty_index_result()
  end
  return normalize_index_result(result)
end

---@param roots table
---@param cb fun(result: table)
function M.build_index_async(roots, cb)
  rpc.request("resource/buildIndex", {
    roots = roots,
  }, function(err, result)
    if err or not result then
      cb(empty_index_result())
      return
    end
    cb(normalize_index_result(result))
  end)
end

---@param cache table
local function rebuild_aux_indexes(cache)
  cache.entries_by_key = {}
  cache.file_entries = {}
  cache.file_meta = {}
  cache.file_errors = cache.file_errors or {}

  for lang, entries in pairs(cache.index or {}) do
    cache.entries_by_key[lang] = cache.entries_by_key[lang] or {}
    for key, entry in pairs(entries or {}) do
      local file = util.normalize_path(entry and entry.file)
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
          local info = resource_info_from_roots(cache.roots or {}, file)
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
---@param cache table|nil
---@return table|nil
local function cached_index_if_fresh(key, cache)
  if not cache or cache.dirty then
    return nil
  end
  M.last_cache_key = key
  local watching = watcher.is_watching(key)
  if watching then
    local now = uv.now()
    if (now - (cache.checked_at or 0)) < CACHE_VALIDATE_INTERVAL_MS then
      return cache
    end
    cache.checked_at = now
    -- For the watcher path, trust the watcher and return cached
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
---@return table|nil
---@return table
local function watching_cache_for_start_dir(start_dir)
  local normalized_start = util.normalize_path(start_dir) or start_dir
  local best_key = nil
  local best_cache = nil
  local best_roots = {}
  local best_len = -1

  for key, cache in pairs(M.caches) do
    if cache and watcher.is_watching(key) and cache.roots and #cache.roots > 0 then
      for _, root in ipairs(cache.roots) do
        local root_path = util.normalize_path(root.path)
        if
          root_path and (util.path_under(normalized_start, root_path) or util.path_under(root_path, normalized_start))
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

---@param start_dir string
---@return table
local function resolve_roots_sync(start_dir)
  local roots_result, roots_err = rpc.request_sync("resource/resolveRoots", {
    start_dir = start_dir,
  })
  if not roots_err and roots_result and roots_result.roots then
    return normalize_roots(roots_result.roots)
  end
  return {}
end

---@param key string
---@param cache table|nil
---@param roots table
---@param built table
---@return table
local function store_built_index(key, cache, roots, built)
  built.key = key
  built.rpc_cache_key = built.cache_key or key
  built.roots = roots
  built.checked_at = uv.now()
  built.dirty = false
  rebuild_aux_indexes(built)

  if cache then
    overwrite_table(cache, built)
    M.caches[key] = cache
    M.last_cache_key = key
    return cache
  end

  M.caches[key] = built
  M.last_cache_key = key
  return built
end

---@param start_dir string
---@param opts? { cooperative?: boolean }
---@return table
function M.ensure_index(start_dir, opts)
  opts = opts or {}
  start_dir = start_dir or vim.fn.getcwd()
  start_dir = util.normalize_path(start_dir) or start_dir

  local key = nil
  local cache = nil
  local roots = nil

  -- Fast path: when a watcher is active for this project, reuse its roots and
  -- avoid resolveRoots RPC on hot refresh paths.
  local watching_key, watching_cache, watching_roots = watching_cache_for_start_dir(start_dir)
  if watching_key and watching_cache then
    key = watching_key
    cache = watching_cache
    roots = watching_roots
  else
    roots = resolve_roots_sync(start_dir)
    key = compute_cache_key(roots, start_dir)
    cache = M.caches[key]
  end

  local reused = cached_index_if_fresh(key, cache)
  if reused then
    return reused
  end

  local co = coroutine.running()
  if opts.cooperative and co then
    pcall(coroutine.yield)
  end

  local built = M.build_index(roots)
  return store_built_index(key, cache, roots, built)
end

---@param start_dir string
---@param opts? { cooperative?: boolean }
---@param cb fun(cache: table)
function M.ensure_index_async(start_dir, opts, cb)
  opts = opts or {}
  start_dir = start_dir or vim.fn.getcwd()

  rpc.request("resource/resolveRoots", {
    start_dir = start_dir,
  }, function(roots_err, roots_result)
    local roots = {}
    if not roots_err and roots_result and roots_result.roots then
      roots = normalize_roots(roots_result.roots)
    end

    local key = compute_cache_key(roots, start_dir)
    local cache = M.caches[key]
    local reused = cached_index_if_fresh(key, cache)
    if reused then
      cb(reused)
      return
    end

    M.build_index_async(roots, function(built)
      cb(store_built_index(key, cache, roots, built))
    end)
  end)
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

  local function set_file_error(path, err)
    cache.file_errors = cache.file_errors or {}
    cache.file_errors[path] = {
      error = err,
      mtime = util.file_mtime(path) or 0,
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

  local function clear_file_error(path)
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

  local changed_valid_json = false
  local rpc_paths = {}

  for _, raw_path in ipairs(paths or {}) do
    local path = util.normalize_path(raw_path) or raw_path

    local stat = uv.fs_stat(path)
    if stat and stat.type == "directory" then
      return false, true
    end

    local within_root = false
    for _, root in ipairs(cache.roots or {}) do
      local root_path = util.normalize_path(root.path)
      if root_path and util.path_under(path, root_path) then
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
      local data, read_err = M.read_json_table(path)
      if data then
        changed_valid_json = true
        rpc_paths[#rpc_paths + 1] = path
      else
        set_file_error(path, (read_err and read_err.error) or "json parse error")
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

    if not rpc_err and rpc_result and rpc_result.success and not rpc_result.needs_rebuild and rpc_result.result then
      local built = normalize_index_result(rpc_result.result)
      built.key = cache_key
      built.rpc_cache_key = cache.rpc_cache_key or cache_key
      built.roots = cache.roots or {}
      built.checked_at = uv.now()
      built.dirty = false
      rebuild_aux_indexes(built)
      for _, path in ipairs(rpc_paths) do
        clear_file_error(path)
      end
      overwrite_table(cache, built)
      M.caches[cache_key] = cache
      return true, false
    end

    if rpc_result and rpc_result.needs_rebuild then
      local built = M.build_index(cache.roots or {})
      built.key = cache_key
      built.rpc_cache_key = built.cache_key or cache.rpc_cache_key or cache_key
      built.roots = cache.roots or {}
      built.checked_at = uv.now()
      built.dirty = false
      rebuild_aux_indexes(built)
      for _, path in ipairs(rpc_paths) do
        clear_file_error(path)
      end
      overwrite_table(cache, built)
      M.caches[cache_key] = cache
      return true, false
    end

    -- Fallback path: if RPC incremental update is unavailable, rebuild from source.
    local built = M.build_index(cache.roots or {})
    built.key = cache_key
    built.rpc_cache_key = built.cache_key or cache.rpc_cache_key or cache_key
    built.roots = cache.roots or {}
    built.checked_at = uv.now()
    built.dirty = false
    rebuild_aux_indexes(built)
    for _, path in ipairs(rpc_paths) do
      clear_file_error(path)
    end
    overwrite_table(cache, built)
    M.caches[cache_key] = cache
  end

  return true, false
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
    if root.kind == "next-intl" or root.kind == "next_intl" then
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
  return resource_info_from_roots(roots, path)
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
    if root.kind == "next-intl" or root.kind == "next_intl" then
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

  local roots_result, roots_err = rpc.request_sync("resource/resolveRoots", {
    start_dir = start_dir,
  })
  local roots = {}
  if not roots_err and roots_result and roots_result.roots then
    roots = normalize_roots(roots_result.roots)
  end
  local key = compute_cache_key(roots, start_dir)
  if #roots == 0 then
    watcher.stop(key)
    return
  end

  local paths = watch_paths(roots)
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

  local normalized_path = path:gsub("\\", "/")
  local matched = false
  for key, cache in pairs(M.caches) do
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
  local roots_result, roots_err = rpc.request_sync("resource/resolveRoots", {
    start_dir = start_dir,
  })
  local roots = {}
  if not roots_err and roots_result and roots_result.roots then
    roots = normalize_roots(roots_result.roots)
  end
  if #roots == 0 then
    return nil
  end
  return compute_cache_key(roots, start_dir)
end

return M
