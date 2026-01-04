---@class I18nStatusScan
local M = {}

local query_cache = {}

local QUERY_CONSTS = [[
    (lexical_declaration
      (variable_declarator
        name: (identifier) @id
        value: (_) @val))
]]

local QUERY_NAMESPACES = [[
    (call_expression
      function: (identifier) @func
      arguments: (arguments (string) @arg))
]]

local QUERY_CALL = [[
    (call_expression
      function: (identifier) @func
      arguments: (arguments (_) @arg))
]]

local QUERY_MEMBER = [[
    (call_expression
      function: (member_expression
        object: (identifier) @obj
        property: (property_identifier) @prop)
      arguments: (arguments (_) @arg))
]]

---@param lang string
---@param name string
---@param source string
---@return any
local function get_query(lang, name, source)
  query_cache[lang] = query_cache[lang] or {}
  local cached = query_cache[lang][name]
  if cached == false then
    return nil
  end
  if cached then
    return cached
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, lang, source)
  if not ok then
    query_cache[lang][name] = false
    return nil
  end
  query_cache[lang][name] = parsed
  return parsed
end

---@class I18nStatusScanItem
---@field key string
---@field raw string
---@field namespace string
---@field lnum integer
---@field col integer
---@field end_col integer
---@field bufnr integer
---@field fallback boolean|nil

---@param bufnr integer
---@return string
local function get_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "javascriptreact" or ft == "typescriptreact" then
    return ft:find("typescript") and "tsx" or "jsx"
  end
  if ft == "typescript" then
    return "typescript"
  end
  if ft == "javascript" then
    return "javascript"
  end
  return ft
end

---@param node TSNode
---@param source integer|string
---@return string
local function node_text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

---@param match table
---@param idx integer
---@return TSNode|nil
local function capture_node(match, idx)
  local node = match[idx]
  if type(node) == "table" then
    return node[1]
  end
  return node
end

---@param text string
---@return string
local function strip_quotes(text)
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if (first == '"' and last == '"') or (first == "'" and last == "'") or (first == "`" and last == "`") then
    return text:sub(2, -2)
  end
  return text
end

---@param range table|nil
---@return table|nil
local function normalize_range(range)
  if type(range) ~= "table" then
    return nil
  end
  local start_line = type(range.start_line) == "number" and range.start_line or nil
  local end_line = type(range.end_line) == "number" and range.end_line or nil
  if start_line and start_line < 0 then
    start_line = 0
  end
  if end_line and end_line < 0 then
    end_line = 0
  end
  if start_line and end_line and end_line < start_line then
    end_line = start_line
  end
  if not start_line and not end_line then
    return nil
  end
  return {
    start_line = start_line,
    end_line = end_line,
  }
end

---@param row integer
---@param range table|nil
---@return boolean
local function row_in_range(row, range)
  if not range then
    return true
  end
  if range.start_line and row < range.start_line then
    return false
  end
  if range.end_line and row > range.end_line then
    return false
  end
  return true
end

---@param node TSNode
---@param source integer|string
---@param consts table<string, string>
---@return string|nil
local function eval_string(node, source, consts)
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
  if typ == "binary_expression" then
    local left = node:child(0)
    local op = node:child(1)
    local right = node:child(2)
    if not left or not op or not right or op:type() ~= "+" then
      return nil
    end
    local l = eval_string(left, source, consts)
    local r = eval_string(right, source, consts)
    if l and r then
      return l .. r
    end
    return nil
  end
  if typ == "identifier" then
    return consts[node_text(node, source)]
  end
  return nil
end

---@param node TSNode
---@return TSNode
local function find_scope(node)
  local scope = node
  while scope do
    local t = scope:type()
    if t == "program" or t:find("function") or t == "method_definition" or t == "arrow_function" then
      return scope
    end
    scope = scope:parent()
  end
  return node
end

---@param root TSNode
---@param source integer|string
---@param lang string
---@return table<string, string>
local function collect_consts(root, source, lang)
  local consts = {}
  local query = get_query(lang, "consts", QUERY_CONSTS)
  if not query then
    return consts
  end
  for _, match in query:iter_matches(root, source) do
    local id = capture_node(match, 1)
    local val = capture_node(match, 2)
    if id and val then
      local value = eval_string(val, source, consts)
      if value then
        consts[node_text(id, source)] = value
      end
    end
  end
  return consts
end

---@param root TSNode
---@param source integer|string
---@param lang string
---@return table
local function collect_namespaces(root, source, lang)
  local scopes = {}
  local query = get_query(lang, "namespaces", QUERY_NAMESPACES)
  if not query then
    return scopes
  end
  for _, match in query:iter_matches(root, source) do
    local func = capture_node(match, 1)
    local arg = capture_node(match, 2)
    if func and arg then
      local name = node_text(func, source)
      if name == "useTranslation" or name == "useTranslations" or name == "getTranslations" then
        local ns = strip_quotes(node_text(arg, source))
        local scope = find_scope(func)
        local start_row, _, end_row, _ = scope:range()
        table.insert(scopes, { ns = ns, start_row = start_row, end_row = end_row })
      end
    end
  end
  table.sort(scopes, function(a, b)
    return (a.end_row - a.start_row) < (b.end_row - b.start_row)
  end)
  return scopes
end

---@param scopes table
---@param row integer
---@return string|nil
local function namespace_for(scopes, row)
  for _, scope in ipairs(scopes) do
    if row >= scope.start_row and row <= scope.end_row then
      return scope.ns
    end
  end
  return nil
end

---@param bufnr integer|nil
---@param opts table
---@param range table|nil
---@param lines string[]|nil
---@return I18nStatusScanItem[]
local function fallback_extract(bufnr, opts, range, lines)
  local items = {}
  local fallback_ns = opts and opts.fallback_namespace or nil
  local current_ns = nil
  local source_lines = lines
  if not source_lines then
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return items
    end
    source_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local function add_item(value, row, col, end_col)
    local key = value
    local ns = key:match("^(.-):")
    local used_fallback = false
    if not ns then
      ns = current_ns or fallback_ns or "common"
      used_fallback = current_ns == nil
      key = ns .. ":" .. key
    end
    table.insert(items, {
      key = key,
      raw = value,
      namespace = ns,
      lnum = row,
      col = col,
      end_col = end_col,
      bufnr = bufnr,
      fallback = used_fallback,
    })
  end

  local function update_namespace(line)
    local patterns = { "useTranslation", "useTranslations", "getTranslations" }
    for _, name in ipairs(patterns) do
      local ns = line:match(name .. "%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
      if ns then
        current_ns = ns
        return
      end
    end
  end

  for i, line in ipairs(source_lines) do
    update_namespace(line)
    local row = i - 1
    if row_in_range(row, range) then
      local idx = 1
      while true do
        local s, e, quote, value = line:find("t%s*%(%s*(['\"])(.-)%1%s*%)", idx)
        if not s then
          break
        end
        local prev = line:sub(s - 1, s - 1)
        if prev == "." or prev == "" or not prev:match("[%w_]") then
          local quote_pos = line:find(quote, s, true)
          if quote_pos then
            local col = quote_pos - 1
            local end_col = col + #value + 2
            add_item(value, row, col, end_col)
          end
        end
        idx = e + 1
      end
    end
  end

  return items
end

---@param lang string
---@param parser TSParser
---@param source integer|string
---@param opts table
---@param range table|nil
---@param meta? { bufnr?: integer, lines?: string[], allow_fallback?: boolean }
---@return I18nStatusScanItem[]
local function extract_from_parser(lang, parser, source, opts, range, meta)
  meta = meta or {}
  local items = {}
  local tree = parser:parse()[1]
  if not tree then
    return items
  end
  local root = tree:root()
  local consts = collect_consts(root, source, lang)
  local scopes = collect_namespaces(root, source, lang)

  local query_call = get_query(lang, "call", QUERY_CALL)
  local query_member = get_query(lang, "member", QUERY_MEMBER)
  if not query_call and not query_member then
    if meta.allow_fallback then
      return fallback_extract(meta.bufnr, opts, range, meta.lines)
    end
    return items
  end

  local function handle_call(arg)
    local value = eval_string(arg, source, consts)
    if not value then
      return
    end
    local row = select(1, arg:range())
    if not row_in_range(row, range) then
      return
    end
    local key = value
    local ns = nil
    local used_fallback = false
    if key:find(":", 1, true) then
      ns = key:match("^(.-):")
    else
      ns = namespace_for(scopes, row)
    end
    if not ns then
      used_fallback = true
      ns = (opts and opts.fallback_namespace) or "common"
    end
    if not key:find(":", 1, true) then
      key = ns .. ":" .. key
    end
    local _, col, _, end_col = arg:range()
    table.insert(items, {
      key = key,
      raw = value,
      namespace = ns,
      lnum = row,
      col = col,
      end_col = end_col,
      bufnr = meta.bufnr,
      fallback = used_fallback,
    })
  end

  if query_call then
    for _, match in query_call:iter_matches(root, source) do
      local func = capture_node(match, 1)
      local arg = capture_node(match, 2)
      if func and arg and node_text(func, source) == "t" then
        handle_call(arg)
      end
    end
  end

  if query_member then
    for _, match in query_member:iter_matches(root, source) do
      local prop = capture_node(match, 2)
      local arg = capture_node(match, 3)
      if prop and arg and node_text(prop, source) == "t" then
        handle_call(arg)
      end
    end
  end

  return items
end

---@param bufnr integer
---@param opts? { fallback_namespace?: string, range?: { start_line?: integer, end_line?: integer } }
---@return I18nStatusScanItem[]
function M.extract(bufnr, opts)
  local items = {}
  local lang = get_lang(bufnr)
  local range = normalize_range(opts and opts.range or nil)
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
    return fallback_extract(bufnr, opts, range)
  end
  return extract_from_parser(lang, parser, bufnr, opts, range, { bufnr = bufnr, allow_fallback = true })
end

---@param text string
---@param lang string|nil
---@param opts? { fallback_namespace?: string, range?: { start_line?: integer, end_line?: integer } }
---@return I18nStatusScanItem[]
function M.extract_text(text, lang, opts)
  if not text or text == "" then
    return {}
  end
  local range = normalize_range(opts and opts.range or nil)
  local lines = vim.split(text, "\n", { plain = true })
  if not lang or lang == "" then
    return fallback_extract(nil, opts, range, lines)
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return fallback_extract(nil, opts, range, lines)
  end
  return extract_from_parser(lang, parser, text, opts, range, { bufnr = nil, lines = lines, allow_fallback = true })
end

---@param node TSNode|nil
---@param source integer|string
---@return string|nil
local function json_key_text(node, source)
  if not node then
    return nil
  end
  return strip_quotes(node_text(node, source))
end

---@param bufnr integer
---@param info { namespace: string|nil, is_root: boolean }
---@param opts? { range?: { start_line?: integer, end_line?: integer } }
---@return I18nStatusScanItem[]
function M.extract_resource(bufnr, info, opts)
  local items = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return items
  end
  if not info or (not info.is_root and (not info.namespace or info.namespace == "")) then
    return items
  end
  local range = normalize_range(opts and opts.range or nil)
  local ft = vim.bo[bufnr].filetype
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, ft)
  if not ok or not parser then
    if ft == "jsonc" then
      ok, parser = pcall(vim.treesitter.get_parser, bufnr, "json")
    else
      ok, parser = pcall(vim.treesitter.get_parser, bufnr, "jsonc")
      if not ok or not parser then
        ok, parser = pcall(vim.treesitter.get_parser, bufnr, "json")
      end
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
  local source = bufnr
  if root:type() == "document" then
    root = root:named_child(0) or root
  end

  local function add_item(namespace, key_path, key_node)
    if not namespace or namespace == "" or not key_path or key_path == "" then
      return
    end
    local row, col, _, end_col = key_node:range()
    if not row_in_range(row, range) then
      return
    end
    table.insert(items, {
      key = namespace .. ":" .. key_path,
      raw = key_path,
      namespace = namespace,
      lnum = row,
      col = col,
      end_col = end_col,
      bufnr = bufnr,
    })
  end

  local function walk_object(node, namespace, prefix)
    for child in node:iter_children() do
      if child:type() == "pair" then
        local key_node = child:child(0)
        local val_node = child:child(2) or child:child(1)
        local key = json_key_text(key_node, source)
        if key and key ~= "" then
          local path = prefix ~= "" and (prefix .. "." .. key) or key
          local val_type = val_node and val_node:type() or ""
          if val_type == "object" then
            walk_object(val_node, namespace, path)
          elseif val_type ~= "array" then
            add_item(namespace, path, key_node)
          end
        end
      end
    end
  end

  if info.is_root then
    if root and root:type() == "object" then
      for child in root:iter_children() do
        if child:type() == "pair" then
          local key_node = child:child(0)
          local val_node = child:child(2) or child:child(1)
          local namespace = json_key_text(key_node, source)
          if namespace and namespace ~= "" and val_node and val_node:type() == "object" then
            walk_object(val_node, namespace, "")
          end
        end
      end
    end
  elseif info.namespace and root and root:type() == "object" then
    walk_object(root, info.namespace, "")
  end

  return items
end

---@param bufnr integer
---@param row integer
---@param opts table|nil
---@return string
function M.namespace_at(bufnr, row, opts)
  local fallback_ns = opts and opts.fallback_namespace or nil
  local lang = get_lang(bufnr)
  if lang == "" then
    return fallback_ns
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
    local current_ns = fallback_ns
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
    for _, line in ipairs(lines) do
      local patterns = { "useTranslation", "useTranslations", "getTranslations" }
      for _, name in ipairs(patterns) do
        local ns = line:match(name .. "%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
        if ns then
          current_ns = ns
        end
      end
    end
    return current_ns
  end
  local tree = parser:parse()[1]
  if not tree then
    return fallback_ns
  end
  local scopes = collect_namespaces(tree:root(), bufnr, lang)
  return namespace_for(scopes, row) or fallback_ns
end

return M
