---@class I18nStatusTSHelpers
local M = {}

---@class I18nStatusLineRange
---@field start_line integer|nil
---@field end_line integer|nil

---@param bufnr integer
---@return string
function M.get_lang(bufnr)
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

---@param query_cache table<string, table<string, any|boolean>>
---@param lang string
---@param name string
---@param source string
---@return any
function M.get_query(query_cache, lang, name, source)
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

---@param text string
---@return string
function M.strip_quotes(text)
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if (first == '"' and last == '"') or (first == "'" and last == "'") or (first == "`" and last == "`") then
    return text:sub(2, -2)
  end
  return text
end

---@param range table|nil
---@return I18nStatusLineRange|nil
function M.normalize_range(range)
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

return M
