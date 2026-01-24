---@class I18nStatusResources
local M = {
  reader = nil,
  caches = {},
  watchers = {},
  watcher_refcounts = {},
  last_cache_key = nil,
}

local util = require("i18n-status.util")
local uv = vim.uv or vim.loop

local CACHE_VALIDATE_INTERVAL_MS = 1000
local WATCH_MAX_FILES = 200

local WATCHER_ERROR_THROTTLE_MS = 60000
local watcher_error_timestamps = {}

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  local real = uv.fs_realpath(path)
  local normalized = real or path
  normalized = normalized:gsub("\\", "/")
  return normalized
end

local function path_under(path, root)
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

---@param handle userdata|nil
local function safe_close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end)
end

---@param path string
---@param err string
local function log_watcher_error(path, err)
  local now = uv.now()
  local last_logged = watcher_error_timestamps[path] or 0
  if (now - last_logged) < WATCHER_ERROR_THROTTLE_MS then
    return
  end
  watcher_error_timestamps[path] = now
  vim.notify(string.format("i18n-status: file watcher error for %s: %s", path, err), vim.log.levels.WARN)
end

local function current_cache()
  if M.last_cache_key then
    return M.caches[M.last_cache_key]
  end
  return nil
end

---@param key string|nil
local function mark_cache_dirty(key)
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
    -- Buffers may point at files under directories that don't exist yet (e.g. unsaved/new files).
    -- In that case, walk up until we find an existing directory so that find_up() can work.
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

---@param key string
---@return boolean
local function is_watching(key)
  local watch = M.watchers[key]
  return watch and watch.signature ~= nil and watch.handles ~= nil and #watch.handles > 0
end

---@class I18nStatusResourceItem
---@field value string
---@field file string

---@class I18nStatusResourceError
---@field lang string
---@field file string
---@field error string

---@param path string
---@return string|nil
local function read_file(path)
  if M.reader then
    return M.reader(path)
  end
  return util.read_file(path)
end

---@param path string
---@return table|nil
---@return string|nil
local function read_json(path)
  local content = read_file(path)
  if not content then
    return nil, "read failed"
  end
  local decoded, err = util.json_decode(content)
  if not decoded then
    return nil, err
  end
  return decoded, nil
end

---@param path string
---@return table
---@return table
function M.read_json_table(path)
  if not util.file_exists(path) then
    return {}, { indent = "  ", newline = true }
  end
  local content = read_file(path)
  if not content then
    return {}, { indent = "  ", newline = true }
  end
  local decoded, err = util.json_decode(content)
  local style = {
    indent = util.detect_indent(content),
    newline = content:sub(-1) == "\n",
  }
  if not decoded then
    style.error = err
    return nil, style
  end
  if type(decoded) ~= "table" then
    return {}, style
  end
  return decoded, style
end

---@param path string
---@param data table
---@param style table|nil
---@param _opts table|nil
function M.write_json_table(path, data, style, _opts)
  local indent = (style and style.indent) or "  "
  local newline = style and style.newline
  local encoded = util.json_encode_pretty(data, indent)
  if newline then
    encoded = encoded .. "\n"
  end

  -- Write to temporary file first, then rename for atomicity
  local tmp_path = path .. ".tmp." .. uv.getpid()
  local fd = uv.fs_open(tmp_path, "w", 420)
  if fd then
    uv.fs_write(fd, encoded, 0)
    uv.fs_fsync(fd)
    uv.fs_close(fd)
    local ok, err = uv.fs_rename(tmp_path, path)
    if ok then
      M.mark_dirty(path)
    else
      local err_msg = tostring(err or "")
      local is_exists = err_msg:lower():find("eexist") or err_msg:lower():find("exists")
      if is_exists then
        pcall(uv.fs_unlink, path)
        ok, err = uv.fs_rename(tmp_path, path)
        if ok then
          M.mark_dirty(path)
          return
        end
      end
      pcall(uv.fs_unlink, tmp_path)
      vim.schedule(function()
        vim.notify(
          string.format("i18n-status: failed to rename %s to %s: %s", tmp_path, path, err or "unknown"),
          vim.log.levels.WARN
        )
      end)
    end
  else
    vim.schedule(function()
      vim.notify("i18n-status: failed to write json file (" .. path .. ")", vim.log.levels.WARN)
    end)
  end
end

---@param index table
---@param lang string
---@param key string
---@param value any
---@param file string
---@param priority integer
local function set_entry(index, lang, key, value, file, priority)
  index[lang] = index[lang] or {}
  local existing = index[lang][key]
  local existing_priority = existing and existing.priority or math.huge
  if existing_priority <= priority then
    return
  end
  index[lang][key] = { value = value, file = file, priority = priority }
end

---@param lang string
---@param namespace string
---@param data table
---@param index table
---@param file string
---@param priority integer
local function merge_namespace(lang, namespace, data, index, file, priority)
  local flat = util.flatten_table(data)
  for key, value in pairs(flat) do
    local canonical = namespace .. ":" .. key
    set_entry(index, lang, canonical, value, file, priority)
  end
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
      table.insert(dirs, name)
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
      table.insert(files, util.path_join(root, name))
    end
  end
  return files
end

---@param root string
---@return table, table, table, I18nStatusResourceError[]
local function load_i18next(root)
  local index = {}
  local files = {}
  local languages = {}
  local errors = {}
  for _, lang in ipairs(list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, path in ipairs(list_json_files(lang_root)) do
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = read_json(path)
      files[path] = util.file_mtime(path)
      if data then
        merge_namespace(lang, namespace, data, index, path, 30)
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, path, 1)
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end
  end
  return index, files, languages, errors
end

---@param root string
---@return table, table, table, I18nStatusResourceError[]
local function load_next_intl(root)
  local index = {}
  local files = {}
  local languages = {}
  local errors = {}
  for _, lang in ipairs(list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, path in ipairs(list_json_files(lang_root)) do
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = read_json(path)
      files[path] = util.file_mtime(path)
      if data then
        merge_namespace(lang, namespace, data, index, path, 50)
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, path, 1)
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end
    local root_file = util.path_join(root, lang .. ".json")
    if util.file_exists(root_file) then
      local data, err = read_json(root_file)
      files[root_file] = util.file_mtime(root_file)
      if data then
        for ns, ns_data in pairs(data) do
          if type(ns_data) == "table" then
            merge_namespace(lang, ns, ns_data, index, root_file, 40)
          end
        end
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, root_file, 1)
        table.insert(errors, { lang = lang, file = root_file, error = message })
      end
    end
  end
  return index, files, languages, errors
end

---@param roots table
---@return string|nil
local function roots_key(roots)
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
local function compute_cache_key(roots, start_dir)
  local key = roots_key(roots)
  if key then
    return key
  end
  return "__none__:" .. (start_dir or "")
end

---@param index table
---@return string[]
local function collect_namespaces(index)
  local set = {}
  for _, items in pairs(index or {}) do
    for key, _ in pairs(items) do
      if key ~= "__error__" then
        local ns = key:match("^(.-):")
        if ns then
          set[ns] = true
        end
      end
    end
  end
  local out = {}
  for ns, _ in pairs(set) do
    table.insert(out, ns)
  end
  table.sort(out)
  return out
end

---@param start_dir string
---@return table
local function resolve_roots(start_dir)
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
---@return string[]
local function watch_paths(roots)
  -- NOTE: watcher setup should be cheap; avoid building the full index here.
  local paths = {}
  local seen = {}
  local watched_files = 0
  local function add(path)
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end
  for _, root in ipairs(roots) do
    add(root.path)
    for _, dir in ipairs(list_dirs(root.path)) do
      local lang_root = util.path_join(root.path, dir)
      add(lang_root)
      -- Hybrid mode: prefer directory watches for scalability, but also watch a
      -- limited number of json files for reliability on some platforms.
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
    -- next-intl root files: messages/{lang}.json lives under root.path
    if root.kind == "next-intl" and watched_files < WATCH_MAX_FILES then
      for _, file in ipairs(list_json_files(root.path)) do
        add(file)
        watched_files = watched_files + 1
        if watched_files >= WATCH_MAX_FILES then
          break
        end
      end
    end
  end
  table.sort(paths)
  return paths
end

---Compute structural signature for cache validation (detects new/deleted files)
---@param roots table
---@return string|nil signature, or nil if no roots
local function compute_structural_signature(roots)
  if not roots or #roots == 0 then
    return nil
  end
  local paths = watch_paths(roots)
  return table.concat(paths, "|")
end

---@param roots table
---@param key string
---@return boolean
local function cache_valid_structural(roots, key)
  local watch = M.watchers[key]
  if not watch or not watch.signature then
    return false
  end
  local signature = table.concat(watch_paths(roots), "|")
  return signature == watch.signature
end

---@param roots table
---@return table
function M.build_index(roots)
  roots = roots or {}
  local merged_index = {}
  local files = {}
  local languages = {}
  local lang_seen = {}
  local errors = {}
  for _, root in ipairs(roots) do
    local index, root_files, root_langs, root_errors = {}, {}, {}, {}
    if root.kind == "i18next" then
      index, root_files, root_langs, root_errors = load_i18next(root.path)
    else
      index, root_files, root_langs, root_errors = load_next_intl(root.path)
    end
    for path, mtime in pairs(root_files) do
      files[path] = mtime
    end
    for _, lang in ipairs(root_langs) do
      if not lang_seen[lang] then
        lang_seen[lang] = true
        table.insert(languages, lang)
      end
    end
    for lang, items in pairs(index) do
      merged_index[lang] = merged_index[lang] or {}
      for key, value in pairs(items) do
        merged_index[lang][key] = value
      end
    end
    for _, entry in ipairs(root_errors) do
      table.insert(errors, entry)
    end
  end
  table.sort(languages)
  return { index = merged_index, files = files, languages = languages, roots = roots, errors = errors }
end

---@return boolean
local function cache_files_changed(cache)
  if not cache or not cache.files then
    return true
  end
  for path, mtime in pairs(cache.files) do
    local now = util.file_mtime(path)
    if now ~= mtime then
      return true
    end
  end
  return false
end

---Check if cache is still valid (both structure and file content)
---@param cache table
---@param roots table
---@return boolean
local function cache_still_valid(cache, roots)
  if not cache or not cache.files then
    return false
  end

  -- First check: structural changes (new/deleted files)
  -- This is cheap and catches most changes
  local current_signature = compute_structural_signature(roots)
  if cache.structural_signature ~= current_signature then
    return false
  end

  -- Second check: file content changes (mtime)
  -- Only needed if structure hasn't changed
  if cache_files_changed(cache) then
    return false
  end

  return true
end

---@param start_dir string
---@return table
function M.ensure_index(start_dir)
  local roots = resolve_roots(start_dir)
  local key = compute_cache_key(roots, start_dir)
  local cache = M.caches[key]
  if cache and not cache.dirty then
    M.last_cache_key = key
    local watching = is_watching(key)
    if watching then
      -- When watching: throttle validation
      local now = uv.now()
      if (now - (cache.checked_at or 0)) < CACHE_VALIDATE_INTERVAL_MS then
        return cache
      end
      cache.checked_at = now
      if cache_valid_structural(roots, key) then
        return cache
      end
    else
      -- When NOT watching: validate both structure and content
      if cache_still_valid(cache, roots) then
        return cache
      end
    end
  end
  local built = M.build_index(roots)
  built.key = key
  built.namespaces = collect_namespaces(built.index)
  built.checked_at = uv.now()
  built.dirty = false
  built.structural_signature = compute_structural_signature(roots)
  M.caches[key] = built
  M.last_cache_key = key
  return built
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
    cache.namespaces = collect_namespaces(cache.index)
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
  if not path or path == "" then
    return nil
  end
  local roots = M.roots(start_dir)
  local norm_path = normalize_path(path)
  for _, root in ipairs(roots) do
    local root_path = normalize_path(root.path)
    if root_path and path_under(norm_path, root_path) then
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
        elseif #parts == 2 then
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

local function stop_single_watch(watch)
  if not watch then
    return
  end
  safe_close_handle(watch.timer)
  watch.timer = nil
  for _, handle in ipairs(watch.handles or {}) do
    safe_close_handle(handle)
  end
  watch.handles = {}
  watch.signature = nil
  watch.start_dir = nil
  watch.needs_rescan = false
end

local function inc_refcount(key, opts)
  if opts and opts._skip_refcount then
    return
  end
  M.watcher_refcounts[key] = (M.watcher_refcounts[key] or 0) + 1
end

local function stop_watch_internal(key, opts)
  local keep_refcount = opts and opts._keep_refcount
  if key then
    local watch = M.watchers[key]
    if watch then
      stop_single_watch(watch)
      M.watchers[key] = nil
    end
    if not keep_refcount then
      M.watcher_refcounts[key] = nil
    end
    return
  end
  for k, watch in pairs(M.watchers) do
    stop_single_watch(watch)
    M.watchers[k] = nil
    if not keep_refcount then
      M.watcher_refcounts[k] = nil
    end
  end
  if not keep_refcount then
    M.watcher_refcounts = {}
  end
end

local function restart_watch(watch)
  if not watch or not watch.start_dir or not watch.on_change then
    return
  end
  M.start_watch(watch.start_dir, watch.on_change, {
    debounce_ms = watch.debounce_ms,
    _skip_refcount = true,
  })
end

---@param start_dir string
---@param on_change fun()
---@param opts table|nil
---@return string|nil key watcher key for reference counting
function M.start_watch(start_dir, on_change, opts)
  if not start_dir or start_dir == "" then
    return
  end
  local roots = resolve_roots(start_dir)
  local key = compute_cache_key(roots, start_dir)
  if #roots == 0 then
    M.stop_watch(key)
    return
  end

  -- Increment reference count for this watcher key
  inc_refcount(key, opts)

  local paths = watch_paths(roots)
  if #paths == 0 then
    return key
  end
  local signature = table.concat(paths, "|")
  local debounce = (opts and opts.debounce_ms) or 200

  if M.watchers[key] and M.watchers[key].signature == signature then
    local existing = M.watchers[key]
    existing.on_change = on_change
    existing.debounce_ms = debounce
    return key
  end

  stop_watch_internal(key, { _keep_refcount = true })

  local rescan_paths = {}
  for _, root in ipairs(roots) do
    rescan_paths[root.path] = true
  end

  local watch = {
    key = key,
    start_dir = start_dir,
    signature = signature,
    handles = {},
    timer = nil,
    on_change = on_change,
    debounce_ms = debounce,
    needs_rescan = false,
    rescan_paths = rescan_paths,
  }
  M.watchers[key] = watch

  local function schedule_change(rescan)
    if rescan then
      watch.needs_rescan = true
    end
    safe_close_handle(watch.timer)
    watch.timer = uv.new_timer()
    watch.timer:start(
      watch.debounce_ms,
      0,
      vim.schedule_wrap(function()
        watch.timer = nil
        mark_cache_dirty(key)
        local cb = watch.on_change
        if cb then
          cb()
        end
        if watch.needs_rescan and watch.start_dir and watch.on_change then
          watch.needs_rescan = false
          restart_watch(watch)
        end
      end)
    )
  end

  for _, path in ipairs(paths) do
    if util.file_exists(path) then
      local handle = uv.new_fs_event()
      if handle then
        local start_ok, start_err = pcall(function()
          handle:start(path, {}, function(err, _filename, _events)
            if err then
              log_watcher_error(path, err)
              -- Schedule recovery: stop current watcher and restart after delay
              vim.defer_fn(function()
                if watch and watch.start_dir and watch.on_change then
                  restart_watch(watch)
                end
              end, 5000)
              return
            end
            schedule_change(rescan_paths[path] == true)
          end)
        end)

        if not start_ok then
          log_watcher_error(path, start_err or "unknown error starting watcher")
        else
          table.insert(watch.handles, handle)
        end
      end
    end
  end

  return key
end

---@param key string|nil
function M.stop_watch(key)
  stop_watch_internal(key, nil)
end

---Stop watcher with reference counting for buffer cleanup
---@param key string|nil watcher key
---@return boolean stopped true if watcher was actually stopped
function M.stop_watch_for_buffer(key)
  if not key then
    return false
  end

  local refcount = M.watcher_refcounts[key] or 0
  if refcount <= 0 then
    return false
  end

  M.watcher_refcounts[key] = refcount - 1

  -- Stop watcher when reference count reaches 0
  if M.watcher_refcounts[key] == 0 then
    local watch = M.watchers[key]
    if watch then
      stop_single_watch(watch)
      M.watchers[key] = nil
    end
    M.watcher_refcounts[key] = nil
    return true
  end

  return false
end

---@param path string|nil
function M.mark_dirty(path)
  if not path or path == "" then
    mark_cache_dirty(nil)
    return
  end
  local matched = false
  for key, cache in pairs(M.caches) do
    if cache.roots then
      for _, root in ipairs(cache.roots) do
        if path:sub(1, #root.path) == root.path then
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
end

---Get watcher key from start_dir (for buffer-watcher association)
---@param start_dir string
---@return string|nil key watcher key, or nil if no valid roots
function M.get_watcher_key(start_dir)
  if not start_dir or start_dir == "" then
    return nil
  end
  local roots = resolve_roots(start_dir)
  if #roots == 0 then
    return nil
  end
  return compute_cache_key(roots, start_dir)
end

return M
