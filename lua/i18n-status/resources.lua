---@class I18nStatusResources
local M = {
  reader = nil,
  caches = {},
  last_cache_key = nil,
}

local util = require("i18n-status.util")
local watcher = require("i18n-status.watcher")

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
---@field index table<string, table<string, I18nStatusResourceItem>> Map of lang -> key -> resource item
---@field files table<string, integer> Map of file path -> mtime
---@field languages string[] List of detected languages
---@field roots I18nStatusRootInfo[] List of resource root directories
---@field errors I18nStatusResourceError[] List of parsing errors
---@field namespaces string[] List of detected namespaces
---@field dirty boolean Whether cache needs rebuild
---@field checked_at integer Timestamp of last validation check
---@field structural_signature string|nil Hash of directory structure
---@field entries_by_key table<string, table<string, table>> Map of lang -> key -> entries with file/priority
---@field file_entries table<string, I18nStatusFileEntry[]> Map of file -> list of entries
---@field file_meta table<string, I18nStatusFileMeta> Map of file -> metadata
---@field file_errors table<string, {error: string, mtime: integer}> Map of file -> parse error info
local uv = vim.uv

local CACHE_VALIDATE_INTERVAL_MS = 1000
local WATCH_MAX_FILES = 200
local WATCH_PATHS_CACHE_TTL_MS = 1000
local BUILD_YIELD_EVERY = 50
local FILE_PERMISSION_RW = 420 -- 0644 (rw-r--r--)
local build_yield_counter = 0
---@type table<string, { paths: string[], signature: string, updated_at: integer }>
local watch_paths_cache = {}

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

local function contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function reset_build_yield_counter()
  build_yield_counter = 0
end

local function maybe_yield_build()
  build_yield_counter = build_yield_counter + 1
  if build_yield_counter < BUILD_YIELD_EVERY then
    return
  end
  build_yield_counter = 0
  -- Cooperative yield for chunked rebuilds when running inside a coroutine.
  pcall(coroutine.yield)
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
  local root_list = roots or M.roots(start_dir)
  for _, root in ipairs(root_list or {}) do
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
---@param path string
---@param stage string
---@param err string|nil
local function notify_write_failure(path, stage, err)
  vim.schedule(function()
    vim.notify(
      string.format("i18n-status: failed to write json file (%s, %s): %s", path, stage, err or "unknown"),
      vim.log.levels.WARN
    )
  end)
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
  local fd, open_err = uv.fs_open(tmp_path, "w", FILE_PERMISSION_RW)
  if not fd then
    notify_write_failure(path, "fs_open", open_err)
    return
  end

  local function cleanup_tmp()
    pcall(uv.fs_unlink, tmp_path)
  end

  local function close_fd()
    return uv.fs_close(fd)
  end

  local written, write_err = uv.fs_write(fd, encoded, 0)
  if type(written) ~= "number" or written ~= #encoded then
    local _, close_err = close_fd()
    cleanup_tmp()
    notify_write_failure(path, "fs_write", write_err or close_err or "short write")
    return
  end

  local fsync_ok, fsync_err = uv.fs_fsync(fd)
  if not fsync_ok then
    local _, close_err = close_fd()
    cleanup_tmp()
    notify_write_failure(path, "fs_fsync", fsync_err or close_err)
    return
  end

  local close_ok, close_err = close_fd()
  if not close_ok then
    cleanup_tmp()
    notify_write_failure(path, "fs_close", close_err)
    return
  end

  local ok, err = uv.fs_rename(tmp_path, path)
  if ok then
    M.mark_dirty(path)
    return
  end

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
  cleanup_tmp()
  notify_write_failure(path, "fs_rename", err)
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

---Add entry with tracking in entries_by_key and file_entries
---@param cache table
---@param lang string
---@param key string
---@param value any
---@param file string
---@param priority integer
local function set_entry_tracked(cache, lang, key, value, file, priority)
  -- Update entries_by_key
  cache.entries_by_key = cache.entries_by_key or {}
  cache.entries_by_key[lang] = cache.entries_by_key[lang] or {}
  cache.entries_by_key[lang][key] = cache.entries_by_key[lang][key] or {}
  -- Check if this file already has an entry for this key
  local found = false
  for i, entry in ipairs(cache.entries_by_key[lang][key]) do
    if entry.file == file then
      cache.entries_by_key[lang][key][i] = { value = value, file = file, priority = priority }
      found = true
      break
    end
  end
  if not found then
    table.insert(cache.entries_by_key[lang][key], { value = value, file = file, priority = priority })
  end

  -- Update file_entries (reverse index)
  cache.file_entries = cache.file_entries or {}
  cache.file_entries[file] = cache.file_entries[file] or {}
  -- Check if entry already exists
  local entry_found = false
  for _, entry in ipairs(cache.file_entries[file]) do
    if entry.lang == lang and entry.key == key then
      entry_found = true
      break
    end
  end
  if not entry_found then
    table.insert(cache.file_entries[file], { lang = lang, key = key, priority = priority })
  end

  -- Update main index with best entry
  cache.index = cache.index or {}
  cache.index[lang] = cache.index[lang] or {}
  local existing = cache.index[lang][key]
  local existing_priority = existing and existing.priority or math.huge
  if priority < existing_priority then
    cache.index[lang][key] = { value = value, file = file, priority = priority }
  end
end

---Reselect best entry for a key from entries_by_key
---@param cache table
---@param lang string
---@param key string
local function reselect_best_entry(cache, lang, key)
  if not cache.entries_by_key or not cache.entries_by_key[lang] then
    return
  end
  local entries = cache.entries_by_key[lang][key]
  if not entries or #entries == 0 then
    -- No entries left, remove from index
    if cache.index and cache.index[lang] then
      cache.index[lang][key] = nil
    end
    -- Cleanup empty table
    cache.entries_by_key[lang][key] = nil
    return
  end
  -- Find best priority entry
  local best = nil
  for _, entry in ipairs(entries) do
    if not best or entry.priority < best.priority then
      best = entry
    end
  end
  if best then
    cache.index[lang] = cache.index[lang] or {}
    cache.index[lang][key] = { value = best.value, file = best.file, priority = best.priority }
  end
end

---Parse a single resource file and return entries with metadata
---@param path string
---@param roots table
---@return { entries: table, meta: table, mtime: integer }|nil, string|nil
local function parse_file(path, roots)
  if not path or path == "" then
    return nil, "path is empty"
  end
  if not util.file_exists(path) then
    return nil, "file not found"
  end

  local norm_path = normalize_path(path)
  if not norm_path then
    return nil, "failed to normalize path"
  end

  -- Determine root/kind/lang/namespace/is_root from path
  local file_meta = nil
  for _, root in ipairs(roots or {}) do
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
          file_meta = {
            kind = root.kind,
            root = root_path,
            lang = parts[1],
            namespace = parts[2]:sub(1, -6),
            is_root = false,
          }
          break
        end
      elseif root.kind == "next-intl" then
        if #parts == 1 then
          file_meta = {
            kind = root.kind,
            root = root_path,
            lang = parts[1]:sub(1, -6),
            namespace = nil,
            is_root = true,
          }
          break
        elseif #parts == 2 then
          file_meta = {
            kind = root.kind,
            root = root_path,
            lang = parts[1],
            namespace = parts[2]:sub(1, -6),
            is_root = false,
          }
          break
        end
      end
      break
    end
  end

  if not file_meta then
    return nil, "file is not within any known root"
  end

  -- Read and parse JSON
  local data, err = read_json(path)
  if not data then
    return nil, err or "json error"
  end

  local mtime = util.file_mtime(path)
  local entries = {}

  if file_meta.kind == "i18next" then
    -- i18next: key = namespace:path, priority = 30
    local flat = util.flatten_table(data)
    for key, value in pairs(flat) do
      local canonical = file_meta.namespace .. ":" .. key
      table.insert(entries, {
        lang = file_meta.lang,
        key = canonical,
        value = value,
        priority = 30,
      })
    end
  elseif file_meta.kind == "next-intl" then
    if file_meta.is_root then
      -- next-intl root file: contains multiple namespaces, priority = 40
      for ns, ns_data in pairs(data) do
        if type(ns_data) == "table" then
          local flat = util.flatten_table(ns_data)
          for key, value in pairs(flat) do
            local canonical = ns .. ":" .. key
            table.insert(entries, {
              lang = file_meta.lang,
              key = canonical,
              value = value,
              priority = 40,
            })
          end
        end
      end
    else
      -- next-intl namespace file: priority = 50
      local flat = util.flatten_table(data)
      for key, value in pairs(flat) do
        local canonical = file_meta.namespace .. ":" .. key
        table.insert(entries, {
          lang = file_meta.lang,
          key = canonical,
          value = value,
          priority = 50,
        })
      end
    end
  end

  return { entries = entries, meta = file_meta, mtime = mtime }, nil
end

---Remove old entries for a file from the cache
---@param cache table
---@param path string
local function remove_old_entries(cache, path)
  local file_entries = cache.file_entries and cache.file_entries[path]
  if not file_entries then
    return
  end

  -- Track which (lang, key) pairs need reselection
  local to_reselect = {}
  for _, entry in ipairs(file_entries) do
    local lang, key = entry.lang, entry.key
    -- Remove this file's entry from entries_by_key
    if cache.entries_by_key and cache.entries_by_key[lang] and cache.entries_by_key[lang][key] then
      local entries = cache.entries_by_key[lang][key]
      for i = #entries, 1, -1 do
        if entries[i].file == path then
          table.remove(entries, i)
        end
      end
      to_reselect[lang] = to_reselect[lang] or {}
      to_reselect[lang][key] = true
    end
  end

  -- Reselect best entry for affected keys
  for lang, keys in pairs(to_reselect) do
    for key, _ in pairs(keys) do
      reselect_best_entry(cache, lang, key)
    end
  end

  -- Clear file_entries for this path
  cache.file_entries[path] = nil
end

---Apply a single file change to the cache
---@param cache table
---@param path string
---@return boolean success
---@return string|nil error
local function apply_file_change(cache, path)
  local norm_path = normalize_path(path)
  if not norm_path then
    return false, "failed to normalize path"
  end

  if util.file_exists(norm_path) then
    -- File exists: parse and update
    local result, err = parse_file(norm_path, cache.roots)
    if result then
      -- Remove old entries first
      remove_old_entries(cache, norm_path)

      -- Insert new entries
      for _, entry in ipairs(result.entries) do
        set_entry_tracked(cache, entry.lang, entry.key, entry.value, norm_path, entry.priority)
      end

      -- Update file metadata
      cache.files[norm_path] = result.mtime
      cache.file_meta = cache.file_meta or {}
      cache.file_meta[norm_path] = result.meta

      -- Clear any previous error for this file
      if cache.file_errors and cache.file_errors[norm_path] then
        cache.file_errors[norm_path] = nil
        -- Remove from cache.errors list
        if cache.errors then
          for i = #cache.errors, 1, -1 do
            if cache.errors[i].file == norm_path then
              table.remove(cache.errors, i)
            end
          end
        end
      end

      -- Update languages if new lang discovered
      local meta = result.meta
      if meta and meta.lang then
        local found = false
        for _, lang in ipairs(cache.languages or {}) do
          if lang == meta.lang then
            found = true
            break
          end
        end
        if not found then
          cache.languages = cache.languages or {}
          table.insert(cache.languages, meta.lang)
          table.sort(cache.languages)
        end
      end

      return true, nil
    else
      -- Parse error: keep old entries, record error
      cache.file_errors = cache.file_errors or {}
      cache.file_errors[norm_path] = { error = err, mtime = util.file_mtime(norm_path) }

      -- Add to cache.errors for doctor display
      cache.errors = cache.errors or {}
      local existing_error = false
      for _, e in ipairs(cache.errors) do
        if e.file == norm_path then
          e.error = err
          existing_error = true
          break
        end
      end
      if not existing_error then
        local meta = cache.file_meta and cache.file_meta[norm_path]
        local lang = meta and meta.lang or "unknown"
        table.insert(cache.errors, { lang = lang, file = norm_path, error = err })
      end

      return false, err
    end
  else
    -- File deleted: remove entries and metadata
    remove_old_entries(cache, norm_path)

    -- Save lang info before clearing file_meta (needed for language cleanup)
    local deleted_lang = nil
    if cache.file_meta and cache.file_meta[norm_path] then
      deleted_lang = cache.file_meta[norm_path].lang
    end

    -- Clear file metadata
    if cache.files then
      cache.files[norm_path] = nil
    end
    if cache.file_meta then
      cache.file_meta[norm_path] = nil
    end
    if cache.file_errors then
      cache.file_errors[norm_path] = nil
    end
    -- Remove from cache.errors
    if cache.errors then
      for i = #cache.errors, 1, -1 do
        if cache.errors[i].file == norm_path then
          table.remove(cache.errors, i)
        end
      end
    end

    -- Check if language has no remaining entries and remove from languages list
    if deleted_lang and cache.entries_by_key then
      local lang_has_entries = false
      if cache.entries_by_key[deleted_lang] then
        for _, entries in pairs(cache.entries_by_key[deleted_lang]) do
          if entries and #entries > 0 then
            lang_has_entries = true
            break
          end
        end
      end
      if not lang_has_entries and cache.languages then
        for i = #cache.languages, 1, -1 do
          if cache.languages[i] == deleted_lang then
            table.remove(cache.languages, i)
            break
          end
        end
        -- Also cleanup empty entries_by_key table
        if cache.entries_by_key[deleted_lang] then
          local empty = true
          for _, _ in pairs(cache.entries_by_key[deleted_lang]) do
            empty = false
            break
          end
          if empty then
            cache.entries_by_key[deleted_lang] = nil
          end
        end
        -- Cleanup empty index
        if cache.index and cache.index[deleted_lang] then
          local empty = true
          for _, _ in pairs(cache.index[deleted_lang]) do
            empty = false
            break
          end
          if empty then
            cache.index[deleted_lang] = nil
          end
        end
      end
    end

    return true, nil
  end
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
---@param root_path string normalized root path for meta
---@return table, table, table, I18nStatusResourceError[], table, table, table
local function load_i18next(root, root_path)
  local index = {}
  local files = {}
  local languages = {}
  local errors = {}
  local entries_by_key = {}
  local file_entries = {}
  local file_meta = {}
  for _, lang in ipairs(list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, raw_path in ipairs(list_json_files(lang_root)) do
      maybe_yield_build()
      -- Normalize path for consistent lookups
      local path = normalize_path(raw_path) or raw_path
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = read_json(path)
      files[path] = util.file_mtime(path)

      -- Store file meta
      file_meta[path] = {
        kind = "i18next",
        root = root_path or root,
        lang = lang,
        namespace = namespace,
        is_root = false,
      }

      if data then
        local flat = util.flatten_table(data)
        for key, value in pairs(flat) do
          local canonical = namespace .. ":" .. key
          set_entry(index, lang, canonical, value, path, 30)

          -- Track in entries_by_key
          entries_by_key[lang] = entries_by_key[lang] or {}
          entries_by_key[lang][canonical] = entries_by_key[lang][canonical] or {}
          table.insert(entries_by_key[lang][canonical], { value = value, file = path, priority = 30 })

          -- Track in file_entries
          file_entries[path] = file_entries[path] or {}
          table.insert(file_entries[path], { lang = lang, key = canonical, priority = 30 })
        end
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, path, 1)
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end
  end
  return index, files, languages, errors, entries_by_key, file_entries, file_meta
end

---@param root string
---@param root_path string normalized root path for meta
---@return table, table, table, I18nStatusResourceError[], table, table, table
local function load_next_intl(root, root_path)
  local index = {}
  local files = {}
  local languages = {}
  local errors = {}
  local entries_by_key = {}
  local file_entries = {}
  local file_meta = {}
  for _, lang in ipairs(list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, raw_path in ipairs(list_json_files(lang_root)) do
      maybe_yield_build()
      -- Normalize path for consistent lookups
      local path = normalize_path(raw_path) or raw_path
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = read_json(path)
      files[path] = util.file_mtime(path)

      -- Store file meta
      file_meta[path] = {
        kind = "next-intl",
        root = root_path or root,
        lang = lang,
        namespace = namespace,
        is_root = false,
      }

      if data then
        local flat = util.flatten_table(data)
        for key, value in pairs(flat) do
          local canonical = namespace .. ":" .. key
          set_entry(index, lang, canonical, value, path, 50)

          -- Track in entries_by_key
          entries_by_key[lang] = entries_by_key[lang] or {}
          entries_by_key[lang][canonical] = entries_by_key[lang][canonical] or {}
          table.insert(entries_by_key[lang][canonical], { value = value, file = path, priority = 50 })

          -- Track in file_entries
          file_entries[path] = file_entries[path] or {}
          table.insert(file_entries[path], { lang = lang, key = canonical, priority = 50 })
        end
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, path, 1)
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end
    local raw_root_file = util.path_join(root, lang .. ".json")
    if util.file_exists(raw_root_file) then
      maybe_yield_build()
      -- Normalize path for consistent lookups
      local root_file = normalize_path(raw_root_file) or raw_root_file
      local data, err = read_json(root_file)
      files[root_file] = util.file_mtime(root_file)

      -- Store file meta for root file
      file_meta[root_file] = {
        kind = "next-intl",
        root = root_path or root,
        lang = lang,
        namespace = nil,
        is_root = true,
      }

      if data then
        for ns, ns_data in pairs(data) do
          if type(ns_data) == "table" then
            merge_namespace(lang, ns, ns_data, index, root_file, 40)

            -- Track in entries_by_key and file_entries for root file
            local flat = util.flatten_table(ns_data)
            for key, value in pairs(flat) do
              local canonical = ns .. ":" .. key
              entries_by_key[lang] = entries_by_key[lang] or {}
              entries_by_key[lang][canonical] = entries_by_key[lang][canonical] or {}
              table.insert(entries_by_key[lang][canonical], { value = value, file = root_file, priority = 40 })

              file_entries[root_file] = file_entries[root_file] or {}
              table.insert(file_entries[root_file], { lang = lang, key = canonical, priority = 40 })
            end
          end
        end
      else
        local message = err or "json error"
        set_entry(index, lang, "__error__", message, root_file, 1)
        table.insert(errors, { lang = lang, file = root_file, error = message })
      end
    end
  end
  return index, files, languages, errors, entries_by_key, file_entries, file_meta
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
  watch_paths_cache[key] = {
    paths = paths,
    signature = table.concat(paths, "|"),
    updated_at = now,
  }
  return paths
end

---Compute structural signature for cache validation (detects new/deleted files)
---@param roots table
---@param opts? { force?: boolean }
---@return string|nil signature, or nil if no roots
local function compute_structural_signature(roots, opts)
  opts = opts or {}
  local force = opts.force == true
  if not roots or #roots == 0 then
    return nil
  end
  local key = roots_key(roots) or "__none__"
  local now = uv.now()
  local cached = watch_paths_cache[key]
  if not force and cached and (now - cached.updated_at) < WATCH_PATHS_CACHE_TTL_MS then
    return cached.signature
  end
  watch_paths(roots, { force = force })
  local refreshed = watch_paths_cache[key]
  return refreshed and refreshed.signature or nil
end

---@param roots table
---@param roots table
---@param key string
---@return boolean
local function cache_valid_structural(roots, key)
  local stored = watcher.signature(key)
  if not stored then
    return false
  end
  local current = compute_structural_signature(roots)
  return current == stored
end

---@param roots table
---@return table
function M.build_index(roots)
  roots = roots or {}
  reset_build_yield_counter()
  local merged_index = {}
  local files = {}
  local languages = {}
  local lang_seen = {}
  local errors = {}
  local merged_entries_by_key = {}
  local merged_file_entries = {}
  local merged_file_meta = {}
  for _, root in ipairs(roots) do
    local index, root_files, root_langs, root_errors, entries_by_key, file_entries, file_meta =
      {}, {}, {}, {}, {}, {}, {}
    local norm_root_path = normalize_path(root.path)
    if root.kind == "i18next" then
      index, root_files, root_langs, root_errors, entries_by_key, file_entries, file_meta =
        load_i18next(root.path, norm_root_path)
    else
      index, root_files, root_langs, root_errors, entries_by_key, file_entries, file_meta =
        load_next_intl(root.path, norm_root_path)
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
      for key, value in pairs(items) do
        set_entry(merged_index, lang, key, value.value, value.file, value.priority or math.huge)
      end
    end
    for _, entry in ipairs(root_errors) do
      table.insert(errors, entry)
    end
    -- Merge entries_by_key
    for lang, keys in pairs(entries_by_key) do
      merged_entries_by_key[lang] = merged_entries_by_key[lang] or {}
      for key, entries in pairs(keys) do
        merged_entries_by_key[lang][key] = merged_entries_by_key[lang][key] or {}
        for _, entry in ipairs(entries) do
          table.insert(merged_entries_by_key[lang][key], entry)
        end
      end
    end
    -- Merge file_entries
    for path, entries in pairs(file_entries) do
      merged_file_entries[path] = merged_file_entries[path] or {}
      for _, entry in ipairs(entries) do
        table.insert(merged_file_entries[path], entry)
      end
    end
    -- Merge file_meta
    for path, meta in pairs(file_meta) do
      merged_file_meta[path] = meta
    end
  end
  table.sort(languages)
  return {
    index = merged_index,
    files = files,
    languages = languages,
    roots = roots,
    errors = errors,
    entries_by_key = merged_entries_by_key,
    file_entries = merged_file_entries,
    file_meta = merged_file_meta,
  }
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
  local current_signature = compute_structural_signature(roots, { force = true })
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
    local watching = watcher.is_watching(key)
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

---Apply incremental changes to the cache
---@param cache_key string
---@param paths string[]
---@param opts table|nil
---@return boolean success
---@return boolean|nil needs_rebuild
function M.apply_changes(cache_key, paths, opts)
  opts = opts or {}
  local cache = M.caches[cache_key]
  if not cache then
    -- No cache, need full rebuild
    return false, true
  end

  local needs_rebuild = false

  for _, path in ipairs(paths or {}) do
    local norm_path = normalize_path(path)
    if not norm_path then
      needs_rebuild = true
    else
      -- Check if path is a directory
      local stat = uv.fs_stat(norm_path)
      if stat and stat.type == "directory" then
        needs_rebuild = true
      else
        -- Check if path is within any root
        local within_root = false
        for _, root in ipairs(cache.roots or {}) do
          local root_path = normalize_path(root.path)
          if root_path and path_under(norm_path, root_path) then
            within_root = true
            break
          end
        end

        if not within_root then
          -- Path outside roots, might be a new file structure
          needs_rebuild = true
        else
          -- Non-json files under root may change structure; rebuild is safer.
          if norm_path:sub(-5) ~= ".json" then
            needs_rebuild = true
          else
            -- Apply file change
            local ok, err = apply_file_change(cache, norm_path)
            if not ok and err == "file is not within any known root" then
              needs_rebuild = true
            end
          end
        end
      end
    end
  end

  if needs_rebuild and opts.allow_rebuild ~= false then
    -- Trigger full rebuild
    cache.dirty = true
    return false, true
  end

  if not needs_rebuild then
    -- Update structural signature and namespaces
    local signature = compute_structural_signature(cache.roots, { force = true })
    cache.structural_signature = signature
    cache.namespaces = collect_namespaces(cache.index)

    watcher.set_signature(cache_key, signature)
  end

  return true, needs_rebuild
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

---@param start_dir string
---@param on_change fun(event: table|nil)
---@param opts table|nil
---@return string|nil key watcher key for reference counting
function M.start_watch(start_dir, on_change, opts)
  if not start_dir or start_dir == "" then
    return
  end
  local roots = resolve_roots(start_dir)
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

---Stop watcher with reference counting for buffer cleanup
---@param key string|nil watcher key
---@return boolean stopped true if watcher was actually stopped
function M.stop_watch_for_buffer(key)
  return watcher.stop_for_buffer(key)
end

---@param path string|nil
function M.mark_dirty(path)
  if not path or path == "" then
    mark_cache_dirty(nil)
    return
  end
  local normalized_path = normalize_path(path)
  if not normalized_path then
    mark_cache_dirty(nil)
    return
  end
  local matched = false
  for key, cache in pairs(M.caches) do
    if cache.roots then
      for _, root in ipairs(cache.roots) do
        local root_path = normalize_path(root.path)
        if root_path and path_under(normalized_path, root_path) then
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
