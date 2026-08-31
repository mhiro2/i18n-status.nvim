local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")

local function with_override(target, key, replacement, callback)
  local original = target[key]
  target[key] = replacement
  local result = { xpcall(callback, debug.traceback) }
  target[key] = original
  if not result[1] then
    error(result[2])
  end
  return unpack(result, 2)
end

describe("resource catalog", function()
  it("resolves an exact cache when the caller does not provide one", function()
    local requested_opts
    with_override(resources, "ensure_index", function(_start_dir, opts)
      requested_opts = opts
      return {
        roots = { { kind = "i18next", path = "/project/locales" } },
      }
    end, function()
      with_override(resources, "build_index", function()
        return {
          errors = {},
          index = { en = {} },
          languages = { "en" },
          namespaces = { "common" },
        }
      end, function()
        local catalog, err = resource_catalog.build("/project", "i18next")

        assert.is_nil(err)
        assert.is_not_nil(catalog)
        assert.is_true(requested_opts.exact)
      end)
    end)
  end)

  it("fails closed when one framework has multiple resource roots", function()
    local build_calls = 0
    with_override(resources, "build_index", function()
      build_calls = build_calls + 1
      return {}
    end, function()
      local catalog, err = resource_catalog.build("/project/src", "i18next", {
        roots = {
          { kind = "i18next", path = "/project/locales" },
          { kind = "i18next", path = "/project/public/locales" },
          { kind = "next-intl", path = "/project/messages" },
        },
      })

      assert.is_nil(catalog)
      assert.are.equal("multiple i18next resource roots are ambiguous", err)
      assert.are.equal(0, build_calls)
    end)
  end)

  it("treats next-intl root spellings as the same framework", function()
    local catalog, err = resource_catalog.build("/project/src", "next_intl", {
      roots = {
        { kind = "next-intl", path = "/project/messages" },
        { kind = "next_intl", path = "/project/legacy-messages" },
      },
    })

    assert.is_nil(catalog)
    assert.are.equal("multiple next-intl resource roots are ambiguous", err)
  end)

  it("builds an isolated index for the requested framework", function()
    local requested_roots
    with_override(resources, "build_index", function(roots)
      requested_roots = vim.deepcopy(roots)
      return {
        errors = {},
        index = {
          ja = { ["common:title"] = { value = "JA", priority = 20 } },
          en = { ["common:title"] = { value = "EN", priority = 20 } },
        },
        languages = { "ja", "en" },
        namespaces = { "translation", "common" },
      }
    end, function()
      local catalog, err = resource_catalog.build("/project/src", "next_intl", {
        roots = {
          { kind = "i18next", path = "/project/locales" },
          { kind = "next-intl", path = "/project/messages" },
        },
      })

      assert.is_nil(err)
      assert.are.same({ { kind = "next-intl", path = "/project/messages" } }, requested_roots)
      assert.are.same({ "en", "ja" }, catalog.languages)
      assert.are.same({ "common", "translation" }, catalog.namespaces)
      assert.is_true(catalog.existing_keys["common:title"])
    end)
  end)

  it("detects exact, ancestor, and descendant target conflicts", function()
    local cases = {
      { entries = { ["common:account.title"] = {} }, target = "common:account.title" },
      { entries = { ["common:account"] = {} }, target = "common:account.title" },
      { entries = { ["common:account.title.long"] = {} }, target = "common:account.title" },
    }

    for _, case in ipairs(cases) do
      assert.is_true(resource_catalog.entries_conflict(case.entries, case.target, nil))
    end
    assert.is_false(resource_catalog.entries_conflict({ ["common:accounts"] = {} }, "common:account", nil))
  end)

  it("reports conflicts only in the languages being written", function()
    local catalog = {
      index = {
        en = { ["common:account"] = {} },
        ja = { ["common:other"] = {} },
      },
      languages = { "en", "ja" },
    }

    assert.are.equal("en", resource_catalog.target_conflict(catalog, "common:account.title"))
    assert.is_nil(resource_catalog.target_conflict(catalog, "common:account.title", { "ja" }))
  end)

  it("compares language sets independent of order", function()
    assert.is_true(resource_catalog.same_languages({ "ja", "en" }, { "en", "ja" }))
    assert.is_false(resource_catalog.same_languages({ "en", "ja" }, { "en" }))
    assert.is_false(resource_catalog.same_languages({ "en", "en" }, { "en" }))
  end)
end)
