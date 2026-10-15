---@class I18nStatusExtractCandidateHelpers
local M = {}

local next_intl_key = require("i18n-status.next_intl_key")

---@param candidate I18nStatusExtractCandidate
---@return string|nil
---@return string|nil
function M.source_key(candidate)
  if type(candidate.proposed_key) ~= "string" or candidate.proposed_key == "" then
    return nil, "translation key is unavailable"
  end
  if candidate.source_key_policy == "canonical" then
    return candidate.proposed_key, nil
  end
  if candidate.source_key_policy ~= "namespace_relative" then
    return nil, "source key policy is unavailable"
  end

  if candidate.framework ~= "next_intl" then
    return nil, "namespace-relative source keys are only supported for next-intl"
  end
  return next_intl_key.source_key(candidate.namespace, candidate.proposed_key)
end

---Qualify a key typed without a namespace with the candidate's translator namespace.
---@param candidate I18nStatusExtractCandidate
---@param key string
---@return string
function M.qualify_key(candidate, key)
  local namespace = candidate.namespace
  if key == "" or key:find(":", 1, true) or type(namespace) ~= "string" or namespace == "" then
    return key
  end
  if candidate.framework == "next_intl" then
    return next_intl_key.canonical_key(namespace, key) or key
  end
  return namespace .. ":" .. key
end

---@param candidate I18nStatusExtractCandidate
---@return string|nil
---@return string|nil
function M.replacement(candidate)
  if type(candidate.t_func) ~= "string" or candidate.t_func == "" then
    return nil, "translation function is unavailable"
  end
  local source_key, source_key_err = M.source_key(candidate)
  if not source_key then
    return nil, source_key_err
  end

  local call = string.format('%s("%s")', candidate.t_func, source_key)
  if candidate.replacement_context == "jsx_expression" then
    return call, nil
  end
  if candidate.replacement_context == "jsx_child" then
    return "{" .. call .. "}", nil
  end
  return nil, "unsupported replacement context"
end

return M
