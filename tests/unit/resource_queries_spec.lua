local resource_queries = require("i18n-status.resource_queries")
local resource_roots = require("i18n-status.resource_roots")
local helpers = require("tests.helpers")

local function write(path, content)
  helpers.write_file(path, content)
end

---@param root string
---@return I18nStatusResources
local function stub_resources(root)
  local cache = {
    languages = { "en", "ja" },
    namespaces = { "marketing", "translation" },
    index = {
      ja = {
        ["translation:title"] = {
          value = "タイトル",
          priority = 30,
        },
      },
    },
  }

  return {
    caches = {
      project = cache,
    },
    last_cache_key = "project",
    ensure_index = function()
      return {
        roots = {
          { kind = "next-intl", path = root .. "/messages" },
        },
        namespaces = cache.namespaces,
      }
    end,
    roots = function()
      return {
        { kind = "next-intl", path = root .. "/messages" },
      }
    end,
    start_dir = function()
      return root
    end,
  }
end

describe("resource queries", function()
  it("reads entries from the current cache", function()
    local queries = resource_queries.new(stub_resources("/tmp"), resource_roots)

    assert.are.same({ "en", "ja" }, queries.languages())
    assert.are.equal("タイトル", queries.get("ja", "translation:title").value)
  end)

  it("prefers next-intl root files for namespace paths", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en.json", '{"common":{"title":"Hello"}}')
    local queries = resource_queries.new(stub_resources(root), resource_roots)

    assert.are.equal(root .. "/messages/en.json", queries.namespace_path(root, "en", "common"))
  end)

  it("uses translation as the fallback namespace when ambiguous", function()
    local queries = resource_queries.new(stub_resources("/tmp"), resource_roots)
    local namespace, reason = queries.fallback_namespace("/tmp")

    assert.are.equal("translation", namespace)
    assert.are.equal("ambiguous", reason)
  end)

  it("prefixes root-file key paths for next-intl", function()
    local root = helpers.tmpdir()
    local queries = resource_queries.new(stub_resources(root), resource_roots)

    assert.are.equal(
      "common.login.title",
      queries.key_path_for_file("common", "login.title", root, "en", root .. "/messages/en.json")
    )
    assert.are.equal(
      "login.title",
      queries.key_path_for_file("common", "login.title", root, "en", root .. "/messages/en/common.json")
    )
  end)
end)
