---@class I18nStatusRender
local M = {}

local util = require("i18n-status.util")
local state = require("i18n-status.state")

local ns_id = vim.api.nvim_create_namespace("i18n-status")

local highlights_set = false

local function ensure_highlights()
  if highlights_set then
    return
  end
  vim.api.nvim_set_hl(0, "I18nStatusSame", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "I18nStatusDiff", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "I18nStatusFallback", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "I18nStatusMissing", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "I18nStatusMismatch", { link = "DiagnosticError", default = true })
  highlights_set = true
end

---@param config I18nStatusConfig
---@param status string
---@return string
local function status_hl(config, status)
  local hl = (config.inline and config.inline.hl) or {}
  if status == "=" then
    return hl.same or "I18nStatusSame"
  end
  if status == "≠" then
    return hl.diff or "I18nStatusDiff"
  end
  if status == "?" then
    return hl.fallback or "I18nStatusFallback"
  end
  if status == "×" then
    return hl.missing or "I18nStatusMissing"
  end
  if status == "!" then
    return hl.mismatch or "I18nStatusMismatch"
  end
  return hl.text or "Comment"
end

---@param config I18nStatusConfig
---@return string
local function text_hl(config)
  local hl = (config.inline and config.inline.hl) or {}
  return hl.text or "Comment"
end

---@return integer
function M.namespace()
  return ns_id
end

---@param text string
---@param max_len integer
---@return string
local function truncate(text, max_len)
  if max_len <= 0 then
    return ""
  end
  local text_len = vim.fn.strchars(text)
  if text_len <= max_len then
    return text
  end
  local suffix = "..."
  local suffix_len = vim.fn.strchars(suffix)
  local head_len = max_len - suffix_len
  if head_len <= 0 then
    return vim.fn.strcharpart(suffix, 0, max_len)
  end
  return vim.fn.strcharpart(text, 0, head_len) .. suffix
end

---@param bufnr integer
---@param items I18nStatusScanItem[]
---@param resolved I18nStatusResolved[]
---@param config I18nStatusConfig
function M.apply(bufnr, items, resolved, config)
  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  state.inline_by_buf[bufnr] = {}
  state.resolved_by_buf[bufnr] = {
    items = items,
    resolved = resolved,
  }

  local top, bottom = 1, vim.api.nvim_buf_line_count(bufnr)
  if config.inline.visible_only then
    top, bottom = util.visible_range(bufnr)
  end

  -- Force eol position for JSON files to maintain readability
  local ft = vim.bo[bufnr].filetype
  local position = config.inline.position
  if ft == "json" or ft == "jsonc" then
    position = "eol"
  end

  for i, item in ipairs(items) do
    local row = item.lnum
    if row + 1 >= top and row + 1 <= bottom then
      local res = resolved[i]
      if res then
        local text = truncate(res.text, config.inline.max_len)
        local marker = "[" .. res.status .. "]"
        local after_key_prefix = position == "after_key" and " : " or ""
        local virt_text = {}
        if config.inline.status_only or text == "" then
          table.insert(virt_text, { after_key_prefix .. marker, status_hl(config, res.status) })
        else
          table.insert(virt_text, { after_key_prefix .. text, text_hl(config) })
          table.insert(virt_text, { " " .. marker, status_hl(config, res.status) })
        end
        local opts = {
          virt_text = virt_text,
          virt_text_pos = position == "after_key" and "inline" or "eol",
        }
        local col = 0
        if position == "after_key" then
          col = item.end_col
          opts.virt_text_pos = "inline"
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, col, opts)
        state.inline_by_buf[bufnr][row] = state.inline_by_buf[bufnr][row] or {}
        table.insert(state.inline_by_buf[bufnr][row], {
          col = item.col,
          end_col = item.end_col,
          resolved = res,
        })
      end
    end
  end
end

return M
