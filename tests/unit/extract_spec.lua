local stub = require("luassert.stub")

local config_mod = require("i18n-status.config")
local extract = require("i18n-status.extract")
local extract_review = require("i18n-status.extract_review")
local hardcoded = require("i18n-status.hardcoded")
local project_identity = require("i18n-status.project_identity")
local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")

local function make_buf(lines, ft, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

describe("extract orchestrator", function()
  local stubs = {}
  local notify_calls
  local original_notify

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    stubs[#stubs + 1] = s
    return s
  end

  before_each(function()
    notify_calls = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
    add_stub(project_identity, "resolve", function(bufnr)
      local start_dir = resources.start_dir(bufnr)
      local cache = resources.ensure_index(start_dir)
      cache.key = cache.key or "/tmp/project\0i18next"
      cache.roots = cache.roots or {
        { kind = "i18next", path = "/tmp/project/locales" },
      }
      return {
        cache = cache,
        cache_key = cache.key,
        filetype = vim.bo[bufnr].filetype,
        name = vim.api.nvim_buf_get_name(bufnr),
        root = "/tmp/project",
        start_dir = start_dir,
      },
        nil
    end)
    add_stub(project_identity, "validate", function(_bufnr, identity)
      return identity, nil
    end)
    add_stub(resource_catalog, "build", function(_start_dir, framework, cache)
      if framework ~= "i18next" then
        return nil, "no next-intl resource root detected"
      end
      return {
        errors = {},
        existing_keys = resource_catalog.collect_existing_keys(cache),
        framework = framework,
        index = cache.index or {},
        languages = vim.deepcopy(cache.languages or {}),
        namespaces = { "common" },
        root_kind = "i18next",
        roots = vim.deepcopy(cache.roots or {}),
      },
        nil
    end)
  end)

  after_each(function()
    vim.notify = original_notify
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}
  end)

  it("opens extract review with generated candidates", function()
    local buf = make_buf({ "Hello", "New value" }, "typescriptreact", "/tmp/project/src/page.tsx")
    local hardcoded_opts
    local open_opts

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        languages = { "ja", "en" },
        index = {
          ja = {
            ["common:hello"] = { value = "Hello" },
          },
          en = {},
        },
      }
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function(_bufnr, opts)
      hardcoded_opts = opts
      return {
        {
          lnum = 0,
          col = 0,
          end_lnum = 0,
          end_col = 5,
          text = "Hello",
          source_text = "Hello",
          kind = "jsx_text",
          replacement_context = "jsx_child",
        },
        {
          lnum = 1,
          col = 0,
          end_lnum = 1,
          end_col = 9,
          text = "New value",
          source_text = "New value",
          kind = "jsx_text",
          replacement_context = "jsx_child",
        },
      },
        nil
    end)
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = "t",
        binding_id = "t@42",
        hook = "useTranslation",
        framework = "i18next",
        source_key_policy = "canonical",
        namespace_resolution = "static",
        extract_safe = true,
        ambiguous = false,
        found_hook = true,
        has_any_hook = true,
      }
    end)
    add_stub(extract_review, "open", function(opts)
      open_opts = opts
      return { list_buf = 10 }
    end)

    local cfg = config_mod.setup({ primary_lang = "ja" })
    local result = extract.run(buf, cfg, {
      range = { start_line = 0, end_line = 1 },
    })

    assert.are.equal(10, result.list_buf)
    assert.are.equal(0, hardcoded_opts.range.start_line)
    assert.are.equal(1, hardcoded_opts.range.end_line)

    assert.are.equal(2, #open_opts.candidates)
    assert.are.equal("common:hello", open_opts.candidates[1].proposed_key)
    assert.are.equal("conflict_existing", open_opts.candidates[1].status)
    assert.are.equal("Hello", open_opts.candidates[1].source_text)
    assert.are.equal("jsx_child", open_opts.candidates[1].replacement_context)
    assert.are.equal("t@42", open_opts.candidates[1].binding_id)
    assert.are.equal("useTranslation", open_opts.candidates[1].hook)
    assert.are.equal("canonical", open_opts.candidates[1].source_key_policy)
    assert.is_false(open_opts.candidates[1].selected)
    assert.are.equal("common:new-value", open_opts.candidates[2].proposed_key)
    assert.are.equal("ready", open_opts.candidates[2].status)
    assert.is_false(open_opts.candidates[2].selected)
  end)

  it("passes byte position and blocks ambiguous translation contexts", function()
    local received_opts = nil
    add_stub(scan, "translation_context_at", function(_bufnr, _row, opts)
      received_opts = opts
      return {
        namespace = "common",
        t_func = "t",
        found_hook = false,
        has_any_hook = true,
        ambiguous = true,
        shadowed = false,
      }
    end)

    local candidates, rejected = extract._test.build_candidates(1, {
      {
        lnum = 2,
        col = 17,
        end_lnum = 2,
        end_col = 22,
        text = "Hello",
      },
    }, "common", { key_separator = "-" }, {})

    assert.are.equal(17, received_opts.col)
    assert.are.equal(0, #candidates)
    assert.are.equal(1, rejected)
  end)

  it("notifies when hardcoded scan fails", function()
    local buf = make_buf({ "Hello" }, "typescriptreact", "/tmp/project/src/page_err.tsx")

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        languages = { "ja", "en" },
        index = { ja = {}, en = {} },
      }
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function()
      return {}, "timeout"
    end)

    local cfg = config_mod.setup({ primary_lang = "ja" })
    local result = extract.run(buf, cfg, {})

    assert.is_nil(result)
    assert.is_true(notify_calls[1].msg:find("failed to scan hardcoded text", 1, true) ~= nil)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("notifies when no hardcoded text is found", function()
    local buf = make_buf({ "Hello" }, "typescriptreact", "/tmp/project/src/page_none.tsx")

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        languages = { "ja", "en" },
        index = { ja = {}, en = {} },
      }
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function()
      return {}, nil
    end)

    local cfg = config_mod.setup({ primary_lang = "ja" })
    local result = extract.run(buf, cfg, {})

    assert.is_nil(result)
    assert.is_true(notify_calls[1].msg:find("no hardcoded text found", 1, true) ~= nil)
    assert.are.equal(vim.log.levels.INFO, notify_calls[1].level)
  end)

  it("notifies when languages are unavailable", function()
    local buf = make_buf({ "Hello" }, "typescriptreact", "/tmp/project/src/page_lang.tsx")

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        languages = {},
        index = {},
      }
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function()
      return {
        {
          lnum = 0,
          col = 0,
          end_lnum = 0,
          end_col = 5,
          text = "Hello",
          source_text = "Hello",
          kind = "jsx_text",
          replacement_context = "jsx_child",
        },
      },
        nil
    end)

    local cfg = config_mod.setup({ primary_lang = "ja" })
    local result = extract.run(buf, cfg, {})

    assert.is_nil(result)
    assert.is_true(notify_calls[1].msg:find("no languages detected", 1, true) ~= nil)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("rejects candidates without a translation function in scope", function()
    local buf = make_buf({ "Hello" }, "typescriptreact")
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = nil,
        found_hook = false,
        has_any_hook = false,
      }
    end)

    local candidates, rejected = extract._test.build_candidates(buf, {
      {
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 5,
        text = "Hello",
        source_text = "Hello",
        kind = "jsx_text",
        replacement_context = "jsx_child",
      },
    }, "common", { key_separator = "-" }, {})

    assert.are.equal(0, #candidates)
    assert.are.equal(1, rejected)
  end)

  it("rejects ambiguous translation functions and queries the candidate byte column", function()
    local buf = make_buf({ "const label = <p>Hello</p>" }, "typescriptreact")
    local queried_col
    add_stub(scan, "translation_context_at", function(_bufnr, _row, opts)
      queried_col = opts.col
      return {
        namespace = "common",
        t_func = "t",
        binding_id = "t@42",
        hook = "useTranslation",
        framework = "i18next",
        source_key_policy = "canonical",
        namespace_resolution = "static",
        found_hook = true,
        has_any_hook = true,
        ambiguous = true,
      }
    end)

    local candidates, rejected = extract._test.build_candidates(buf, {
      {
        lnum = 0,
        col = 17,
        end_lnum = 0,
        end_col = 22,
        text = "Hello",
        source_text = "Hello",
        kind = "jsx_text",
        replacement_context = "jsx_child",
      },
    }, "common", { key_separator = "-" }, {})

    assert.are.equal(17, queried_col)
    assert.are.equal(0, #candidates)
    assert.are.equal(1, rejected)
  end)

  it("rejects next-intl translators without a static namespace", function()
    local buf = make_buf({ "const label = <p>Hello</p>" }, "typescriptreact")
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = "t",
        binding_id = "t@42",
        hook = "useTranslations",
        framework = "next_intl",
        source_key_policy = "canonical",
        namespace_resolution = "absent",
        found_hook = true,
        has_any_hook = true,
        ambiguous = false,
      }
    end)

    local candidates, rejected = extract._test.build_candidates(buf, {
      {
        lnum = 0,
        col = 17,
        end_lnum = 0,
        end_col = 22,
        text = "Hello",
        source_text = "Hello",
        kind = "jsx_text",
        replacement_context = "jsx_child",
      },
    }, "common", { key_separator = "-" }, {})

    assert.are.equal(0, #candidates)
    assert.are.equal(1, rejected)
  end)

  it("rejects dynamically resolved namespaces", function()
    local buf = make_buf({ "const label = <p>Hello</p>" }, "typescriptreact")
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = "t",
        binding_id = "t@42",
        hook = "useTranslation",
        framework = "i18next",
        source_key_policy = "canonical",
        namespace_resolution = "dynamic",
        found_hook = true,
        has_any_hook = true,
        ambiguous = false,
      }
    end)

    local candidates, rejected = extract._test.build_candidates(buf, {
      {
        lnum = 0,
        col = 17,
        end_lnum = 0,
        end_col = 22,
        text = "Hello",
        source_text = "Hello",
        kind = "jsx_text",
        replacement_context = "jsx_child",
      },
    }, "common", { key_separator = "-" }, {})

    assert.are.equal(0, #candidates)
    assert.are.equal(1, rejected)
  end)

  it("aborts when the source changes while the review is being built", function()
    local buf = make_buf({ "Hello" }, "typescriptreact", "/tmp/project/src/page_race.tsx")
    local opened = false
    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        key = "/tmp/project\0i18next",
        roots = { { kind = "i18next", path = "/tmp/project/locales" } },
        languages = { "ja", "en" },
        index = { ja = {}, en = {} },
      }
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Changed" })
      return {
        {
          lnum = 0,
          col = 0,
          end_lnum = 0,
          end_col = 5,
          text = "Hello",
          source_text = "Hello",
          kind = "jsx_text",
          replacement_context = "jsx_child",
        },
      },
        nil
    end)
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = "t",
        binding_id = "t@42",
        hook = "useTranslation",
        framework = "i18next",
        source_key_policy = "canonical",
        namespace_resolution = "static",
        extract_safe = true,
        ambiguous = false,
        found_hook = true,
        has_any_hook = true,
      }
    end)
    add_stub(extract_review, "open", function()
      opened = true
      return {}
    end)

    local result = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})

    assert.is_nil(result)
    assert.is_false(opened)
    assert.are.equal("Changed", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.is_truthy(notify_calls[#notify_calls].msg:find("source changed while building", 1, true))
  end)

  it("uses the first detected language when configured primary is absent", function()
    local primary, used_fallback = extract._test.effective_primary({ "ja", "fr" }, "en")

    assert.are.equal("ja", primary)
    assert.is_true(used_fallback)
  end)
end)
