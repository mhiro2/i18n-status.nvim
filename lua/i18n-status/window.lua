---@class I18nStatusWindow
local M = {}

---@param bufnr integer
---@return integer, integer
function M.visible_range(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return 1, vim.api.nvim_buf_line_count(bufnr)
  end

  local top = nil
  local bottom = nil
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      local win_top = vim.fn.line("w0", win)
      local win_bottom = vim.fn.line("w$", win)
      if top == nil or win_top < top then
        top = win_top
      end
      if bottom == nil or win_bottom > bottom then
        bottom = win_bottom
      end
    end
  end

  if top == nil or bottom == nil then
    return 1, vim.api.nvim_buf_line_count(bufnr)
  end
  return top, bottom
end

return M
