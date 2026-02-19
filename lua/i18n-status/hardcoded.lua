---@class I18nStatusHardcoded
local M = {}

local rpc = require("i18n-status.rpc")
local util = require("i18n-status.util")

---@param bufnr integer
---@return string
local function lang_for_buf(bufnr)
  return util.lang_for_filetype(vim.bo[bufnr].filetype)
end

---@param bufnr integer
---@return string
local function buf_source(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

---@param bufnr integer
---@param opts? { range?: { start_line: integer, end_line: integer }, min_length?: integer, exclude_components?: string[] }
---@return table[]
function M.extract(bufnr, opts)
  local lang = lang_for_buf(bufnr)
  if lang == "" then
    return {}
  end
  opts = opts or {}
  local result, err = rpc.request_sync("hardcoded/extract", {
    source = buf_source(bufnr),
    lang = lang,
    range = opts.range and {
      start_line = opts.range.start_line,
      end_line = opts.range.end_line,
    } or vim.NIL,
    min_length = opts.min_length or 2,
    exclude_components = opts.exclude_components or { "Trans", "Translation" },
  })
  if err or not result then
    return {}
  end
  return result.items or {}
end

return M
