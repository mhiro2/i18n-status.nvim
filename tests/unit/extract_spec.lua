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
  local original_select
  local original_notify
  local write_calls
  local notify_calls
  local input_queue
  local input_calls
  local select_queue
  local select_calls
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
    input_calls = {}
    select_queue = {}
    select_calls = {}
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
      table.insert(input_calls, opts)
      local next_value = table.remove(input_queue, 1)
      if next_value == "__DEFAULT__" then
        on_confirm(opts.default)
        return
      end
      on_confirm(next_value)
    end

    original_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      table.insert(select_calls, { items = items, opts = opts })
      local next_value = table.remove(select_queue, 1)
      if next_value == "__DEFAULT__" then
        on_choice(items[1])
        return
      end
      if next_value == "__NONE__" then
        on_choice(nil)
        return
      end
      on_choice(next_value)
    end

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.ui.input = original_input
    vim.ui.select = original_select
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
      index = { ja = { ["common:key"] = {} }, en = {} },
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
    assert.are.equal('{t("common:key-0")}', line)
    assert.are.equal(1, #write_calls)
    assert.are.equal("common", write_calls[1].namespace)
    assert.are.equal("key-0", write_calls[1].key_path)
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
    assert.are.equal('{t("common:aaaa")} {t("common:bbbb")}', line)
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
    select_queue = { "No" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal("TEXT", line)
    assert.are.equal(0, #write_calls)
    assert.are.equal(1, #select_calls)
    assert.same({ "Yes", "No" }, select_calls[1].items)
    assert.are.equal("No translation hook found in this file. Continue?", select_calls[1].opts.prompt)
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
    assert.are.equal('{tr("common:hello")}', line)
  end)

  it("uses configured key separator for auto-generated keys", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file4_sep.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "Hello world",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({
      primary_lang = "ja",
      extract = { key_separator = "_" },
    })

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal('{t("common:hello_world")}', line)
    assert.are.equal("hello_world", write_calls[1].key_path)
  end)

  it("includes text preview in extract prompt", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file5.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "Hello world",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    assert.is_true(input_calls[1].prompt:find('Extract "Hello world" (1:1): ', 1, true) ~= nil)
  end)

  it("normalizes whitespace and truncates prompt preview", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file6.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 4,
        text = "Long\n\n   text value that should be truncated for prompt display",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    local prompt = input_calls[1].prompt
    assert.is_nil(prompt:find("\n", 1, true))
    assert.is_true(prompt:find("...", 1, true) ~= nil)
  end)

  it("focuses target text and restores original cursor after extraction", function()
    local buf = make_buf({ "AAAA", "BBBB" }, "typescriptreact", "/tmp/project/src/file7.tsx")
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
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
    }
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })
    local cursor_calls = {}
    local clear_calls = {}
    local highlight_calls = {}

    add_stub(vim.api, "nvim_win_set_cursor", function(winid, pos)
      table.insert(cursor_calls, { winid = winid, pos = { pos[1], pos[2] } })
    end)
    add_stub(vim.api, "nvim_buf_clear_namespace", function(bufnr, ns_id, first, last)
      table.insert(clear_calls, { bufnr = bufnr, ns_id = ns_id, first = first, last = last })
    end)
    add_stub(vim.api, "nvim_buf_add_highlight", function(bufnr, ns_id, group, line, col_start, col_end)
      table.insert(highlight_calls, {
        bufnr = bufnr,
        ns_id = ns_id,
        group = group,
        line = line,
        col_start = col_start,
        col_end = col_end,
      })
    end)

    extract.run(buf, cfg, {})

    assert.is_true(#highlight_calls > 0)
    assert.is_true(#clear_calls > 0)
    assert.are.same({ 1, 0 }, cursor_calls[1].pos)
    assert.are.same({ 2, 0 }, cursor_calls[#cursor_calls].pos)
  end)

  it("restores cursor and clears highlight when cancelled before extraction", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file8.tsx")
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { 1, 2 })
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
    context_fn = function()
      return {
        namespace = "common",
        t_func = "t",
        found_hook = false,
        has_any_hook = false,
      }
    end
    select_queue = { "No" }
    local cfg = config_mod.setup({ primary_lang = "ja" })
    local cursor_calls = {}
    local clear_calls = {}

    add_stub(vim.api, "nvim_win_set_cursor", function(winid, pos)
      table.insert(cursor_calls, { winid = winid, pos = { pos[1], pos[2] } })
    end)
    add_stub(vim.api, "nvim_buf_clear_namespace", function(bufnr, ns_id, first, last)
      table.insert(clear_calls, { bufnr = bufnr, ns_id = ns_id, first = first, last = last })
    end)

    extract.run(buf, cfg, {})

    assert.are.equal(0, #write_calls)
    assert.is_true(#clear_calls > 0)
    assert.are.same({ 1, 2 }, cursor_calls[#cursor_calls].pos)
  end)

  it("processes extraction targets from top to bottom", function()
    local buf = make_buf({ "Top", "Bottom" }, "typescriptreact", "/tmp/project/src/file9.tsx")
    hardcoded_items = {
      {
        bufnr = buf,
        lnum = 1,
        col = 0,
        end_lnum = 1,
        end_col = 6,
        text = "Bottom",
        kind = "jsx_text",
      },
      {
        bufnr = buf,
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 3,
        text = "Top",
        kind = "jsx_text",
      },
    }
    input_queue = { "__DEFAULT__", "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    extract.run(buf, cfg, {})

    assert.is_true(input_calls[1].prompt:find('Extract "Top" (1:1): ', 1, true) ~= nil)
    assert.is_true(input_calls[2].prompt:find('Extract "Bottom" (2:1): ', 1, true) ~= nil)
  end)

  it("does not crash when buffer text update fails", function()
    local buf = make_buf({ "TEXT" }, "typescriptreact", "/tmp/project/src/file10.tsx")
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
    input_queue = { "__DEFAULT__" }
    local cfg = config_mod.setup({ primary_lang = "ja" })

    add_stub(vim.api, "nvim_buf_set_text", function()
      error("buffer is invalid")
    end)

    extract.run(buf, cfg, {})

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal("TEXT", line)
    assert.are.equal(1, #write_calls)

    local found_warning = false
    for _, call in ipairs(notify_calls) do
      if call.msg:find("failed to update buffer text", 1, true) then
        found_warning = true
        assert.are.equal(vim.log.levels.WARN, call.level)
      end
    end
    assert.is_true(found_warning)
  end)
end)
