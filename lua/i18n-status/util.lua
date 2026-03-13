---@class I18nStatusUtil
local M = {}

---@param base table
---@param extra table
---@return table
function M.tbl_deep_merge(base, extra)
  return vim.tbl_deep_extend("force", {}, base, extra or {})
end

return M
