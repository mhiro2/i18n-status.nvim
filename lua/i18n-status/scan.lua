---@class I18nStatusScan
local M = {}

local rpc = require("i18n-status.rpc")
local util = require("i18n-status.util")

---@param bufnr integer
---@return string
local function buf_source(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

---@param bufnr integer
---@return string
local function lang_for_buf(bufnr)
  return util.lang_for_filetype(vim.bo[bufnr].filetype)
end

---@param value string
---@param fallback_ns string
---@return table[]
local function regex_extract(value, fallback_ns)
  local items = {}
  local line_num = 0
  for line in (value .. "\n"):gmatch("([^\n]*)\n") do
    local col = 1
    while true do
      local s, e, key = line:find("t%s*%(%s*[\"']([^\"']+)[\"']", col)
      if not s then
        break
      end
      local ns = key:match("^(.-):")
      local canonical = key
      local fallback = false
      if not ns then
        ns = fallback_ns
        canonical = ns .. ":" .. key
        fallback = true
      end
      table.insert(items, {
        key = canonical,
        raw = key,
        namespace = ns,
        lnum = line_num,
        col = s - 1,
        end_col = e,
        fallback = fallback,
      })
      col = e + 1
    end
    line_num = line_num + 1
  end
  return items
end

---@param source string
---@param lang string
---@param opts { fallback_namespace?: string, range?: { start_line: integer, end_line: integer } }
---@return table
local function extract_params(source, lang, opts)
  return {
    source = source,
    lang = lang,
    fallback_namespace = opts.fallback_namespace or "",
    range = opts.range and {
      start_line = opts.range.start_line,
      end_line = opts.range.end_line,
    } or vim.NIL,
  }
end

---@param source string
---@param info { namespace?: string|nil, is_root?: boolean|nil }
---@param opts { range?: { start_line: integer, end_line: integer } }
---@return table
local function extract_resource_params(source, info, opts)
  return {
    source = source,
    namespace = info.namespace or "",
    is_root = info.is_root or false,
    range = opts.range and {
      start_line = opts.range.start_line,
      end_line = opts.range.end_line,
    } or vim.NIL,
  }
end

---@param source string
---@param lang string
---@param row integer
---@param fallback_ns string
---@return table|nil
local function request_translation_context(source, lang, row, fallback_ns)
  local result, err = rpc.request_sync("scan/translationContextAt", {
    source = source,
    lang = lang,
    row = row,
    fallback_namespace = fallback_ns,
  })
  if err then
    return nil
  end
  return result
end

---@param bufnr integer
---@param opts? { fallback_namespace?: string, range?: { start_line: integer, end_line: integer } }
---@return table[]
function M.extract(bufnr, opts)
  local lang = lang_for_buf(bufnr)
  if lang == "" then
    return {}
  end
  opts = opts or {}
  local result, err = rpc.request_sync("scan/extract", extract_params(buf_source(bufnr), lang, opts))
  if err or not result then
    return {}
  end
  return result.items or {}
end

---@param source string
---@param lang string|nil
---@param opts? { fallback_namespace?: string, range?: { start_line: integer, end_line: integer } }
---@return table[]
function M.extract_text(source, lang, opts)
  opts = opts or {}
  local fallback_ns = opts.fallback_namespace or ""
  if not lang or lang == "" then
    return regex_extract(source, fallback_ns)
  end
  local result, err = rpc.request_sync("scan/extract", extract_params(source, lang, opts))
  if err or not result then
    return {}
  end
  return result.items or {}
end

---@param bufnr integer
---@param info { namespace?: string|nil, is_root?: boolean|nil }
---@param opts? { range?: { start_line: integer, end_line: integer } }
---@return table[]
function M.extract_resource(bufnr, info, opts)
  opts = opts or {}
  local result, err = rpc.request_sync("scan/extractResource", extract_resource_params(buf_source(bufnr), info, opts))
  if err or not result then
    return {}
  end
  return result.items or {}
end

---@param bufnr integer
---@param opts? { fallback_namespace?: string, range?: { start_line: integer, end_line: integer } }
---@param cb fun(items: table[])
function M.extract_async(bufnr, opts, cb)
  local lang = lang_for_buf(bufnr)
  if lang == "" then
    cb({})
    return
  end
  opts = opts or {}
  rpc.request("scan/extract", extract_params(buf_source(bufnr), lang, opts), function(err, result)
    if err or not result then
      cb({})
      return
    end
    cb(result.items or {})
  end)
end

---@param bufnr integer
---@param info { namespace?: string|nil, is_root?: boolean|nil }
---@param opts? { range?: { start_line: integer, end_line: integer } }
---@param cb fun(items: table[])
function M.extract_resource_async(bufnr, info, opts, cb)
  opts = opts or {}
  rpc.request("scan/extractResource", extract_resource_params(buf_source(bufnr), info, opts), function(err, result)
    if err or not result then
      cb({})
      return
    end
    cb(result.items or {})
  end)
end

---@param bufnr integer
---@param row integer
---@param opts? { fallback_namespace?: string }
---@return { namespace: string|nil, t_func: string, found_hook: boolean, has_any_hook: boolean }
function M.translation_context_at(bufnr, row, opts)
  opts = opts or {}
  local fallback_ns = opts.fallback_namespace or ""
  local lang = lang_for_buf(bufnr)
  if lang == "" then
    return { namespace = fallback_ns, t_func = "t", found_hook = false, has_any_hook = false }
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local source = table.concat(lines, "\n")
  local result = request_translation_context(source, lang, row, fallback_ns)
  if not result and row + 1 <= #lines then
    local patched = vim.deepcopy(lines)
    patched[row + 1] = ""
    result = request_translation_context(table.concat(patched, "\n"), lang, row, fallback_ns)
  end
  if not result and row > 0 then
    local clipped = {}
    for i = 1, row do
      clipped[#clipped + 1] = lines[i] or ""
    end
    result = request_translation_context(table.concat(clipped, "\n"), lang, row - 1, fallback_ns)
  end
  if not result then
    return { namespace = fallback_ns, t_func = "t", found_hook = false, has_any_hook = false }
  end
  return {
    namespace = result.namespace,
    t_func = result.t_func or "t",
    found_hook = result.found_hook or false,
    has_any_hook = result.has_any_hook or false,
  }
end

return M
