---@class I18nStatusBlinkSource
---@field private config table|nil
local Source = {}
Source.__index = Source

---@class I18nStatusBlinkCompat
local M = {}

local resources = require("i18n-status.resources")
local state = require("i18n-status.state")
local scan = require("i18n-status.scan")

local SUPPORTED_FILETYPES = {
  javascript = true,
  typescript = true,
  javascriptreact = true,
  typescriptreact = true,
}

---@param key string
---@param value string|nil
---@return boolean
local function is_missing_value(key, value)
  if value == nil or value == "" then
    return true
  end
  if value == key then
    return true
  end
  local key_path = key:match("^[^:]+:(.+)$")
  if key_path and value == key_path then
    return true
  end
  return false
end

---@param text string
---@return integer|nil
local function last_call_start(text)
  local last = nil
  for s in text:gmatch("()t%s*%(") do
    last = s
  end
  for s in text:gmatch("()%.t%s*%(") do
    last = s
  end
  return last
end

---@param line string
---@param col integer
---@return string|nil
local function current_arg_prefix(line, col)
  local before = line:sub(1, col)
  local start = last_call_start(before)
  if not start then
    return nil
  end
  local arg_segment = before:sub(start)
  local quote_pos = arg_segment:find("[\"'`]")
  if not quote_pos then
    return ""
  end
  return arg_segment:sub(quote_pos + 1)
end

---@param ctx table|nil
---@return integer, integer, string
local function current_position(ctx)
  local row, col
  if ctx and ctx.cursor then
    if type(ctx.cursor) == "number" then
      col = ctx.cursor
    elseif type(ctx.cursor) == "table" then
      row = ctx.cursor[1] or ctx.cursor.row
      col = ctx.cursor[2] or ctx.cursor.col
    end
  end
  if not row or not col then
    local cursor = vim.api.nvim_win_get_cursor(0)
    row = row or cursor[1]
    col = col or cursor[2]
  end
  local line = (ctx and type(ctx.line) == "string") and ctx.line or vim.api.nvim_get_current_line()
  return row - 1, col, line
end

---@param ctx table|nil
---@return boolean
local function should_complete(ctx)
  if not ctx or next(ctx) == nil then
    return true
  end
  local _, col, line = current_position(ctx or {})
  if not line or col == nil then
    return true
  end
  local before = line:sub(1, col)
  local start = last_call_start(before)
  if not start then
    return false
  end
  local arg_segment = before:sub(start)
  if arg_segment:find(",") then
    return false
  end
  return true
end

---@param ctx table
---@return table[]
local function get_completion_items(ctx)
  if not should_complete(ctx) then
    return {}
  end

  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local project = state.set_languages(cache.key, cache.languages)
  state.set_buf_project(bufnr, cache.key)
  local primary = (project and project.primary_lang) or cache.languages[1]
  local items = {}
  local entries = cache.index[primary] or {}
  local contextless = not ctx or next(ctx) == nil
  local row, col, line = current_position(ctx or {})
  local prefix = current_arg_prefix(line, col)
  local explicit_ns = false
  local ns = nil

  if not contextless then
    if prefix and prefix:find(":", 1, true) then
      ns = prefix:match("^(.-):")
      explicit_ns = true
    else
      local hint, reason = resources.namespace_hint(start_dir)
      local fallback_ns = reason == "single" and hint or nil
      ns = scan.namespace_at(bufnr, row, { fallback_namespace = fallback_ns })
    end
  end

  local MAX_COMPLETION_ITEMS = 100
  local item_count = 0

  for key, entry in pairs(entries) do
    if key ~= "__error__" then
      local include = true
      if ns and key:sub(1, #ns + 1) ~= ns .. ":" then
        include = false
      end
      if include then
        local insert_key = key
        local label = key
        if ns and not explicit_ns then
          insert_key = key:match("^[^:]+:(.+)$") or key
          label = insert_key
        end
        local sort_text = is_missing_value(key, entry.value) and "0" .. key or "1" .. key
        table.insert(items, {
          label = label,
          insertText = insert_key,
          sortText = sort_text,
          kind = vim.lsp.protocol.CompletionItemKind.Text,
          documentation = entry.value,
        })

        item_count = item_count + 1
        if item_count >= MAX_COMPLETION_ITEMS then
          -- Reached limit, return without sorting for performance
          return items
        end
      end
    end
  end

  -- Only sort if below limit
  table.sort(items, function(a, b)
    return a.sortText < b.sortText
  end)

  return items
end

-- Backwards compatible: nvim-cmp style completion
---@param ctx table
---@param callback fun(items: table[])
function M.complete(ctx, callback)
  local items = get_completion_items(ctx)
  callback(items)
end

-- BLINK.CMP SOURCE PROTOCOL IMPLEMENTATION

---@param config table|nil
---@return I18nStatusBlinkSource
function Source.new(config)
  local self = setmetatable({}, Source)
  self.config = config or {}
  return self
end

---@param ctx table
---@param callback fun(items: table[])
function Source:complete(ctx, callback)
  local items = get_completion_items(ctx)
  callback(items)
end

---@param ctx table
---@param callback fun(response: table|nil)
function Source:get_completions(ctx, callback)
  local items = get_completion_items(ctx)
  callback({
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

---@return string[]
function Source:get_trigger_characters()
  return { '"', "'", "`", ":" }
end

---@return boolean
function Source:enabled()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  return SUPPORTED_FILETYPES[ft] == true
end

---@param ctx table
---@return boolean
function Source:is_available(ctx)
  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if not SUPPORTED_FILETYPES[ft] then
    return false
  end
  local row, col, line = current_position(ctx or {})
  return should_complete({ cursor = { row, col }, line = line })
end

---@param _ctx table
---@param _item table
---@param callback fun()
---@param default_implementation fun()
function Source:execute(_ctx, _item, callback, default_implementation)
  -- No special execution needed for i18n keys
  if default_implementation then
    default_implementation()
  end
  callback()
end

-- Export both old style (M) and new style (Source)
M.Source = Source
M.new = Source.new

return M
