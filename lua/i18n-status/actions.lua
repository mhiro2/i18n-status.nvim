---@class I18nStatusActions
local M = {}

local ui = require("i18n-status.ui")
local state = require("i18n-status.state")

---@param bufnr integer
---@return integer|nil
local function window_for_buf(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == bufnr then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---@param path string
local function edit_file(path)
  vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
end

---@param bufnr integer
---@return I18nStatusResolved|nil
function M.item_at_cursor(bufnr)
  local winid = window_for_buf(bufnr)
  if not winid then
    return nil
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
  row = row - 1
  local entries = state.inline_by_buf[bufnr] and state.inline_by_buf[bufnr][row] or nil
  if not entries then
    return nil
  end
  for _, entry in ipairs(entries) do
    if col >= entry.col and col <= entry.end_col then
      return entry.resolved
    end
  end
  return nil
end

---@param item I18nStatusResolved
---@param opts { lang?: string }?
---@return boolean
function M.jump_to_definition(item, opts)
  opts = opts or {}
  if not item or not item.hover or not item.hover.values then
    return false
  end

  local order = {}
  local project = state.project_for_buf(vim.api.nvim_get_current_buf())
  local preferred = opts.lang
    or (project and project.current_lang)
    or (project and project.primary_lang)
    or (item.hover and item.hover.display_lang)
  if preferred then
    table.insert(order, preferred)
  end
  if project and project.primary_lang then
    table.insert(order, project.primary_lang)
  end
  for lang, _ in pairs(item.hover.values) do
    table.insert(order, lang)
  end

  local seen = {}
  for _, lang in ipairs(order) do
    if not seen[lang] then
      seen[lang] = true
      local info = item.hover.values[lang]
      if info and info.file then
        edit_file(info.file)
        return true
      end
    end
  end

  return false
end

---@param bufnr integer
function M.hover(bufnr)
  local item = M.item_at_cursor(bufnr)
  if not item then
    return
  end
  local lines = ui.format_hover_lines(item)
  ui.open_hover(lines)
end

return M
