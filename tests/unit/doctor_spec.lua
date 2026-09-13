local doctor = require("i18n-status.doctor")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")
local stub = require("luassert.stub")

local function diagnose(bufnr, config)
  local done = false
  local result = nil
  local context = nil
  doctor.diagnose(bufnr, config, function(issues, _, ctx)
    result = issues
    context = ctx
    done = true
  end)
  local ok = vim.wait(5000, function()
    return done
  end)
  assert.is_true(ok, "doctor.diagnose timed out")
  return result, context
end

local function init_git_repo()
  if vim.fn.executable("git") == 0 then
    return nil
  end
  local root = helpers.tmpdir()
  vim.fn.system({ "git", "-C", root, "init" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return root
end

local function write_i18next(root, lang, namespace, json)
  helpers.write_file(root .. "/frontend/public/locales/" .. lang .. "/" .. namespace .. ".json", json)
end

describe("doctor", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("reports missing and unused keys", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"},"unused":"x"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"},"unused":"x"}')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")', 't("missing.key")' })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
      })

      local issues = diagnose(buf, config)
      local counts = { missing = 0, unused = 0 }
      for _, issue in ipairs(issues) do
        if issue.kind == "missing" then
          counts.missing = counts.missing + 1
        elseif issue.kind == "unused" then
          counts.unused = counts.unused + 1
        end
      end
      assert.is_true(counts.missing >= 1)
      assert.is_true(counts.unused >= 1)
    end)
  end)

  it("reports missing resource root", function()
    local root = helpers.tmpdir()
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
      })

      local issues = diagnose(buf, config)
      local found = false
      for _, issue in ipairs(issues) do
        if issue.kind == "resource_root_missing" then
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)

  it("delegates project root resolution to resources.project_root", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.write_file(root .. "/src/app.ts", 't("login.title")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/src/app.ts")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local config = config_mod.setup({ primary_lang = "ja" })
      local called = nil
      local project_root_stub = stub(resources, "project_root", function(start_dir, roots)
        called = { start_dir = start_dir, roots = roots }
        return start_dir
      end)

      local ok, issues_or_err = pcall(function()
        return diagnose(buf, config)
      end)

      project_root_stub:revert()

      assert.is_true(ok, issues_or_err)
      assert.is_true(type(issues_or_err) == "table")
      assert.is_not_nil(called)
      local expected_start_dir = vim.uv.fs_realpath(root .. "/src") or (root .. "/src")
      assert.are.equal(expected_start_dir, called.start_dir)
      assert.is_true(type(called.roots) == "table")
    end)
  end)

  it("reports drift and respects ignore keys", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":"A","missing_in_en":"M","ignore":"X"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a":"A","extra":"Y"}')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("a")' })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
        doctor = { ignore_keys = { "^common:ignore$" } },
      })

      local issues, ctx = diagnose(buf, config)
      local drift_extra = false
      local drift_missing = false
      local ignored_seen = false
      for _, issue in ipairs(issues) do
        if issue.kind == "drift_extra" and issue.key == "common:extra" then
          drift_extra = true
        end
        if issue.kind == "drift_missing" and issue.key == "common:missing_in_en" then
          drift_missing = true
        end
        if issue.key == "common:ignore" then
          ignored_seen = true
        end
      end
      assert.is_true(drift_extra)
      assert.is_true(drift_missing)
      assert.is_false(ignored_seen)
      assert.are.same({ "en", "ja" }, ctx.cache.languages)
      assert.are.same({ "common" }, ctx.cache.namespaces)
      assert.is_false(ctx.cache.dirty)
    end)
  end)

  it("does not crash on invalid ignore key pattern", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":"A"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a":"A","extra":"Y"}')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("a")' })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
        doctor = { ignore_keys = { "[" } },
      })

      local issues = diagnose(buf, config)
      assert.is_true(type(issues) == "table")
      assert.is_true(#issues > 0)
    end)
  end)

  it("uses literal substring ignore semantics with ^/$ anchors", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a.b":"A"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a.b":"A","axb":"B"}')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("a.b")' })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
        doctor = { ignore_keys = { "a.b" } },
      })

      local issues = diagnose(buf, config)
      local saw_ignored = false
      local saw_axb = false
      for _, issue in ipairs(issues) do
        if issue.key == "common:a.b" then
          saw_ignored = true
        end
        if issue.kind == "drift_extra" and issue.key == "common:axb" then
          saw_axb = true
        end
      end
      assert.is_false(saw_ignored)
      assert.is_true(saw_axb)
    end)
  end)

  it("scans project files, not just open buffers", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"used":"使用中","unused":"未使用"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"used":"Used","unused":"Unused"}')
    -- Create a file that uses a key but is NOT open as a buffer
    helpers.write_file(root .. "/src/foo.ts", 't("common:used")')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "// This buffer does not use any keys" })
      vim.bo[buf].filetype = "typescript"
      local config = config_mod.setup({
        primary_lang = "ja",
      })

      local issues = diagnose(buf, config)
      local unused_used = false
      local unused_unused = false
      for _, issue in ipairs(issues) do
        if issue.kind == "unused" then
          if issue.key == "common:used" then
            unused_used = true
          elseif issue.key == "common:unused" then
            unused_unused = true
          end
        end
      end
      -- common:used should NOT be reported as unused (it's used in src/foo.ts)
      assert.is_false(unused_used, "common:used should not be unused")
      -- common:unused SHOULD be reported as unused
      assert.is_true(unused_unused, "common:unused should be unused")
    end)
  end)

  it("does not allocate anonymous buffers when scanning project files", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"used":"使用中"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"used":"Used"}')
    helpers.write_file(root .. "/src/app.tsx", 't("common:used")')
    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/src/app.tsx")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("common:used")' })
      vim.bo[buf].filetype = "typescriptreact"

      local config = config_mod.setup({
        primary_lang = "ja",
      })

      local original_create_buf = vim.api.nvim_create_buf
      vim.api.nvim_create_buf = function()
        error("doctor should not allocate extra buffers")
      end

      local ok, err = pcall(function()
        diagnose(buf, config)
      end)

      vim.api.nvim_create_buf = original_create_buf

      assert.is_true(ok, err)
    end)
  end)

  it("scans project files via git from repo root when in subdir", function()
    local root = init_git_repo()
    if not root then
      return
    end
    write_i18next(root, "ja", "translation", '{"alpha":"A","beta":{"gamma":"B"},"unused":"x"}')
    write_i18next(root, "en", "translation", '{"alpha":"A","beta":{"gamma":"B"},"unused":"x"}')
    helpers.write_file(root .. "/frontend/src/app/a.ts", 't("alpha")')
    helpers.write_file(root .. "/frontend/src/app/b.ts", 't("beta.gamma")')

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/frontend/src/app/a.ts")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("alpha")' })
    vim.bo[buf].filetype = "typescript"

    local config = config_mod.setup({
      primary_lang = "ja",
    })
    local issues = diagnose(buf, config)
    local unused = {}
    for _, issue in ipairs(issues) do
      if issue.kind == "unused" then
        unused[issue.key] = true
      end
    end

    assert.is_nil(unused["translation:alpha"], "translation:alpha should not be unused")
    assert.is_nil(unused["translation:beta.gamma"], "translation:beta.gamma should not be unused")
    assert.is_true(unused["translation:unused"], "translation:unused should be unused")
  end)

  it("resolves namespace from useTranslation()", function()
    local root = init_git_repo()
    if not root then
      return
    end
    write_i18next(root, "ja", "core", '{"alpha":"A"}')
    write_i18next(root, "en", "core", '{"alpha":"A"}')
    write_i18next(root, "ja", "feature", '{"item":{"label":"X"}}')
    write_i18next(root, "en", "feature", '{"item":{"label":"X"}}')

    helpers.write_file(
      root .. "/frontend/src/app/feature.tsx",
      [[
      const { t } = useTranslation("feature")
      t("item.label")
    ]]
    )

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/frontend/src/app/empty.tsx")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "// no keys here" })
    vim.bo[buf].filetype = "typescriptreact"

    local config = config_mod.setup({ primary_lang = "ja" })
    local issues = diagnose(buf, config)
    local unused = {}
    for _, issue in ipairs(issues) do
      if issue.kind == "unused" then
        unused[issue.key] = true
      end
    end

    assert.is_nil(unused["feature:item.label"], "feature:item.label should not be unused")
  end)

  it("uses fallback namespace when useTranslation() has no args", function()
    local root = init_git_repo()
    if not root then
      return
    end
    write_i18next(root, "ja", "translation", '{"alpha":"A","unused":"x"}')
    write_i18next(root, "en", "translation", '{"alpha":"A","unused":"x"}')

    helpers.write_file(
      root .. "/frontend/src/app/page.ts",
      [[
      useTranslation()
      t("alpha")
    ]]
    )

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/frontend/src/app/empty.ts")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "// no keys here" })
    vim.bo[buf].filetype = "typescript"

    local config = config_mod.setup({ primary_lang = "ja" })
    local issues = diagnose(buf, config)
    local unused = {}
    for _, issue in ipairs(issues) do
      if issue.kind == "unused" then
        unused[issue.key] = true
      end
    end

    assert.is_nil(unused["translation:alpha"], "translation:alpha should not be unused")
    assert.is_true(unused["translation:unused"], "translation:unused should be unused")
  end)

  it("uses the sole non-common namespace on a cold cache", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/auth.json", '{"login":"ログイン"}')
    helpers.write_file(root .. "/locales/en/auth.json", '{"login":"Login"}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/page.ts")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login")' })
      vim.bo[buf].filetype = "typescript"

      local issues, ctx = diagnose(buf, config_mod.setup({ primary_lang = "ja" }))
      for _, issue in ipairs(issues) do
        assert.is_false(
          issue.kind == "missing" and issue.key == "common:login",
          "the worker must not keep the cold-cache common fallback"
        )
        assert.is_false(
          issue.kind == "unused" and issue.key == "auth:login",
          "the sole namespace key should be recognized as used"
        )
      end
      assert.are.equal("auth", ctx.fallback_ns)
      assert.are.same({ "auth" }, ctx.cache.namespaces)
    end)
  end)

  it("keeps explicit namespace keys", function()
    local root = init_git_repo()
    if not root then
      return
    end
    write_i18next(root, "ja", "feature", '{"alpha":{"beta":"B"}}')
    write_i18next(root, "en", "feature", '{"alpha":{"beta":"B"}}')

    helpers.write_file(root .. "/frontend/src/app/a.ts", 't("feature:alpha.beta")')

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/frontend/src/app/empty.ts")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "// no keys here" })
    vim.bo[buf].filetype = "typescript"

    local config = config_mod.setup({ primary_lang = "ja" })
    local issues = diagnose(buf, config)
    local unused = {}
    for _, issue in ipairs(issues) do
      if issue.kind == "unused" then
        unused[issue.key] = true
      end
    end

    assert.is_nil(unused["feature:alpha.beta"], "feature:alpha.beta should not be unused")
  end)

  it("scans tsx files for project usage", function()
    local root = init_git_repo()
    if not root then
      return
    end
    write_i18next(root, "ja", "feature", '{"alpha":{"beta":"B"}}')
    write_i18next(root, "en", "feature", '{"alpha":{"beta":"B"}}')

    helpers.write_file(root .. "/frontend/src/app/feature.tsx", 'const label = t("feature:alpha.beta")')

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/frontend/src/app/empty.tsx")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "// no keys here" })
    vim.bo[buf].filetype = "typescriptreact"

    local config = config_mod.setup({ primary_lang = "ja" })
    local issues = diagnose(buf, config)
    local unused = {}
    for _, issue in ipairs(issues) do
      if issue.kind == "unused" then
        unused[issue.key] = true
      end
    end

    assert.is_nil(unused["feature:alpha.beta"], "feature:alpha.beta should not be unused")
  end)

  it("keeps interactive RPC responsive while Doctor resource IO is blocked", function()
    if vim.fn.executable("mkfifo") == 0 or vim.fn.executable("sh") == 0 then
      return
    end

    local root = helpers.tmpdir()
    local locale_dir = root .. "/locales/ja"
    vim.fn.mkdir(locale_dir, "p")
    local fifo = locale_dir .. "/blocked.json"
    vim.fn.system({ "mkfifo", fifo })
    assert.are.equal(0, vim.v.shell_error)

    local rpc = require("i18n-status.rpc")
    local ready, ready_error = rpc.ensure_ready()
    assert.is_true(ready, ready_error)
    local doctor_done = false
    local doctor_error = nil
    local scan_result = nil
    local scan_error = nil

    rpc.request("doctor/diagnose", {
      project_root = root,
      roots = { { kind = "i18next", path = root .. "/locales" } },
      primary_lang = "ja",
      languages = {},
      fallback_namespace = "common",
      ignore_patterns = {},
      open_buf_paths = {},
      open_buffers = {},
      deadline_ms = 1000,
    }, function(err)
      doctor_error = err
      doctor_done = true
    end, { timeout_ms = 2000 })

    local started_at = vim.uv.hrtime()
    rpc.request("scan/extract", {
      source = 't("ready")',
      lang = "typescript",
      fallback_namespace = "common",
    }, function(err, result)
      scan_error = err
      scan_result = result
    end)

    local interactive_done = vim.wait(500, function()
      return scan_result ~= nil
    end, 5)
    local interactive_elapsed_ms = (vim.uv.hrtime() - started_at) / 1000000
    local interactive_preceded_doctor = not doctor_done

    local writer_done = false
    vim.system({ "sh", "-c", 'printf "{}" > "$1"', "sh", fifo }, {}, function()
      writer_done = true
    end)
    assert.is_true(vim.wait(2000, function()
      return writer_done and doctor_done
    end, 5))

    assert.is_true(interactive_done, "interactive RPC was blocked behind Doctor")
    assert.is_true(interactive_elapsed_ms < 500, "interactive RPC exceeded its latency budget")
    assert.is_true(interactive_preceded_doctor, "Doctor completed before the isolation assertion")
    assert.is_nil(scan_error)
    assert.are.equal("common:ready", scan_result.items[1].key)
    assert.is_nil(doctor_error)
  end)
end)
