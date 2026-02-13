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

describe("state project lookup", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("returns default project when no buffer key is assigned", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local project, key = state.project_for_buf(buf)
    assert.is_nil(key)
    assert.are.equal("ja", project.current_lang)
    assert.are.same({}, project.languages)
  end)

  it("binds project key and languages from cache", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local project, key = state.project_for_buf(buf, {
      key = "__cache__",
      languages = { "ja", "en" },
    })
    assert.are.equal("__cache__", key)
    assert.are.same({ "ja", "en" }, project.languages)
    assert.are.equal("__cache__", state.buf_project[buf])
  end)
end)
