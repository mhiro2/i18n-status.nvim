local actions = require("i18n-status.actions")
local state = require("i18n-status.state")
local ui = require("i18n-status.ui")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

describe("hover", function()
  it("opens hover preview with translations", function()
    local buf = make_buf({ 't("login.title")' }, "typescript")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    state.inline_by_buf[buf] = {
      [0] = {
        {
          col = 0,
          end_col = 5,
          resolved = {
            key = "common:login.title",
            status = "=",
            hover = {
              namespace = "common",
              status = "=",
              values = {
                ja = { value = "ログイン", file = "/tmp/locales/ja/common.json" },
                en = { value = "Login" },
              },
              lang_order = { "ja", "en" },
            },
          },
        },
      },
    }

    local captured = nil
    local original_open = ui.open_hover
    ui.open_hover = function(lines)
      captured = lines
    end

    actions.hover(buf)

    ui.open_hover = original_open

    assert.is_not_nil(captured)
    local found_key = false
    local found_ja = false
    local found_file = false
    for _, line in ipairs(captured) do
      if line:find("common:login.title", 1, true) then
        found_key = true
      end
      if line:find("ja:", 1, true) and line:find("ログイン", 1, true) then
        found_ja = true
      end
      if line:find("/tmp/locales/ja/common.json", 1, true) then
        found_file = true
      end
    end
    assert.is_true(found_key)
    assert.is_true(found_ja)
    assert.is_true(found_file)
  end)

  it("shows mismatch reason details", function()
    local buf = make_buf({ 't("login.count")' }, "typescript")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    state.inline_by_buf[buf] = {
      [0] = {
        {
          col = 0,
          end_col = 5,
          resolved = {
            key = "common:login.count",
            status = "!",
            hover = {
              namespace = "common",
              status = "!",
              reason = "placeholder_mismatch",
              mismatch_langs = { "en" },
              values = {
                ja = { value = "{count}件", file = "/tmp/locales/ja/common.json" },
                en = { value = "{name}" },
              },
              lang_order = { "ja", "en" },
              primary_lang = "ja",
            },
          },
        },
      },
    }

    local captured = nil
    local original_open = ui.open_hover
    ui.open_hover = function(lines)
      captured = lines
    end

    actions.hover(buf)

    ui.open_hover = original_open

    local found_reason = false
    local found_mismatch = false
    local found_placeholders = false
    for _, line in ipairs(captured or {}) do
      if line:find("reason:", 1, true) and line:find("placeholder_mismatch", 1, true) then
        found_reason = true
      end
      if line:find("mismatch_langs:", 1, true) and line:find("en", 1, true) then
        found_mismatch = true
      end
      if line:find("## Placeholders", 1, true) then
        found_placeholders = true
      end
    end
    assert.is_true(found_reason)
    assert.is_true(found_mismatch)
    assert.is_true(found_placeholders)
  end)

  it("does not show action hints in hover", function()
    local buf = make_buf({ 't("login.title")' }, "typescript")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    state.inline_by_buf[buf] = {
      [0] = {
        {
          col = 0,
          end_col = 5,
          resolved = {
            key = "common:login.title",
            status = "=",
            hover = {
              namespace = "common",
              status = "=",
              values = {
                ja = { value = "ログイン", file = "/tmp/locales/ja/common.json" },
                en = { value = "Login" },
              },
              lang_order = { "ja", "en" },
            },
          },
        },
      },
    }

    local captured = nil
    local original_open = ui.open_hover
    ui.open_hover = function(lines)
      captured = lines
    end

    actions.hover(buf)

    ui.open_hover = original_open

    assert.is_not_nil(captured)
    local found_actions = false
    for _, line in ipairs(captured) do
      if line:find("## Actions", 1, true) then
        found_actions = true
        break
      end
    end
    assert.is_false(found_actions, "Hover should not include action hints")
  end)
end)
