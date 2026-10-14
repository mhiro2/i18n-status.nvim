---Key spelling rules for next-intl translators.
---
---next-intl joins the namespace bound by useTranslations/getTranslations and the source key into
---one dot-separated message path. The plugin identifies a message as `namespace:path`, where the
---namespace is the first path segment (the top-level message object or namespace file).
local M = {}

---Canonical `namespace:path` identity of a next-intl source key.
---@param translator_namespace string|nil Namespace bound to the translator; nil for a root translator
---@param source_key string
---@return string|nil
function M.canonical_key(translator_namespace, source_key)
  local path = translator_namespace and (translator_namespace .. "." .. source_key) or source_key
  local namespace, key_path = path:match("^([^.]+)%.(.+)$")
  if not namespace then
    return nil
  end
  return namespace .. ":" .. key_path
end

---Source key that a translator bound to `translator_namespace` uses to reach a canonical key.
---@param translator_namespace string|nil Namespace bound to the translator; nil for a root translator
---@param key string Canonical `namespace:path` key
---@return string|nil
---@return string|nil error
function M.source_key(translator_namespace, key)
  local namespace, key_path = key:match("^([^:]+):(.+)$")
  if not namespace then
    return nil, "canonical translation key is unavailable"
  end
  local path = namespace .. "." .. key_path
  if not translator_namespace then
    return path, nil
  end
  local prefix = translator_namespace .. "."
  if #path <= #prefix or path:sub(1, #prefix) ~= prefix then
    return nil,
      string.format("key '%s' is outside namespace '%s' bound to the next-intl translator", key, translator_namespace)
  end
  return path:sub(#prefix + 1), nil
end

return M
