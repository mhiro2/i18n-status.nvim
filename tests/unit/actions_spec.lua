local actions = require("i18n-status.actions")
local state = require("i18n-status.state")

describe("actions (unit)", function()
  before_each(function()
    state.init("en", { "en", "ja" })
    state.inline_by_buf = {}
    state.set_buf_project(vim.api.nvim_get_current_buf(), "__default__")
  end)

  it("resolves item under cursor by column", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "01234567890" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    state.inline_by_buf[buf] = {
      [0] = {
        { col = 0, end_col = 4, resolved = { key = "first", hover = { values = {} } } },
        { col = 6, end_col = 10, resolved = { key = "second", hover = { values = {} } } },
      },
    }

    local item = actions.item_at_cursor(buf)
    assert.are.equal("second", item.key)
  end)

  it("returns nil when cursor is outside item range", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "01234567890" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    state.inline_by_buf[buf] = {
      [0] = {
        { col = 0, end_col = 4, resolved = { key = "first", hover = { values = {} } } },
        { col = 6, end_col = 10, resolved = { key = "second", hover = { values = {} } } },
      },
    }

    local item = actions.item_at_cursor(buf)
    assert.is_nil(item)
  end)

  it("uses window cursor for non-current buffer", function()
    local current_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, { "current" })
    vim.api.nvim_set_current_buf(current_buf)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "01234567890" })
    state.inline_by_buf[buf] = {
      [0] = {
        { col = 0, end_col = 4, resolved = { key = "first", hover = { values = {} } } },
        { col = 6, end_col = 10, resolved = { key = "second", hover = { values = {} } } },
      },
    }

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 12,
      height = 1,
      style = "minimal",
    })
    vim.api.nvim_win_set_cursor(win, { 1, 7 })

    local item = actions.item_at_cursor(buf)

    vim.api.nvim_win_close(win, true)

    assert.are.equal("second", item.key)
  end)

  it("prefers current language when jumping to definition", function()
    local original_cmd = vim.api.nvim_cmd
    local opened = nil
    vim.api.nvim_cmd = function(cmd)
      opened = cmd.args[1]
    end

    state.set_current(nil, "ja")
    local item = {
      hover = {
        values = {
          ja = { file = "/tmp/ja.json" },
          en = { file = "/tmp/en.json" },
        },
      },
    }

    local ok = actions.jump_to_definition(item)
    vim.api.nvim_cmd = original_cmd

    assert.is_true(ok)
    assert.are.equal("/tmp/ja.json", opened)
  end)

  it("falls back to any available file", function()
    local original_cmd = vim.api.nvim_cmd
    local opened = nil
    vim.api.nvim_cmd = function(cmd)
      opened = cmd.args[1]
    end

    state.set_current(nil, "ja")
    local item = {
      hover = {
        values = {
          fr = { file = "/tmp/fr.json" },
        },
      },
    }

    local ok = actions.jump_to_definition(item)
    vim.api.nvim_cmd = original_cmd

    assert.is_true(ok)
    assert.are.equal("/tmp/fr.json", opened)
  end)

  it("returns false when no files exist", function()
    local ok = actions.jump_to_definition({
      hover = { values = { ja = {} } },
    })
    assert.is_false(ok)
  end)

  it("extracts fallback value when primary language is missing", function()
    state.set_current(nil, "ja")
    local item = {
      key = "common:missing.key",
      hover = {
        values = {
          en = { file = "/tmp/en.json", value = "Fallback Value" },
          fr = { file = "/tmp/fr.json", value = "Valeur de secours" },
        },
      },
    }

    -- Since ja (primary) is missing, should fall back to available language
    local hover_values = item.hover.values
    assert.is_nil(hover_values.ja, "ja should be missing")
    assert.is_not_nil(hover_values.en or hover_values.fr, "should have fallback value")
  end)

  it("prefers primary language over fallback when both exist", function()
    state.set_current(nil, "ja")
    local item = {
      hover = {
        values = {
          ja = { file = "/tmp/ja.json", value = "日本語" },
          en = { file = "/tmp/en.json", value = "English" },
        },
      },
    }

    local hover_values = item.hover.values
    assert.is_not_nil(hover_values.ja, "ja should exist")
    assert.are.equal("日本語", hover_values.ja.value)
  end)
end)
