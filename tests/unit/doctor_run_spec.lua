local doctor = require("i18n-status.doctor")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")

describe("doctor async run", function()
  local original_notify
  local original_setqflist
  local original_cmd
  local rpc
  local original_rpc_request
  local original_rpc_request_sync
  local original_rpc_on_notification
  local original_rpc_off_notification

  before_each(function()
    original_notify = vim.notify
    original_setqflist = vim.fn.setqflist
    original_cmd = vim.api.nvim_cmd
    rpc = require("i18n-status.rpc")
    original_rpc_request = rpc.request
    original_rpc_request_sync = rpc.request_sync
    original_rpc_on_notification = rpc.on_notification
    original_rpc_off_notification = rpc.off_notification

    vim.notify = function(...)
      original_notify(...)
    end
    vim.fn.setqflist = function()
      return 0
    end
    vim.api.nvim_cmd = function()
      return
    end
    rpc.on_notification = function()
      return
    end
    rpc.off_notification = function()
      return
    end
    rpc.request = function(_method, _params, cb, _opts)
      vim.schedule(function()
        cb(nil, { issues = {}, used_keys = {} })
      end)
    end
    rpc.request_sync = function(method, _params)
      if method == "resource/resolveRoots" then
        return { roots = {} }, nil
      end
      if method == "resource/buildIndex" then
        return {
          index = {},
          files = {},
          languages = { "ja", "en" },
          errors = {},
          namespaces = {},
        },
          nil
      end
      return {}, nil
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.setqflist = original_setqflist
    vim.api.nvim_cmd = original_cmd
    rpc.request = original_rpc_request
    rpc.request_sync = original_rpc_request_sync
    rpc.on_notification = original_rpc_on_notification
    rpc.off_notification = original_rpc_off_notification
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
      local completed = vim.wait(500, function()
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

      local request_params = nil
      local request_cb = nil
      rpc.request = function(_method, params, cb, _opts)
        request_params = params
        request_cb = cb
        return 42
      end
      local original_stop = rpc.stop
      local stop_called = false
      rpc.stop = function()
        stop_called = true
      end
      vim.notify = function()
        return
      end

      doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))
      local started = vim.wait(500, function()
        return request_params ~= nil
      end, 10)
      assert.is_true(started, "doctor request did not start")
      assert.is_truthy(request_params.cancel_token_path)

      local cancelled = doctor.cancel()
      assert.is_true(cancelled)
      assert.is_false(stop_called)
      assert.is_not_nil(vim.uv.fs_stat(request_params.cancel_token_path))

      request_cb(nil, { issues = {}, used_keys = {}, cancelled = true })
      local cleaned = vim.wait(500, function()
        return vim.uv.fs_stat(request_params.cancel_token_path) == nil
      end, 10)

      assert.is_true(cleaned, "cancel token file should be removed after callback")
      rpc.stop = original_stop
    end)
  end)
end)
