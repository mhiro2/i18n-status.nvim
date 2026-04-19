---@class I18nStatusTreesitter
local M = {}

---@type boolean
local aliases_registered = false

---@type table<string, string>
local FILETYPE_ALIASES = {
  javascriptreact = "jsx",
  jsonc = "json",
  typescriptreact = "tsx",
}

function M.register_language_aliases()
  if aliases_registered then
    return
  end
  aliases_registered = true

  for filetype, lang in pairs(FILETYPE_ALIASES) do
    vim.treesitter.language.register(lang, filetype)
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
