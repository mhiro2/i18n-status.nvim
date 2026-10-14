local message_escape = require("i18n-status.message_escape")

describe("message_escape", function()
  -- Expected values were checked against intl-messageformat, which next-intl uses to format messages.
  local icu_cases = {
    { "Hello {name}", "Hello '{'name'}'" },
    { "it's fine", "it's fine" },
    { "'quoted'", "'quoted'" },
    { "{'}", "'{''}'" },
    { "a'{b}'", "a'''{'b'}'''" },
    { "don''t", "don''''t" },
    { "a < b > c", "a '<' b '>' c" },
    { "<b>bold</b>", "'<'b'>'bold'<'/b'>'" },
  }

  for _, case in ipairs(icu_cases) do
    it("quotes ICU syntax in " .. vim.inspect(case[1]), function()
      assert.are.equal(case[2], message_escape.literal_message("next_intl", case[1]))
    end)
  end

  it("keeps i18next text without interpolation markers", function()
    assert.are.equal("Hello {name}", message_escape.literal_message("i18next", "Hello {name}"))
  end)

  it("rejects i18next text with interpolation or nesting markers", function()
    local message, err = message_escape.literal_message("i18next", "Hello {{name}}")
    assert.is_nil(message)
    assert.is_truthy(err)
    assert.is_nil((message_escape.literal_message("i18next", "see $t(other)")))
  end)
end)
