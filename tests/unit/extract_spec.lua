local stub = require("luassert.stub")

local config_mod = require("i18n-status.config")
local core = require("i18n-status.core")
local extract = require("i18n-status.extract")
local hardcoded = require("i18n-status.hardcoded")
local key_write = require("i18n-status.key_write")
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

describe("extract", function()
  local stubs = {}
  local original_input
  local original_notify
  local write_calls
  local notify_calls
  local input_queue
  local hardcoded_items
  local context_fn
  local cache_data

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    table.insert(stubs, s)
    return s
  end

  before_each(function()
    write_calls = {}
    notify_calls = {}
    input_queue = {}
    hardcoded_items = {}
    cache_data = {
      languages = { "ja", "en" },
      index = { ja = {}, en = {} },
    }
    context_fn = function(_bufnr, _row, _opts)
      return {
        namespace = "common",
        t_func = "t",
        found_hook = true,
        has_any_hook = true,
      }
    end

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return cache_data
    end)
    add_stub(resources, "fallback_namespace", function()
      return "common"
    end)
    add_stub(hardcoded, "extract", function()
      return hardcoded_items
    end)
    add_stub(scan, "translation_context_at", function(bufnr, row, opts)
      return context_fn(bufnr, row, opts)
    end)
    add_stub(key_write, "write_translations", function(namespace, key_path, translations, start_dir, languages)
      table.insert(write_calls, {
        namespace = namespace,
        key_path = key_path,
        translations = translations,
        start_dir = start_dir,
        languages = languages,
      })
      return #languages, {}
    end)
    add_stub(core, "refresh", function() end)
    add_stub(core, "refresh_all", function() end)

    original_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      local next_value = table.remove(input_queue, 1)
      if next_value == "__DEFAULT__" then
        on_confirm(opts.default)
        return
      end
      on_confirm(next_value)
    end

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.ui.input = original_input
    vim.notify = original_notify
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}
  end)

  it("uses non-ascii fallback key and avoids existing key collisions", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file1.tsx")
    cache_data = {
      languages = { "ja", "en" },
      index = { ja = { ["common:file1.text_1"] = {} }, en = {} },
    }
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "ログインしてください",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal('{t("common:file1.text_2")}', line)
    assert.are.equal(1, #write_calls)
    assert.are.equal("common", write_calls[1].namespace)
    assert.are.equal("file1.text_2", write_calls[1].key_path)
    assert.are.equal("ログインしてください", write_calls[1].translations.ja)
    assert.are.equal("", write_calls[1].translations.en)
  end)

  it("replaces multiple items on the same line safely", function()
    local buf = make_buf({ "AAAA BBBB" }, "typescriptreact", "/tmp/project/src/file2.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "AAAA",
        kind = "jsx_text",
      },
      {
        bufnr = buf,
        lnum = 0,
        col = 5,
        end_lnum = 0,
        end_col = 9,
        text = "BBBB",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__", "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal('{t("common:file2.aaaa")} {t("common:file2.bbbb")}', line)
    assert.are.equal(2, #write_calls)
  end)

  it("cancels when no translation hook is detected", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file3.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "TEXT",
        kind = "jsx_text",
      },
    }
    context_fn = function(_bufnr, row, _opts)
      if row == 0 then
        return {
          namespace = "common",
          t_func = "t",
          found_hook = false,
          has_any_hook = false,
        }
      end
      return {
        namespace = "common",
        t_func = "t",
        found_hook = false,
        has_any_hook = false,
      }
    end
    input_queue = { "n" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal("TEXT", line)
    assert.are.equal(0, #write_calls)
  end)

  it("uses translation function alias for replacement", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file4.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "Hello",
        kind = "jsx_text",
      },
    }
    context_fn = function(_bufnr, _row, _opts)
      return {
        namespace = "common",
        t_func = "tr",
        found_hook = true,
        has_any_hook = true,
      }
    end
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal('{tr("common:file4.hello")}', line)
  end)
end)
