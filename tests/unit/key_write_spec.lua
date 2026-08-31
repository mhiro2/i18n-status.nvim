local stub = require("luassert.stub")

local fs = require("i18n-status.fs")
local key_write = require("i18n-status.key_write")
local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")

describe("key_write", function()
  local stubs = {}
  local files
  local writes
  local missing_lang
  local fail_at_write_count
  local write_call_count
  local project_root
  local catalog_languages
  local ensure_index_opts
  local namespace_roots
  local raise_after_commit_count
  local rollback_raise_path
  local discard_raise_path
  local discard_calls
  local protected_paths

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
    catalog_languages = { "ja", "en" }
    ensure_index_opts = nil
    namespace_roots = nil
    raise_after_commit_count = nil
    rollback_raise_path = nil
    discard_raise_path = nil
    discard_calls = {}
    protected_paths = {}

    add_stub(resources, "namespace_path", function(_start_dir, lang, namespace, _framework, root_list)
      namespace_roots = root_list
      if missing_lang and lang == missing_lang then
        return nil
      end
      return string.format("/project/locales/%s/%s.json", lang, namespace)
    end)
    add_stub(resources, "ensure_index", function(_start_dir, opts)
      ensure_index_opts = opts
      return {
        roots = {
          { kind = "i18next", path = "/project/locales" },
        },
      }
    end)
    add_stub(resources, "project_root", function(_start_dir, _roots)
      return project_root
    end)
    add_stub(resource_catalog, "build", function(_start_dir, framework)
      return {
        errors = {},
        existing_keys = {},
        framework = framework,
        index = { ja = {}, en = {} },
        languages = vim.deepcopy(catalog_languages),
        namespaces = { "common" },
        root_kind = "i18next",
        roots = { { kind = "i18next", path = "/project/locales" } },
      },
        nil
    end)
    add_stub(fs, "sanitize_path", function(path, base_dir)
      if path == base_dir or path:sub(1, #base_dir + 1) == (base_dir .. "/") then
        return path, nil
      end
      return nil, "path is outside base directory"
    end)
    add_stub(fs, "ensure_dir_within", function()
      return true, nil
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
    add_stub(resources, "prepare_json_write", function(path, data)
      return {
        path = path,
        data = vim.deepcopy(data),
        original = vim.deepcopy(files[path]),
        atomic = { committed_ok = false },
      },
        nil
    end)
    add_stub(resources, "validate_json_write", function()
      return true, nil
    end)
    add_stub(resources, "commit_json_write", function(plan)
      write_call_count = write_call_count + 1
      if fail_at_write_count and write_call_count == fail_at_write_count then
        return false, "simulated failure"
      end
      files[plan.path] = vim.deepcopy(plan.data)
      plan.atomic.committed_ok = true
      plan.atomic.committed = { exists = true, content = "committed" }
      table.insert(writes, plan.path)
      if raise_after_commit_count and write_call_count == raise_after_commit_count then
        error("simulated commit exception")
      end
      return true, nil
    end)
    add_stub(resources, "rollback_json_write", function(plan)
      if rollback_raise_path == plan.path then
        error("simulated rollback exception")
      end
      files[plan.path] = vim.deepcopy(plan.original)
      plan.atomic.committed_ok = false
      plan.atomic.committed = nil
      return true, nil
    end)
    add_stub(resources, "discard_json_write", function(plan)
      discard_calls[#discard_calls + 1] = plan.path
      if discard_raise_path == plan.path then
        error("simulated discard exception")
      end
      return true, nil
    end)
    add_stub(resources, "protect_json_write", function(plan)
      protected_paths[#protected_paths + 1] = plan.path
      return true, nil
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

  it("uses exact roots throughout mutation planning", function()
    local success_count = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(2, success_count)
    assert.is_true(ensure_index_opts.exact)
    assert.are.same({ { kind = "i18next", path = "/project/locales" } }, namespace_roots)
  end)

  it("rolls back a locale when its commit raises after installation", function()
    raise_after_commit_count = 1

    local success_count, failed_langs, err = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(0, success_count)
    assert.are.same({ "ja", "en" }, failed_langs)
    assert.is_truthy(err:find("commit raised", 1, true))
    assert.are.same({ existing = "A" }, files["/project/locales/ja/common.json"])
    assert.are.same({ existing = "B" }, files["/project/locales/en/common.json"])
  end)

  it("continues rolling back earlier locales after one rollback raises", function()
    files["/project/locales/fr/common.json"] = { existing = "C" }
    fail_at_write_count = 3
    rollback_raise_path = "/project/locales/en/common.json"

    local success_count, _, err = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
      fr = "ajouté",
    }, "/project", { "ja", "en", "fr" })

    assert.are.equal(0, success_count)
    assert.is_truthy(err:find("rollback raised", 1, true))
    assert.are.same({ existing = "A" }, files["/project/locales/ja/common.json"])
    assert.are.equal("added", files["/project/locales/en/common.json"].new.key)
    assert.are.same({ existing = "C" }, files["/project/locales/fr/common.json"])
    assert.are.same({ "/project/locales/en/common.json" }, protected_paths)
  end)

  it("continues discarding other locales after one discard raises", function()
    discard_raise_path = "/project/locales/en/common.json"

    local success_count = key_write.write_translations("common", "new.key", {
      ja = "追加",
      en = "added",
    }, "/project", { "ja", "en" })

    assert.are.equal(2, success_count)
    assert.are.same({ "/project/locales/en/common.json", "/project/locales/ja/common.json" }, discard_calls)
  end)

  it("does not overwrite an exact key in create-only mode", function()
    local success_count, failed_langs, err = key_write.write_translations("common", "existing", {
      ja = "置換",
      en = "replacement",
    }, "/project", { "ja", "en" }, { create_only = true })

    assert.are.equal(0, success_count)
    assert.are.same({ "ja", "en" }, failed_langs)
    assert.is_truthy(err:find("target key already exists", 1, true))
    assert.are.equal("A", files["/project/locales/ja/common.json"].existing)
    assert.are.equal("B", files["/project/locales/en/common.json"].existing)
    assert.are.same({}, writes)
  end)

  it("does not replace an existing scalar ancestor", function()
    files["/project/locales/ja/common.json"] = { account = "既存" }
    files["/project/locales/en/common.json"] = { account = "existing" }

    local success_count, _, err = key_write.write_translations("common", "account.title", {
      ja = "題名",
      en = "title",
    }, "/project", { "ja", "en" })

    assert.are.equal(0, success_count)
    assert.is_truthy(err:find("existing ancestor", 1, true))
    assert.are.equal("既存", files["/project/locales/ja/common.json"].account)
    assert.are.equal("existing", files["/project/locales/en/common.json"].account)
  end)

  it("does not replace an existing branch even in overwrite mode", function()
    files["/project/locales/ja/common.json"] = { account = { title = "既存" } }
    files["/project/locales/en/common.json"] = { account = { title = "existing" } }

    local success_count, _, err = key_write.write_translations("common", "account", {
      ja = "置換",
      en = "replacement",
    }, "/project", { "ja", "en" }, { create_only = false })

    assert.are.equal(0, success_count)
    assert.is_truthy(err:find("existing descendants", 1, true))
    assert.are.same({ title = "既存" }, files["/project/locales/ja/common.json"].account)
    assert.are.same({ title = "existing" }, files["/project/locales/en/common.json"].account)
  end)

  it("rejects framework language changes before staging writes", function()
    catalog_languages = { "ja" }

    local success_count, failed_langs, err = key_write.write_translations(
      "common",
      "new.key",
      {
        ja = "追加",
        en = "added",
      },
      "/project",
      { "ja", "en" },
      {
        create_only = true,
        expected_languages = { "ja", "en" },
        framework = "i18next",
      }
    )

    assert.are.equal(0, success_count)
    assert.are.same({ "ja", "en" }, failed_langs)
    assert.is_truthy(err:find("resource languages changed", 1, true))
    assert.are.same({}, writes)
  end)
end)
