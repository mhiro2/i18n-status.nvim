local treesitter = require("i18n-status.treesitter")

describe("treesitter", function()
  it("registers parser aliases without nvim-treesitter", function()
    treesitter.register_language_aliases()

    assert.are.equal("jsx", treesitter.parser_lang_for_filetype("javascriptreact"))
    assert.are.equal("tsx", treesitter.parser_lang_for_filetype("typescriptreact"))
    assert.are.equal("json", treesitter.parser_lang_for_filetype("jsonc"))
  end)
end)
