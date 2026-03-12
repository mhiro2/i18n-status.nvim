---@class I18nStatusReviewFilters
local M = {}

local review_shared_ui = require("i18n-status.review_shared_ui")

---@param query string|nil
---@param opts I18nStatusFilterNormalizeOptions|nil
---@return string|nil
function M.normalize_query(query, opts)
  return review_shared_ui.normalize_filter_query(query, opts)
end

---@param text string|nil
---@param query string|nil
---@param lowercase boolean|nil
---@return boolean
local function contains_query(text, query, lowercase)
  if not query then
    return true
  end
  local haystack = text or ""
  local needle = query
  if lowercase then
    haystack = haystack:lower()
    needle = needle:lower()
  end
  return haystack:find(needle, 1, true) ~= nil
end

---@param items I18nStatusResolved[]|nil
---@param query string|nil
---@return I18nStatusResolved[]
function M.filter_items_by_key(items, query)
  local source = items or {}
  local normalized = M.normalize_query(query)
  if not normalized then
    return source
  end

  local filtered = {}
  for _, item in ipairs(source) do
    if contains_query(item.key, normalized, true) then
      filtered[#filtered + 1] = item
    end
  end
  return filtered
end

---@param candidate I18nStatusExtractCandidate
---@param query string|nil
---@return boolean
function M.candidate_matches(candidate, query)
  if not query then
    return true
  end
  return contains_query(candidate.proposed_key, query, true) or contains_query(candidate.text, query, true)
end

return M
