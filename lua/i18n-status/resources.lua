---@class I18nStatusResources
---@field reader fun(path: string): string|nil
---@field caches table<string, I18nStatusCache>
---@field last_cache_key string|nil
local M = {
  reader = nil,
  caches = {},
  last_cache_key = nil,
}

local resource_io = require("i18n-status.resource_io")
local resource_roots = require("i18n-status.resource_roots")
local resource_cache = require("i18n-status.resource_cache").new(M, resource_roots)
local resource_queries = require("i18n-status.resource_queries").new(M, resource_roots)
local resource_watch_service = require("i18n-status.resource_watch_service").new(M, resource_roots)

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

---@class I18nStatusResourceInfo
---@field kind "i18next"|"next-intl"|"next_intl"
---@field root string
---@field lang string
---@field namespace string|nil
---@field is_root boolean

---@class I18nStatusJsonStyle
---@field indent string
---@field newline boolean
---@field error string|nil

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

M.start_dir = resource_roots.start_dir
M.project_root = resource_roots.project_root

---@param path string
---@return table|nil
---@return I18nStatusJsonStyle
function M.read_json_table(path)
  return resource_io.read_json_table(path)
end

---@param path string
---@param data table
---@param style I18nStatusJsonStyle|nil
---@param opts I18nStatusResourceWriteOpts|nil
---@return boolean ok
---@return string|nil err
function M.write_json_table(path, data, style, opts)
  local io_opts = vim.tbl_extend("force", opts or {}, { mark_dirty = M.mark_dirty })
  return resource_io.write_json_table(path, data, style, io_opts)
end

M.build_index = resource_cache.build_index
M.build_index_async = resource_cache.build_index_async
M.ensure_index = resource_cache.ensure_index
M.ensure_index_async = resource_cache.ensure_index_async
M.apply_changes = resource_cache.apply_changes

---@param start_dir string
---@return I18nStatusRootInfo[]
function M.roots(start_dir)
  local cache = M.ensure_index(start_dir)
  return cache.roots or {}
end

M.namespace_path = resource_queries.namespace_path
M.get = resource_queries.get
M.languages = resource_queries.languages
M.namespaces = resource_queries.namespaces
M.namespace_hint = resource_queries.namespace_hint
M.fallback_namespace = resource_queries.fallback_namespace
M.fallback_namespace_for_buf = resource_queries.fallback_namespace_for_buf
M.resource_info = resource_queries.resource_info
M.resource_info_for_buf = resource_queries.resource_info_for_buf
M.is_next_intl_root_file = resource_queries.is_next_intl_root_file
M.key_path_for_file = resource_queries.key_path_for_file

M.start_watch = resource_watch_service.start_watch
M.resolve_watch_target = resource_watch_service.resolve_watch_target
M.stop_watch = resource_watch_service.stop_watch
M.stop_watch_for_buffer = resource_watch_service.stop_watch_for_buffer
M.mark_dirty = resource_watch_service.mark_dirty
M.get_watcher_key = resource_watch_service.get_watcher_key

---@param reader fun(path: string): string|nil
function M.set_reader(reader)
  M.reader = reader
  resource_io.set_reader(reader)
end

return M
