local key_spelling = require("i18n-status.key_spelling")

describe("key_spelling", function()
  describe("translation_arg_at", function()
    it("reports the quote of any open string", function()
      assert.are.equal("`", key_spelling.open_quote_at("const a = `x"))
      assert.is_nil(key_spelling.open_quote_at('const a = "x"'))
      assert.is_nil(key_spelling.open_quote_at('// "x'))
    end)

    it("reports the opening quote of the first string argument", function()
      assert.are.same(
        { prefix = "home.ti", quote = "'", quote_col = 8, member_call = true },
        key_spelling.translation_arg_at("i18n.t( 'home.ti")
      )
    end)

    it("ignores closed arguments and other calls", function()
      assert.is_nil(key_spelling.translation_arg_at('t("a") + "'))
      assert.is_nil(key_spelling.translation_arg_at('axios.get("'))
    end)
  end)

  describe("for_context", function()
    it("binds next-intl spellings to the translator namespace", function()
      assert.are.same(
        { framework = "next_intl", namespace = "Home.Form" },
        key_spelling.for_context({
          found_hook = true,
          framework = "next_intl",
          source_key_policy = "namespace_relative",
          namespace = "Home.Form",
        }, nil)
      )
      assert.are.same(
        { framework = "next_intl" },
        key_spelling.for_context(
          { found_hook = true, framework = "next_intl", source_key_policy = "canonical", namespace = "x" },
          nil
        )
      )
    end)

    it("rejects next-intl translators with a dynamic namespace", function()
      local spelling, err =
        key_spelling.for_context({ found_hook = true, framework = "next_intl", namespace = "translation" }, nil)
      assert.is_nil(spelling)
      assert.is_truthy(err:find("statically", 1, true))
    end)

    it("rejects translators whose namespace or key options are opaque", function()
      for _, context in ipairs({
        { found_hook = true, framework = "i18next", namespace = "x", namespace_resolution = "dynamic" },
        { found_hook = true, hook = "useTranslation", framework = "i18next", namespace = "x", extract_safe = false },
      }) do
        local spelling, err = key_spelling.for_context(context, nil)
        assert.is_nil(spelling)
        assert.is_truthy(err:find("statically", 1, true))
      end
    end)

    it("uses the fallback namespace without a translator binding", function()
      local spelling = key_spelling.for_context({ found_hook = false, namespace = "ignored" }, "common")
      assert.are.equal("title", key_spelling.source_key(spelling, "common:title"))
    end)
  end)

  describe("for_item", function()
    it("follows the translator that owns a scanned call", function()
      assert.are.same(
        { framework = "next_intl", namespace = "Home.Form" },
        key_spelling.for_item({
          framework = "next_intl",
          source_key_policy = "namespace_relative",
          translator_namespace = "Home.Form",
        }, "common")
      )
      assert.are.same({ namespace = "auth" }, key_spelling.for_item({ translator_namespace = "auth" }, "common"))
      assert.are.same({ namespace = "common" }, key_spelling.for_item({ fallback = true }, "common"))
      assert.is_nil((key_spelling.for_item({ opaque_binding = true, translator_namespace = "auth" }, nil)))
    end)
  end)

  describe("source_key", function()
    it("rejects or qualifies keys of other i18next namespaces", function()
      local spelling = { namespace = "auth" }
      local key, err = key_spelling.source_key(spelling, "common:save")
      assert.is_nil(key)
      assert.are.equal("key 'common:save' is outside namespace 'auth'", err)
      assert.are.equal(
        "common:save",
        key_spelling.source_key(spelling, "common:save", { qualify_other_namespaces = true })
      )
    end)

    it("keeps explicit namespaces", function()
      assert.are.equal(
        "auth:login",
        key_spelling.source_key({ namespace = "auth", explicit_namespace = true }, "auth:login")
      )
    end)
  end)

  it("spells root keys as full message paths for next-intl", function()
    assert.are.equal("Home.Form.title", key_spelling.root_key("Home:Form.title", "next_intl"))
    assert.are.equal("common:title", key_spelling.root_key("common:title", "i18next"))
  end)
end)
