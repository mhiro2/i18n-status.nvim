local treesitter = require("i18n-status.treesitter")

---Load a fresh copy of the module so aliases register again.
---@return I18nStatusTreesitter
local function reload()
  package.loaded["i18n-status.treesitter"] = nil
  local fresh = require("i18n-status.treesitter")
  package.loaded["i18n-status.treesitter"] = treesitter
  return fresh
end

describe("treesitter", function()
  it("registers parser aliases without nvim-treesitter", function()
    treesitter.register_language_aliases()

    assert.are.equal("javascript", treesitter.parser_lang_for_filetype("javascriptreact"))
    assert.are.equal("tsx", treesitter.parser_lang_for_filetype("typescriptreact"))
    assert.are.equal("json", treesitter.parser_lang_for_filetype("jsonc"))
  end)

  it("parses JSX in javascriptreact buffers", function()
    treesitter.register_language_aliases()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "const el = <p>Hello</p>;" })
    vim.bo[buf].filetype = "javascriptreact"

    local ok, parser = pcall(vim.treesitter.get_parser, buf)

    assert.is_true(ok, tostring(parser))
    assert.is_truthy(parser)
    assert.is_false(parser:parse()[1]:root():has_error())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps mappings registered by the user or other plugins", function()
    local original = vim.treesitter.language.get_lang("javascriptreact")
    vim.treesitter.language.register("tsx", "javascriptreact")

    local ok, err = pcall(function()
      reload().register_language_aliases()
      assert.are.equal("tsx", vim.treesitter.language.get_lang("javascriptreact"))
    end)
    vim.treesitter.language.register(original, "javascriptreact")
    assert(ok, err)
  end)
end)
