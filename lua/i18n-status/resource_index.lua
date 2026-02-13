---@class I18nStatusResourceIndex
local M = {}

local util = require("i18n-status.util")
local resource_io = require("i18n-status.resource_io")
local discovery = require("i18n-status.resource_discovery")

local uv = vim.uv

local BUILD_YIELD_EVERY = 50
local build_yield_counter = 0

local function reset_build_yield_counter()
  build_yield_counter = 0
end

local function maybe_yield_build()
  build_yield_counter = build_yield_counter + 1
  if build_yield_counter < BUILD_YIELD_EVERY then
    return
  end
  build_yield_counter = 0
  pcall(coroutine.yield)
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

---@param cache table
---@param lang string
---@param key string
---@param value any
---@param file string
---@param priority integer
local function set_entry_tracked(cache, lang, key, value, file, priority)
  cache.entries_by_key = cache.entries_by_key or {}
  cache.entries_by_key[lang] = cache.entries_by_key[lang] or {}
  cache.entries_by_key[lang][key] = cache.entries_by_key[lang][key] or {}

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

  cache.file_entries = cache.file_entries or {}
  cache.file_entries[file] = cache.file_entries[file] or {}
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

  cache.index = cache.index or {}
  cache.index[lang] = cache.index[lang] or {}
  local existing = cache.index[lang][key]
  local existing_priority = existing and existing.priority or math.huge
  if priority < existing_priority then
    cache.index[lang][key] = { value = value, file = file, priority = priority }
  end
end

---@param cache table
---@param lang string
---@param key string
local function reselect_best_entry(cache, lang, key)
  if not cache.entries_by_key or not cache.entries_by_key[lang] then
    return
  end

  local entries = cache.entries_by_key[lang][key]
  if not entries or #entries == 0 then
    if cache.index and cache.index[lang] then
      cache.index[lang][key] = nil
    end
    cache.entries_by_key[lang][key] = nil
    return
  end

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

---@param path string
---@param roots table
---@return { entries: table, meta: table, mtime: integer }|nil
---@return string|nil
local function parse_file(path, roots)
  if not path or path == "" then
    return nil, "path is empty"
  end
  if not util.file_exists(path) then
    return nil, "file not found"
  end

  local norm_path = discovery.normalize_path(path)
  if not norm_path then
    return nil, "failed to normalize path"
  end

  local file_meta = discovery.resource_info_from_roots(roots, norm_path)
  if not file_meta then
    return nil, "file is not within any known root"
  end

  local data, err = resource_io.read_json(norm_path)
  if not data then
    return nil, err or "json error"
  end

  local mtime = util.file_mtime(norm_path)
  local entries = {}

  if file_meta.kind == "i18next" then
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

---@param cache table
---@param path string
local function remove_old_entries(cache, path)
  local file_entries = cache.file_entries and cache.file_entries[path]
  if not file_entries then
    return
  end

  local to_reselect = {}
  for _, entry in ipairs(file_entries) do
    local lang, key = entry.lang, entry.key
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

  for lang, keys in pairs(to_reselect) do
    for key, _ in pairs(keys) do
      reselect_best_entry(cache, lang, key)
    end
  end

  cache.file_entries[path] = nil
end

---@param cache table
---@param path string
---@return boolean
---@return string|nil
local function apply_file_change(cache, path)
  local norm_path = discovery.normalize_path(path)
  if not norm_path then
    return false, "failed to normalize path"
  end

  if util.file_exists(norm_path) then
    local result, err = parse_file(norm_path, cache.roots)
    if result then
      remove_old_entries(cache, norm_path)

      for _, entry in ipairs(result.entries) do
        set_entry_tracked(cache, entry.lang, entry.key, entry.value, norm_path, entry.priority)
      end

      cache.files[norm_path] = result.mtime
      cache.file_meta = cache.file_meta or {}
      cache.file_meta[norm_path] = result.meta

      if cache.file_errors and cache.file_errors[norm_path] then
        cache.file_errors[norm_path] = nil
        if cache.errors then
          for i = #cache.errors, 1, -1 do
            if cache.errors[i].file == norm_path then
              table.remove(cache.errors, i)
            end
          end
        end
      end

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
    end

    cache.file_errors = cache.file_errors or {}
    cache.file_errors[norm_path] = { error = err, mtime = util.file_mtime(norm_path) }

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

  remove_old_entries(cache, norm_path)

  local deleted_lang = nil
  if cache.file_meta and cache.file_meta[norm_path] then
    deleted_lang = cache.file_meta[norm_path].lang
  end

  if cache.files then
    cache.files[norm_path] = nil
  end
  if cache.file_meta then
    cache.file_meta[norm_path] = nil
  end
  if cache.file_errors then
    cache.file_errors[norm_path] = nil
  end
  if cache.errors then
    for i = #cache.errors, 1, -1 do
      if cache.errors[i].file == norm_path then
        table.remove(cache.errors, i)
      end
    end
  end

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

      if cache.entries_by_key[deleted_lang] then
        local empty_entries = true
        for _, _ in pairs(cache.entries_by_key[deleted_lang]) do
          empty_entries = false
          break
        end
        if empty_entries then
          cache.entries_by_key[deleted_lang] = nil
        end
      end

      if cache.index and cache.index[deleted_lang] then
        local empty_index = true
        for _, _ in pairs(cache.index[deleted_lang]) do
          empty_index = false
          break
        end
        if empty_index then
          cache.index[deleted_lang] = nil
        end
      end
    end
  end

  return true, nil
end

---@param lang string
---@param namespace string
---@param data table
---@param cache table
---@param file string
---@param priority integer
local function merge_namespace(lang, namespace, data, cache, file, priority)
  local flat = util.flatten_table(data)
  for key, value in pairs(flat) do
    local canonical = namespace .. ":" .. key
    set_entry_tracked(cache, lang, canonical, value, file, priority)
  end
end

---@param root string
---@param root_path string
---@return table, table, table, I18nStatusResourceError[], table, table, table
local function load_i18next(root, root_path)
  local tracked = {
    index = {},
    entries_by_key = {},
    file_entries = {},
  }
  local files = {}
  local languages = {}
  local errors = {}
  local file_meta = {}

  for _, lang in ipairs(discovery.list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, raw_path in ipairs(discovery.list_json_files(lang_root)) do
      maybe_yield_build()
      local path = discovery.normalize_path(raw_path) or raw_path
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = resource_io.read_json(path)
      files[path] = util.file_mtime(path)

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
          set_entry_tracked(tracked, lang, canonical, value, path, 30)
        end
      else
        local message = err or "json error"
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end
  end

  return tracked.index, files, languages, errors, tracked.entries_by_key, tracked.file_entries, file_meta
end

---@param root string
---@param root_path string
---@return table, table, table, I18nStatusResourceError[], table, table, table
local function load_next_intl(root, root_path)
  local tracked = {
    index = {},
    entries_by_key = {},
    file_entries = {},
  }
  local files = {}
  local languages = {}
  local errors = {}
  local file_meta = {}

  for _, lang in ipairs(discovery.list_dirs(root)) do
    table.insert(languages, lang)
    local lang_root = util.path_join(root, lang)
    for _, raw_path in ipairs(discovery.list_json_files(lang_root)) do
      maybe_yield_build()
      local path = discovery.normalize_path(raw_path) or raw_path
      local namespace = vim.fn.fnamemodify(path, ":t:r")
      local data, err = resource_io.read_json(path)
      files[path] = util.file_mtime(path)

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
          set_entry_tracked(tracked, lang, canonical, value, path, 50)
        end
      else
        local message = err or "json error"
        table.insert(errors, { lang = lang, file = path, error = message })
      end
    end

    local raw_root_file = util.path_join(root, lang .. ".json")
    if util.file_exists(raw_root_file) then
      maybe_yield_build()
      local root_file = discovery.normalize_path(raw_root_file) or raw_root_file
      local data, err = resource_io.read_json(root_file)
      files[root_file] = util.file_mtime(root_file)

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
            merge_namespace(lang, ns, ns_data, tracked, root_file, 40)
          end
        end
      else
        local message = err or "json error"
        table.insert(errors, { lang = lang, file = root_file, error = message })
      end
    end
  end

  return tracked.index, files, languages, errors, tracked.entries_by_key, tracked.file_entries, file_meta
end

---@param index table
---@return string[]
function M.collect_namespaces(index)
  local set = {}
  for _, items in pairs(index or {}) do
    for key, _ in pairs(items) do
      local ns = key:match("^(.-):")
      if ns then
        set[ns] = true
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
    local norm_root_path = discovery.normalize_path(root.path)

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

    for lang, keys in pairs(entries_by_key) do
      merged_entries_by_key[lang] = merged_entries_by_key[lang] or {}
      for key, entries in pairs(keys) do
        merged_entries_by_key[lang][key] = merged_entries_by_key[lang][key] or {}
        for _, entry in ipairs(entries) do
          table.insert(merged_entries_by_key[lang][key], entry)
        end
      end
    end

    for path, entries in pairs(file_entries) do
      merged_file_entries[path] = merged_file_entries[path] or {}
      for _, entry in ipairs(entries) do
        table.insert(merged_file_entries[path], entry)
      end
    end

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

---@param cache table
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

---@param cache table
---@param roots table
---@return boolean
function M.cache_still_valid(cache, roots)
  if not cache or not cache.files then
    return false
  end

  local current_signature = discovery.compute_structural_signature(roots, { force = true })
  if cache.structural_signature ~= current_signature then
    return false
  end

  if cache_files_changed(cache) then
    return false
  end

  return true
end

---@class I18nStatusResourceApplyOpts
---@field allow_rebuild boolean|nil
---@field cache_key string|nil
---@field set_signature fun(key: string, sig: string)|nil

---@param cache table
---@param paths string[]
---@param opts I18nStatusResourceApplyOpts|nil
---@return boolean
---@return boolean|nil
function M.apply_changes(cache, paths, opts)
  opts = opts or {}
  local needs_rebuild = false

  for _, path in ipairs(paths or {}) do
    local norm_path = discovery.normalize_path(path)
    if not norm_path then
      needs_rebuild = true
    else
      local stat = uv.fs_stat(norm_path)
      if stat and stat.type == "directory" then
        needs_rebuild = true
      else
        local within_root = false
        for _, root in ipairs(cache.roots or {}) do
          local root_path = discovery.normalize_path(root.path)
          if root_path and discovery.path_under(norm_path, root_path) then
            within_root = true
            break
          end
        end

        if not within_root then
          needs_rebuild = true
        else
          if norm_path:sub(-5) ~= ".json" then
            needs_rebuild = true
          else
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
    cache.dirty = true
    return false, true
  end

  if not needs_rebuild then
    local signature = discovery.compute_structural_signature(cache.roots, { force = true })
    cache.structural_signature = signature
    cache.namespaces = M.collect_namespaces(cache.index)

    if opts.set_signature and opts.cache_key and signature then
      opts.set_signature(opts.cache_key, signature)
    end
  end

  return true, needs_rebuild
end

return M
