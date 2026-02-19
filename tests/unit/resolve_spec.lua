local resolve = require("i18n-status.resolve")

---@param items table[]
---@param project table
---@param index table
---@return table[]
local function compute_async(items, project, index)
  local done = false
  local result = nil
  resolve.compute_async(items, project, index, function(resolved)
    result = resolved
    done = true
  end)
  local ok = vim.wait(5000, function()
    return done
  end)
  assert.is_true(ok, "resolve.compute_async timed out")
  return result or {}
end

describe("resolve", function()
  local project

  before_each(function()
    project = {
      primary_lang = "ja",
      current_lang = "ja",
      languages = { "ja", "en" },
    }
  end)

  it("marks ok when all languages match", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "Login" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("=", out[1].status)
  end)

  it("marks localized when values differ", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "ログイン" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("≠", out[1].status)
  end)

  it("marks fallback when missing in other lang", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "ログイン" } },
      en = {},
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("?", out[1].status)
  end)

  it("marks missing when primary missing", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = {},
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("×", out[1].status)
  end)

  it("treats empty string as missing", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("×", out[1].status)
  end)

  it("treats raw key as missing", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "login.title" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("×", out[1].status)
  end)

  it("treats key path as missing for explicit namespace", function()
    local items = { { key = "common:login.title", raw = "common:login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "login.title" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("×", out[1].status)
  end)

  it("marks placeholder mismatch", function()
    local items = { { key = "common:login.count", raw = "login.count" } }
    local index = {
      ja = { ["common:login.count"] = { value = "{count}件" } },
      en = { ["common:login.count"] = { value = "{name}" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("!", out[1].status)
  end)

  it("uses all languages for status when 3+ languages exist", function()
    project.languages = { "ja", "en", "fr" }
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "ログイン" } },
      en = { ["common:login.title"] = { value = "Login" } },
      fr = {},
    }
    local out = resolve.compute(items, project, index)
    -- Should be "?" because fr is missing (status considers all languages)
    assert.are.equal("?", out[1].status)
    assert.are.same({ "fr" }, out[1].hover.missing_langs)
    assert.are.same({ "en" }, out[1].hover.localized_langs)
  end)

  it("reports localized_langs and missing_langs correctly for all languages", function()
    project.languages = { "ja", "en", "fr", "de" }
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "ログイン" } },
      en = { ["common:login.title"] = { value = "Login" } },
      fr = { ["common:login.title"] = { value = "Connexion" } },
      de = {},
    }
    local out = resolve.compute(items, project, index)
    -- Should be "?" because de is missing
    assert.are.equal("?", out[1].status)
    assert.are.same({ "de" }, out[1].hover.missing_langs)
    -- en and fr differ from primary (ja)
    local localized_langs = out[1].hover.localized_langs
    assert.are.same(2, #localized_langs)
    assert.is_true(
      (localized_langs[1] == "en" and localized_langs[2] == "fr")
        or (localized_langs[1] == "fr" and localized_langs[2] == "en")
    )
  end)

  it("uses current language for display text", function()
    project.current_lang = "en"
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "ログイン" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = resolve.compute(items, project, index)
    assert.are.equal("Login", out[1].text)
  end)

  it("computes asynchronously", function()
    local items = { { key = "common:login.title", raw = "login.title" } }
    local index = {
      ja = { ["common:login.title"] = { value = "Login" } },
      en = { ["common:login.title"] = { value = "Login" } },
    }
    local out = compute_async(items, project, index)
    assert.are.equal("=", out[1].status)
  end)
end)
