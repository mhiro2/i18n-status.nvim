local state = require("i18n-status.state")

describe("state lang cycle", function()
  local key = "__test__"

  local function current_lang()
    return state.project_for_key(key).current_lang
  end

  before_each(function()
    state.init("ja", {})
    state.set_languages(key, { "ja", "en", "fr" })
    state.set_current(key, "ja")
  end)

  it("cycles next", function()
    state.cycle_next(key)
    assert.are.equal("en", current_lang())
    state.cycle_next(key)
    assert.are.equal("fr", current_lang())
    state.cycle_next(key)
    assert.are.equal("ja", current_lang())
  end)

  it("cycles prev with history", function()
    state.cycle_next(key)
    assert.are.equal("en", current_lang())
    state.cycle_prev(key)
    assert.are.equal("ja", current_lang())
  end)

  it("handles single language", function()
    state.set_languages(key, { "ja" })
    state.cycle_next(key)
    assert.are.equal("ja", current_lang())
    state.cycle_prev(key)
    assert.are.equal("ja", current_lang())
  end)

  it("resets current language if removed", function()
    state.set_current(key, "en")
    state.set_languages(key, { "ja" })
    assert.are.equal("ja", current_lang())
  end)
end)
