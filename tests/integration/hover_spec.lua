local actions = require("i18n-status.actions")
local resolve = require("i18n-status.resolve")
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

  it("shows the placeholder names the core compared for a mismatch", function()
    local buf = make_buf({ 't("cart.summary")' }, "typescript")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local function entry(value)
      return { value = value, file = "/tmp/messages.json", framework = "next_intl" }
    end
    local resolved = resolve.compute({ { key = "cart:summary" } }, {
      primary_lang = "en",
      languages = { "en", "ja" },
    }, {
      en = { ["cart:summary"] = entry("{name} has {count, plural, one {# item} other {# items}}") },
      ja = { ["cart:summary"] = entry("{name} の'{'商品'}'") },
    })
    assert.are.equal(1, #resolved)
    state.inline_by_buf[buf] = {
      [0] = { { col = 0, end_col = 5, resolved = resolved[1] } },
    }

    local captured = nil
    local original_open = ui.open_hover
    ui.open_hover = function(lines)
      captured = lines
    end
    actions.hover(buf)
    ui.open_hover = original_open

    assert.is_not_nil(captured)
    local section = nil
    for index, line in ipairs(captured) do
      if line == "## Placeholders" then
        section = index
      end
    end
    assert.is_not_nil(section, "hover has no placeholder section")
    assert.is_truthy(vim.tbl_contains(captured, "- reason: `placeholder_mismatch`"))
    assert.is_truthy(vim.tbl_contains(captured, "- mismatch_langs: `ja`"))
    -- ICU plural arguments count, while quoted braces in the translation do not.
    assert.are.same({ "- en: count, name", "- ja: name" }, vim.list_slice(captured, section + 1, section + 2))
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
