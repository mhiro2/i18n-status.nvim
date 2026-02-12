---@class I18nStatusHardcoded
local M = {}

local query_cache = {}
local ts_helpers = require("i18n-status.ts_helpers")

local QUERY_JSX_TEXT = [[
  (jsx_text) @text
]]

local QUERY_JSX_EXPR = [[
  (jsx_expression (_) @expr)
]]

---@class I18nStatusHardcodedItem
---@field bufnr integer
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field text string
---@field kind "jsx_text"|"jsx_literal"

---@param bufnr integer
---@return string
local get_lang = ts_helpers.get_lang

---@param lang string
---@param name string
---@param source string
---@return any
local function get_query(lang, name, source)
  return ts_helpers.get_query(query_cache, lang, name, source)
end

---@param node TSNode
---@param source integer|string
---@return string
local function node_text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

---@param text string
---@return string
local strip_quotes = ts_helpers.strip_quotes

---@param text string
---@return string
local function normalize_whitespace(text)
  local single_line = text:gsub("%s+", " ")
  return vim.trim(single_line)
end

---@param node TSNode|nil
---@param source integer|string
---@return string|nil
local function eval_literal(node, source)
  if not node then
    return nil
  end
  local typ = node:type()
  if typ == "string" then
    return strip_quotes(node_text(node, source))
  end
  if typ == "template_string" then
    for child in node:iter_children() do
      if child:type() == "template_substitution" then
        return nil
      end
    end
    return strip_quotes(node_text(node, source))
  end
  if typ == "parenthesized_expression" then
    for child in node:iter_children() do
      local value = eval_literal(child, source)
      if value then
        return value
      end
    end
  end
  return nil
end

---@param node TSNode
---@param source integer|string
---@return string|nil
local function first_field(node, name)
  if not node then
    return nil
  end
  local values = node:field(name)
  if type(values) == "table" then
    return values[1]
  end
  return nil
end

---@param node TSNode
---@param source integer|string
---@return string|nil
local function component_name(node, source)
  local name_node = first_field(node, "name")
  if not name_node then
    local first = node:child(0)
    if first then
      name_node = first_field(first, "name")
    end
  end
  if not name_node then
    return nil
  end
  return node_text(name_node, source)
end

---@param node TSNode
---@param source integer|string
---@param exclude_set table<string, boolean>
---@return boolean
local function inside_excluded_component(node, source, exclude_set)
  local cur = node
  while cur do
    local typ = cur:type()
    if typ == "jsx_element" or typ == "jsx_self_closing_element" then
      local full_name = component_name(cur, source)
      if full_name and full_name ~= "" then
        local short_name = full_name:match("([%w_]+)$") or full_name
        if exclude_set[full_name] or exclude_set[short_name] then
          return true
        end
      end
    end
    cur = cur:parent()
  end
  return false
end

---@param node TSNode
---@param source integer|string
---@return boolean
local function inside_t_call(node, source)
  local cur = node
  while cur do
    if cur:type() == "call_expression" then
      local func = first_field(cur, "function")
      if func then
        if func:type() == "identifier" and node_text(func, source) == "t" then
          return true
        end
        if func:type() == "member_expression" then
          local prop = first_field(func, "property")
          if prop and node_text(prop, source) == "t" then
            return true
          end
        end
      end
    end
    cur = cur:parent()
  end
  return false
end

---@param range table|nil
---@return table|nil
local normalize_range = ts_helpers.normalize_range

---@param start_row integer
---@param end_row integer
---@param range table|nil
---@return boolean
local function in_range(start_row, end_row, range)
  if not range then
    return true
  end
  if range.start_line and end_row < range.start_line then
    return false
  end
  if range.end_line and start_row > range.end_line then
    return false
  end
  return true
end

---@param items I18nStatusHardcodedItem[]
---@param node TSNode
---@param source integer
---@param kind "jsx_text"|"jsx_literal"
---@param text string
local function push_item(items, node, source, kind, text)
  local start_row, start_col, end_row, end_col = node:range()
  table.insert(items, {
    bufnr = source,
    lnum = start_row,
    col = start_col,
    end_lnum = end_row,
    end_col = end_col,
    text = text,
    kind = kind,
  })
end

---@param list string[]|nil
---@return table<string, boolean>
local function to_set(list)
  local set = {}
  for _, value in ipairs(list or {}) do
    if type(value) == "string" and value ~= "" then
      set[value] = true
    end
  end
  return set
end

---@param bufnr integer
---@param opts? { range?: { start_line?: integer, end_line?: integer }, min_length?: integer, exclude_components?: string[] }
---@return I18nStatusHardcodedItem[]
function M.extract(bufnr, opts)
  opts = opts or {}
  local items = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return items
  end

  local lang = get_lang(bufnr)
  if lang == "" then
    return items
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    if lang == "tsx" then
      ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typescript")
      lang = "typescript"
    elseif lang == "jsx" then
      ok, parser = pcall(vim.treesitter.get_parser, bufnr, "javascript")
      lang = "javascript"
    end
  end
  if not ok or not parser then
    return items
  end

  local tree = parser:parse()[1]
  if not tree then
    return items
  end
  local root = tree:root()
  local range = normalize_range(opts.range)
  local min_length = type(opts.min_length) == "number" and math.max(0, opts.min_length) or 2
  local exclude_set = to_set(opts.exclude_components or { "Trans", "Translation" })

  local query_text = get_query(lang, "hardcoded_jsx_text", QUERY_JSX_TEXT)
  if query_text then
    for _, match in query_text:iter_matches(root, bufnr) do
      local node = match[1]
      if type(node) == "table" then
        node = node[1]
      end
      if node then
        local start_row, _, end_row, _ = node:range()
        if in_range(start_row, end_row, range) and not inside_excluded_component(node, bufnr, exclude_set) then
          local text = normalize_whitespace(node_text(node, bufnr))
          if #text >= min_length and not inside_t_call(node, bufnr) then
            push_item(items, node, bufnr, "jsx_text", text)
          end
        end
      end
    end
  end

  local query_expr = get_query(lang, "hardcoded_jsx_expr", QUERY_JSX_EXPR)
  if query_expr then
    for _, match in query_expr:iter_matches(root, bufnr) do
      local node = match[1]
      if type(node) == "table" then
        node = node[1]
      end
      if node then
        local start_row, _, end_row, _ = node:range()
        if in_range(start_row, end_row, range) and not inside_excluded_component(node, bufnr, exclude_set) then
          local literal = eval_literal(node, bufnr)
          if literal and #vim.trim(literal) >= min_length and not inside_t_call(node, bufnr) then
            push_item(items, node, bufnr, "jsx_literal", literal)
          end
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.lnum == b.lnum then
      return a.col < b.col
    end
    return a.lnum < b.lnum
  end)

  return items
end

return M
