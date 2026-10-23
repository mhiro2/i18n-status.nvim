local extract_candidate = require("i18n-status.extract_candidate")

describe("extract candidate replacement", function()
  it("wraps a JSX child replacement in braces", function()
    local replacement, err = extract_candidate.replacement({
      t_func = "t",
      proposed_key = "common:hello",
      source_key_policy = "canonical",
      replacement_context = "jsx_child",
    })

    assert.is_nil(err)
    assert.are.equal('{t("common:hello")}', replacement)
  end)

  it("does not add braces inside an existing JSX expression", function()
    local replacement, err = extract_candidate.replacement({
      t_func = "t",
      proposed_key = "common:hello",
      source_key_policy = "canonical",
      replacement_context = "jsx_expression",
    })

    assert.is_nil(err)
    assert.are.equal('t("common:hello")', replacement)
  end)

  it("uses a namespace-relative key for a scoped next-intl translator", function()
    local replacement, err = extract_candidate.replacement({
      namespace = "Home",
      framework = "next_intl",
      t_func = "t",
      proposed_key = "Home:greeting",
      source_key_policy = "namespace_relative",
      replacement_context = "jsx_child",
    })

    assert.is_nil(err)
    assert.are.equal('{t("greeting")}', replacement)
  end)

  it("keeps the translation function name and multibyte keys intact", function()
    local replacement, err = extract_candidate.replacement({
      t_func = "tr",
      proposed_key = "common:日本語",
      source_key_policy = "canonical",
      replacement_context = "jsx_child",
    })

    assert.is_nil(err)
    assert.are.equal('{tr("common:日本語")}', replacement)
  end)

  it("rejects namespace-relative keys outside next-intl", function()
    local replacement, err = extract_candidate.replacement({
      namespace = "common",
      framework = "i18next",
      t_func = "t",
      proposed_key = "common:hello",
      source_key_policy = "namespace_relative",
      replacement_context = "jsx_child",
    })

    assert.is_nil(replacement)
    assert.are.equal("namespace-relative source keys are only supported for next-intl", err)
  end)
end)
