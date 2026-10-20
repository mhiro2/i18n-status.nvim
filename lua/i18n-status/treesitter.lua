---@class I18nStatusTreesitter
local M = {}

---@type boolean
local aliases_registered = false

-- Tree-sitter parser names; JSX is part of the javascript grammar.
---@type table<string, string>
local FILETYPE_ALIASES = {
  javascriptreact = "javascript",
  jsonc = "json",
  typescriptreact = "tsx",
}

function M.register_language_aliases()
  if aliases_registered then
    return
  end
  aliases_registered = true

  for filetype, lang in pairs(FILETYPE_ALIASES) do
    -- Keep mappings set by the user or other plugins, and parsers named after the filetype.
    if vim.treesitter.language.get_lang(filetype) == filetype and not M.has_parser(filetype) then
      vim.treesitter.language.register(lang, filetype)
    end
  end
end

---@param filetype string
---@return string|nil
function M.parser_lang_for_filetype(filetype)
  M.register_language_aliases()
  return vim.treesitter.language.get_lang(filetype)
end

---@param lang string
---@return boolean
---@return string|nil
function M.has_parser(lang)
  local ok, err = vim.treesitter.language.add(lang)
  return ok == true, err
end

return M
