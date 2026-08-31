---@class I18nStatusResourceCatalogService
local M = {}

local resource_roots = require("i18n-status.resource_roots")
local resources = require("i18n-status.resources")

---@class I18nStatusFrameworkCatalog
---@field errors I18nStatusResourceError[]
---@field existing_keys table<string, boolean>
---@field framework 'i18next'|'next_intl'
---@field index table<string, table<string, I18nStatusResourceItem>>
---@field languages string[]
---@field namespaces string[]
---@field root_kind 'i18next'|'next-intl'
---@field roots I18nStatusRootInfo[]

---@param framework string|nil
---@return 'i18next'|'next-intl'|nil
function M.root_kind(framework)
  if framework == "i18next" then
    return "i18next"
  end
  if resource_roots.is_next_intl_kind(framework) then
    return "next-intl"
  end
  return nil
end

---@param root I18nStatusRootInfo
---@param root_kind string
---@return boolean
local function root_matches(root, root_kind)
  if root_kind == "i18next" then
    return root.kind == "i18next"
  end
  return root_kind == "next-intl" and resource_roots.is_next_intl_kind(root.kind)
end

---@param index I18nStatusCache|nil
---@return table<string, boolean>
function M.collect_existing_keys(index)
  local keys = {}
  for _, entries in pairs((index and index.index) or {}) do
    for key, _ in pairs(entries or {}) do
      if key ~= "__error__" then
        keys[key] = true
      end
    end
  end
  return keys
end

---@param start_dir string
---@param framework 'i18next'|'next_intl'
---@param cache I18nStatusCache|nil
---@return I18nStatusFrameworkCatalog|nil
---@return string|nil
function M.build(start_dir, framework, cache)
  local root_kind = M.root_kind(framework)
  if not root_kind then
    return nil, "unsupported translation framework"
  end

  cache = cache or resources.ensure_index(start_dir, { exact = true })
  local roots = {}
  for _, root in ipairs((cache and cache.roots) or {}) do
    if root_matches(root, root_kind) then
      roots[#roots + 1] = { kind = root.kind, path = root.path }
    end
  end
  if #roots == 0 then
    return nil, "no " .. root_kind .. " resource root detected"
  end
  if #roots > 1 then
    return nil, "multiple " .. root_kind .. " resource roots are ambiguous"
  end

  local built = resources.build_index(roots)
  if type(built) ~= "table" then
    return nil, "failed to build framework resource catalog"
  end
  local languages = vim.deepcopy(built.languages or {})
  table.sort(languages)
  local catalog = {
    errors = vim.deepcopy(built.errors or {}),
    existing_keys = M.collect_existing_keys(built),
    framework = framework,
    index = built.index or {},
    languages = languages,
    namespaces = vim.deepcopy(built.namespaces or {}),
    root_kind = root_kind,
    roots = roots,
  }
  table.sort(catalog.namespaces)
  return catalog, nil
end

---@param catalog I18nStatusFrameworkCatalog
---@return string
function M.fallback_namespace(catalog)
  if #catalog.namespaces == 1 then
    return catalog.namespaces[1]
  end
  for _, namespace in ipairs(catalog.namespaces) do
    if namespace == "translation" then
      return namespace
    end
  end
  return catalog.namespaces[1] or "common"
end

---@param entries table<string, I18nStatusResourceItem>|nil
---@param target_key string
---@param excluded_key string|nil
---@return boolean
function M.entries_conflict(entries, target_key, excluded_key)
  local descendant_prefix = target_key .. "."
  for key, _ in pairs(entries or {}) do
    if
      key ~= excluded_key
      and (
        key == target_key
        or key:sub(1, #descendant_prefix) == descendant_prefix
        or target_key:sub(1, #key + 1) == key .. "."
      )
    then
      return true
    end
  end
  return false
end

---@param catalog I18nStatusFrameworkCatalog
---@param target_key string
---@param languages string[]|nil
---@return string|nil conflicting_language
function M.target_conflict(catalog, target_key, languages)
  local checked = languages or catalog.languages
  for _, language in ipairs(checked) do
    if M.entries_conflict(catalog.index[language], target_key, nil) then
      return language
    end
  end
  return nil
end

---@param actual string[]
---@param expected string[]
---@return boolean
function M.same_languages(actual, expected)
  local left = vim.deepcopy(actual or {})
  local right = vim.deepcopy(expected or {})
  table.sort(left)
  table.sort(right)
  return vim.deep_equal(left, right)
end

return M
