---@class I18nStatusResolve
local M = {}

local rpc = require("i18n-status.rpc")

---@param key string
---@return string
local function namespace_from_key(key)
  local ns = key and key:match("^(.-):")
  return ns or ""
end

---@param key string
---@return string
local function raw_from_key(key)
  return (key and key:match("^[^:]+:(.+)$")) or key or ""
end

---@param items table[]
---@return table[]
local function normalize_items(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local key = item.key or ""
    out[#out + 1] = {
      key = key,
      raw = item.raw or raw_from_key(key),
      namespace = item.namespace or namespace_from_key(key),
      fallback = item.fallback == true,
    }
  end
  return out
end

---@param index table
---@return table
local function normalize_index(index)
  local out = vim.empty_dict()
  for lang, lang_items in pairs(index or {}) do
    local normalized_lang_items = vim.empty_dict()
    for key, entry in pairs(lang_items or {}) do
      if type(key) == "string" then
        normalized_lang_items[key] = {
          value = entry and entry.value or nil,
          file = entry and entry.file or nil,
          priority = entry and entry.priority or 0,
        }
      end
    end
    out[lang] = normalized_lang_items
  end
  return out
end

---@param items table[]
---@param project { primary_lang?: string, languages?: string[], current_lang?: string|nil }
---@param index table
---@return table[]
function M.compute(items, project, index)
  project = project or {}
  local result, err = rpc.request_sync("resolve/compute", {
    items = normalize_items(items),
    primary_lang = project.primary_lang or "",
    languages = project.languages or {},
    index = normalize_index(index),
    current_lang = project.current_lang,
  })
  if err or not result then
    return {}
  end
  return result.resolved or {}
end

---@param items table[]
---@param project { primary_lang?: string, languages?: string[], current_lang?: string|nil }
---@param index table
---@param cb fun(resolved: table[])
function M.compute_async(items, project, index, cb)
  project = project or {}
  rpc.request("resolve/compute", {
    items = normalize_items(items),
    primary_lang = project.primary_lang or "",
    languages = project.languages or {},
    index = normalize_index(index),
    current_lang = project.current_lang,
  }, function(err, result)
    if err or not result then
      cb({})
      return
    end
    cb(result.resolved or {})
  end)
end

return M
