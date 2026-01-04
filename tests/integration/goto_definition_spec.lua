local init = require("i18n-status")
local core = require("i18n-status.core")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")

describe("goto definition mapping", function()
  before_each(function()
    state.inline_by_buf = {}
  end)

  it("opens translation file when cursor is on inline key", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"jump":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("jump.title")' })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_buf_set_name(buf, root .. "/src/index.ts")
      vim.api.nvim_set_current_buf(buf)

      init.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })
      init.attach(buf)
      core.refresh_now(buf, init.get_config())

      local entries = state.inline_by_buf[buf] and state.inline_by_buf[buf][0]
      assert.is_not_nil(entries)
      vim.api.nvim_win_set_cursor(0, { 1, entries[1].col })

      local opened
      local original_cmd = vim.api.nvim_cmd
      vim.api.nvim_cmd = function(cmd, opts)
        if cmd.cmd == "edit" then
          opened = cmd.args[1]
        end
        return original_cmd(cmd, opts)
      end

      local ok = init.goto_definition(buf)

      vim.api.nvim_cmd = original_cmd

      assert.is_true(ok)
      assert.is_true(opened and opened:find("common.json", 1, true) ~= nil)
    end)
  end)
end)
