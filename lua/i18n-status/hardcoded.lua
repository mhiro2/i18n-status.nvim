---@class I18nStatusHardcoded
local M = {}

local rpc = require("i18n-status.rpc")
local util = require("i18n-status.util")
local RETRYABLE_RPC_ERRORS = {
  ["process not running"] = true,
  ["stdin not available"] = true,
  ["sync request timeout"] = true,
}
local RPC_RETRY_MAX_ATTEMPTS = 5
local RPC_RETRY_WAIT_MS = 80

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

---@param err string|nil
---@return boolean
local function is_retryable_rpc_error(err)
  if type(err) ~= "string" then
    return false
  end
  if RETRYABLE_RPC_ERRORS[err] then
    return true
  end
  if err:find("process exited", 1, true) then
    return true
  end
  if err:find("write failed", 1, true) then
    return true
  end
  return false
end

---@param wait_ms integer
local function wait_for_retry(wait_ms)
  vim.wait(wait_ms, function()
    return false
  end, 10)
end

---@param bufnr integer
---@param opts? { range?: { start_line: integer, end_line: integer }, min_length?: integer, exclude_components?: string[] }
---@return table[]
---@return string|nil
function M.extract(bufnr, opts)
  local lang = lang_for_buf(bufnr)
  if lang == "" then
    return {}, nil
  end
  opts = opts or {}
  local params = {
    source = buf_source(bufnr),
    lang = lang,
    range = opts.range and {
      start_line = opts.range.start_line,
      end_line = opts.range.end_line,
    } or vim.NIL,
    min_length = opts.min_length or 2,
    exclude_components = opts.exclude_components or { "Trans", "Translation" },
  }
  local result, err = nil, nil
  for attempt = 1, RPC_RETRY_MAX_ATTEMPTS do
    result, err = rpc.request_sync("hardcoded/extract", params)
    if not err and result then
      break
    end
    if not is_retryable_rpc_error(err) or attempt == RPC_RETRY_MAX_ATTEMPTS then
      break
    end
    wait_for_retry(RPC_RETRY_WAIT_MS)
  end
  if is_retryable_rpc_error(err) then
    return {}, err
  end
  if err or not result then
    return {}, err or "rpc returned no result"
  end
  return result.items or {}, nil
end

return M
