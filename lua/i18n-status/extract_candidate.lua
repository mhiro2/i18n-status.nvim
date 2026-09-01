---@class I18nStatusExtractCandidateHelpers
local M = {}

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

  local namespace, key_path = candidate.proposed_key:match("^([^:]+):(.+)$")
  if not namespace or not key_path then
    return nil, "canonical translation key is unavailable"
  end
  if namespace ~= candidate.namespace then
    return nil, "translation namespace does not match the scoped translator"
  end
  return key_path, nil
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
