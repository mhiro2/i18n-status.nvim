local resources = require("i18n-status.resources")
local helpers = require("tests.helpers")

local function write(path, content)
  helpers.write_file(path, content)
end

describe("resources", function()
  it("loads i18next resources", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local cache = resources.ensure_index(root)
    table.sort(cache.languages)
    assert.are.same({ "en", "ja" }, cache.languages)
    assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)
  end)

  it("loads next-intl with priority", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en/common.json", '{"title":"Common"}')
    write(root .. "/messages/en.json", '{"common":{"title":"Root"}}')
    local cache = resources.ensure_index(root)
    assert.are.equal("Root", cache.index.en["common:title"].value)
  end)

  it("handles invalid json", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", "{")
    local cache = resources.ensure_index(root)
    assert.is_not_nil(cache.index.ja["__error__"])
  end)

  it("reloads when file mtime changes", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"A"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"B"}}')
    local cache = resources.ensure_index(root)
    assert.are.equal("A", cache.index.ja["common:login.title"].value)

    -- Sleep to ensure mtime changes on filesystems with second-level precision
    vim.loop.sleep(1000)
    write(root .. "/locales/ja/common.json", '{"login":{"title":"C"}}')
    cache = resources.ensure_index(root)
    assert.are.equal("C", cache.index.ja["common:login.title"].value)
  end)

  it("prefers next-intl root files when available", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en.json", '{"common":{"title":"Root"}}')
    write(root .. "/messages/en/common.json", '{"title":"Namespaced"}')

    local path = resources.namespace_path(root, "en", "common")
    assert.are.equal(root .. "/messages/en.json", path)
  end)

  it("falls back to namespace files when root missing", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en/common.json", '{"title":"Namespaced"}')

    local path = resources.namespace_path(root, "en", "common")
    assert.are.equal(root .. "/messages/en/common.json", path)
  end)

  it("detects new files when watcher disabled", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key1":"value1"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.is_nil(cache.index.ja["new:key2"])

    write(root .. "/locales/ja/new.json", '{"key2":"value2"}')

    cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.are.equal("value2", cache.index.ja["new:key2"].value)
  end)

  it("detects deleted files when watcher disabled", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key1":"value1"}')
    write(root .. "/locales/ja/temp.json", '{"key2":"value2"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.are.equal("value2", cache.index.ja["temp:key2"].value)

    os.remove(root .. "/locales/ja/temp.json")

    cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.is_nil(cache.index.ja["temp:key2"])
  end)

  it("validates structure before checking file mtimes", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key":"value1"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key"].value)

    write(root .. "/locales/ja/new.json", '{"key2":"value2"}')

    cache = resources.ensure_index(root)
    assert.are.equal("value2", cache.index.ja["new:key2"].value)
  end)
end)
