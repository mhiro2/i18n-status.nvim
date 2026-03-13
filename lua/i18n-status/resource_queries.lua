---@class I18nStatusResourceQueries
local M = {}

local fs = require("i18n-status.fs")

---@param resources I18nStatusResources
---@param roots I18nStatusResourceRoots
---@return I18nStatusResourceQueries
function M.new(resources, roots)
  local service = {}

  ---@return I18nStatusCache|nil
  local function current_cache()
    local key = resources.last_cache_key
    if key then
      return resources.caches[key]
    end
    return nil
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

  ---@param start_dir string
  ---@param lang string
  ---@param namespace string
  ---@return string|nil
  function service.namespace_path(start_dir, lang, namespace)
    local root_list = resources.roots(start_dir)
    for _, root in ipairs(root_list) do
      if root.kind == "i18next" then
        return fs.path_join(root.path, lang, namespace .. ".json")
      end
      if roots.is_next_intl_kind(root.kind) then
        local root_file = fs.path_join(root.path, lang .. ".json")
        if fs.file_exists(root_file) then
          return root_file
        end
        return fs.path_join(root.path, lang, namespace .. ".json")
      end
    end
    return nil
  end

  ---@param lang string
  ---@param key string
  ---@return I18nStatusResourceItem|nil
  function service.get(lang, key)
    local cache = current_cache()
    if not cache or not cache.index or not cache.index[lang] then
      return nil
    end
    return cache.index[lang][key]
  end

  ---@return string[]
  function service.languages()
    local cache = current_cache()
    return (cache and cache.languages) or {}
  end

  ---@param start_dir string
  ---@return string[]
  function service.namespaces(start_dir)
    local cache = resources.ensure_index(start_dir)
    return cache.namespaces or {}
  end

  ---@param start_dir string
  ---@return string|nil, string, string[]
  function service.namespace_hint(start_dir)
    local namespaces = service.namespaces(start_dir)
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
  function service.fallback_namespace(start_dir)
    local hint, reason, namespaces = service.namespace_hint(start_dir)
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
  function service.fallback_namespace_for_buf(bufnr)
    return service.fallback_namespace(resources.start_dir(bufnr))
  end

  ---@param start_dir string
  ---@param path string
  ---@return I18nStatusResourceInfo|nil
  function service.resource_info(start_dir, path)
    return roots.resource_info_from_roots(resources.roots(start_dir), path)
  end

  ---@param bufnr integer
  ---@return I18nStatusResourceInfo|nil
  function service.resource_info_for_buf(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not path or path == "" then
      return nil
    end
    return service.resource_info(resources.start_dir(bufnr), path)
  end

  ---@param start_dir string
  ---@param lang string
  ---@param path string
  ---@return boolean
  function service.is_next_intl_root_file(start_dir, lang, path)
    for _, root in ipairs(resources.roots(start_dir)) do
      if roots.is_next_intl_kind(root.kind) then
        local candidate = fs.path_join(root.path, lang .. ".json")
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
  function service.key_path_for_file(namespace, key_path, start_dir, lang, path)
    if service.is_next_intl_root_file(start_dir, lang, path) then
      if key_path == "" then
        return namespace
      end
      return namespace .. "." .. key_path
    end
    return key_path
  end

  return service
end

return M
