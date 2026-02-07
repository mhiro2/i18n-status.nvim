local doctor = require("i18n-status.doctor")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")

describe("doctor async run", function()
  local original_system
  local original_defer
  local original_notify
  local original_setqflist
  local original_cmd

  before_each(function()
    original_system = vim.system
    original_defer = vim.defer_fn
    original_notify = vim.notify
    original_setqflist = vim.fn.setqflist
    original_cmd = vim.api.nvim_cmd

    vim.system = function(_cmd, _opts, on_exit)
      local handle = { kill = function() end }
      vim.schedule(function()
        on_exit({ code = 0, stdout = "" })
      end)
      return handle
    end
    vim.defer_fn = function(fn, _)
      fn()
    end
    vim.notify = function(...)
      original_notify(...)
    end
    vim.fn.setqflist = function()
      return 0
    end
    vim.api.nvim_cmd = function()
      return
    end
  end)

  after_each(function()
    vim.system = original_system
    vim.defer_fn = original_defer
    vim.notify = original_notify
    vim.fn.setqflist = original_setqflist
    vim.api.nvim_cmd = original_cmd
  end)

  it("completes run() without errors", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.write_file(root .. "/src.tsx", 't("login.title")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local messages = {}
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end

      doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))
      local completed = vim.wait(100, function()
        return #messages >= 2
      end)
      assert.is_true(completed, "doctor.run did not finish")
      local final = messages[#messages]
      assert.is_truthy(final and final.msg:match("i18n%-status doctor"))
    end)
  end)

  it("cancels active async job", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.write_file(root .. "/src.tsx", 't("login.title")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local killed_signal = nil
      vim.system = function(_cmd, _opts, _on_exit)
        return {
          kill = function(_, signal)
            killed_signal = signal
          end,
        }
      end

      doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))
      local cancelled = doctor.cancel()

      assert.is_true(cancelled)
      assert.are.equal(15, killed_signal)
    end)
  end)
end)
