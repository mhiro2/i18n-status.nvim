local init = require("i18n-status")
local core = require("i18n-status.core")
local state = require("i18n-status.state")
local helpers = require("tests.helpers")
require("plugin.i18n-status")

local function setup_buffer(root)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
  vim.bo[buf].filetype = "typescript"
  vim.api.nvim_buf_set_name(buf, root .. "/src/app.ts")
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe(":I18nLang", function()
  before_each(function()
    -- Reset inline cache between tests
    state.inline_by_buf = {}
  end)

  it("warns when an unknown language is requested", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local buf = setup_buffer(root)
      init.setup({ primary_lang = "ja" })
      init.attach(buf)
      core.refresh_now(buf, init.get_config())

      local original_notify_once = vim.notify_once
      local notifications = {}
      vim.notify_once = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      vim.api.nvim_cmd({ cmd = "I18nLang", args = { "fr" } }, {})

      vim.notify_once = original_notify_once

      local project = select(1, state.project_for_buf(buf))
      assert.are.equal("ja", project.current_lang)
      assert.are.equal(1, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.is_truthy(notifications[1].msg:find("unknown language 'fr'", 1, true))
    end)
  end)

  it("switches language when valid", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local buf = setup_buffer(root)
      init.setup({ primary_lang = "ja" })
      init.attach(buf)
      core.refresh_now(buf, init.get_config())

      local original_notify_once = vim.notify_once
      local notifications = {}
      vim.notify_once = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      vim.api.nvim_cmd({ cmd = "I18nLang", args = { "en" } }, {})

      vim.notify_once = original_notify_once

      local project = select(1, state.project_for_buf(buf))
      assert.are.equal("en", project.current_lang)
      assert.are.equal(0, #notifications)
    end)
  end)

  it("completes available languages", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local buf = setup_buffer(root)
      init.setup({ primary_lang = "ja" })
      init.attach(buf)
      core.refresh_now(buf, init.get_config())

      local candidates = vim.fn.getcompletion("I18nLang ", "cmdline")
      table.sort(candidates)
      assert.same({ "en", "ja" }, candidates)

      local filtered = vim.fn.getcompletion("I18nLang j", "cmdline")
      assert.same({ "ja" }, filtered)
    end)
  end)
end)
