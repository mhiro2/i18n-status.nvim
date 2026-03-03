local stub = require("luassert.stub")

local config_mod = require("i18n-status.config")
local extract = require("i18n-status.extract")
local extract_review = require("i18n-status.extract_review")
local hardcoded = require("i18n-status.hardcoded")
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
          kind = "jsx_text",
        },
        {
          lnum = 1,
          col = 0,
          end_lnum = 1,
          end_col = 9,
          text = "New value",
          kind = "jsx_text",
        },
      },
        nil
    end)
    add_stub(scan, "translation_context_at", function()
      return {
        namespace = "common",
        t_func = "t",
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
    assert.is_false(open_opts.candidates[1].selected)
    assert.are.equal("common:new-value", open_opts.candidates[2].proposed_key)
    assert.are.equal("ready", open_opts.candidates[2].status)
    assert.is_false(open_opts.candidates[2].selected)
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
          kind = "jsx_text",
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
end)
