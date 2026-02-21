local stub = require("luassert.stub")

local key_write = require("i18n-status.key_write")
local resources = require("i18n-status.resources")
local util = require("i18n-status.util")

describe("key_write", function()
  local stubs = {}
  local files
  local writes
  local missing_lang
  local fail_at_write_count
  local write_call_count
  local project_root

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    table.insert(stubs, s)
    return s
  end

  before_each(function()
    files = {
      ["/project/locales/ja/common.json"] = { existing = "A" },
      ["/project/locales/en/common.json"] = { existing = "B" },
    }
    writes = {}
    missing_lang = nil
    fail_at_write_count = nil
    write_call_count = 0
    project_root = "/project"

    add_stub(resources, "namespace_path", function(_start_dir, lang, namespace)
      if missing_lang and lang == missing_lang then
        return nil
      end
      return string.format("/project/locales/%s/%s.json", lang, namespace)
    end)
    add_stub(resources, "ensure_index", function()
      return {
        roots = {
          { kind = "i18next", path = "/project/locales" },
        },
      }
    end)
    add_stub(resources, "project_root", function(_start_dir, _roots)
      return project_root
    end)
    add_stub(util, "sanitize_path", function(path, base_dir)
      if path == base_dir or path:sub(1, #base_dir + 1) == (base_dir .. "/") then
        return path, nil
      end
      return nil, "path is outside base directory"
    end)
    add_stub(util, "ensure_dir", function()
      return true
    end)
    add_stub(resources, "read_json_table", function(path)
      local data = files[path]
      if not data then
        return nil, { error = "not found" }
      end
      return vim.deepcopy(data), { indent = "  " }
    end)
    add_stub(resources, "key_path_for_file", function(_namespace, key_path)
      return key_path
    end)
    add_stub(resources, "write_json_table", function(path, data)
      write_call_count = write_call_count + 1
      if fail_at_write_count and write_call_count == fail_at_write_count then
        return false, "simulated failure"
      end
      files[path] = vim.deepcopy(data)
      table.insert(writes, path)
      return true
    end)
  end)

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}
  end)

  it("writes translations to all languages when all writes succeed", function()
    local success_count, failed_langs = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(2, success_count)
    assert.are.same({}, failed_langs)
    assert.are.same({ "/project/locales/ja/common.json", "/project/locales/en/common.json" }, writes)
    assert.are.equal("追加", files["/project/locales/ja/common.json"].new.key)
    assert.are.equal("added", files["/project/locales/en/common.json"].new.key)
  end)

  it("does not commit any file when one language fails before commit", function()
    missing_lang = "en"

    local success_count, failed_langs = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(0, success_count)
    assert.are.same({ "en" }, failed_langs)
    assert.are.same({}, writes)
    assert.is_nil(files["/project/locales/ja/common.json"].new)
  end)

  it("rolls back already committed files when commit fails", function()
    fail_at_write_count = 2

    local success_count, failed_langs = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(0, success_count)
    assert.are.same({ "ja", "en" }, failed_langs)
    assert.is_nil(files["/project/locales/ja/common.json"].new)
    assert.is_nil(files["/project/locales/en/common.json"].new)
    assert.are.equal("A", files["/project/locales/ja/common.json"].existing)
    assert.are.equal("B", files["/project/locales/en/common.json"].existing)
  end)

  it("uses project root as sanitize base even when start_dir is nested", function()
    local success_count, failed_langs = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project/src/components", { "ja", "en" })

    assert.are.equal(2, success_count)
    assert.are.same({}, failed_langs)
    assert.are.equal("追加", files["/project/locales/ja/common.json"].new.key)
    assert.are.equal("added", files["/project/locales/en/common.json"].new.key)
  end)
end)
