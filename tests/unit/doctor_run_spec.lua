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
  local original_review_module

  before_each(function()
    doctor._reset_open_buffer_snapshots_for_test()
    original_notify = vim.notify
    original_setqflist = vim.fn.setqflist
    original_cmd = vim.api.nvim_cmd
    rpc = require("i18n-status.rpc")
    original_rpc_request = rpc.request
    original_rpc_request_sync = rpc.request_sync
    original_rpc_on_notification = rpc.on_notification
    original_rpc_off_notification = rpc.off_notification
    original_review_module = package.loaded["i18n-status.review"]

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

    package.loaded["i18n-status.review"] = {
      open_doctor_results = function() end,
    }
  end)

  after_each(function()
    doctor._reset_open_buffer_snapshots_for_test()
    vim.notify = original_notify
    vim.fn.setqflist = original_setqflist
    vim.api.nvim_cmd = original_cmd
    rpc.request = original_rpc_request
    rpc.request_sync = original_rpc_request_sync
    rpc.on_notification = original_rpc_on_notification
    rpc.off_notification = original_rpc_off_notification
    package.loaded["i18n-status.review"] = original_review_module
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

  it("sends open buffer source only when it changed", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":"A"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a":"A"}')
    helpers.write_file(root .. "/src.ts", 't("a")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/src.ts")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("a")' })
      vim.bo[buf].filetype = "typescript"

      local original_list_bufs = vim.api.nvim_list_bufs
      local calls = {}
      local ok, err = pcall(function()
        vim.api.nvim_list_bufs = function()
          return { buf }
        end

        rpc.request = function(_method, params, cb, _opts)
          table.insert(calls, params)
          vim.schedule(function()
            cb(nil, { issues = {}, used_keys = {} })
          end)
        end

        local config = config_mod.setup({ primary_lang = "ja" })
        local done = false

        doctor.diagnose(buf, config, function()
          done = true
        end)
        assert.is_true(vim.wait(500, function()
          return done
        end, 10))
        assert.are.equal(1, #calls[1].open_buffers)
        assert.is_true(#calls[1].open_buf_paths > 0)

        done = false
        doctor.diagnose(buf, config, function()
          done = true
        end)
        assert.is_true(vim.wait(500, function()
          return done
        end, 10))
        assert.are.equal(0, #calls[2].open_buffers)
        assert.are.equal(0, #calls[2].open_buf_paths)

        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 't("b")' })

        done = false
        doctor.diagnose(buf, config, function()
          done = true
        end)
        assert.is_true(vim.wait(500, function()
          return done
        end, 10))
        assert.are.equal(1, #calls[3].open_buffers)
      end)
      vim.api.nvim_list_bufs = original_list_bufs
      assert.is_true(ok, err)
    end)
  end)

  it("skips sending oversized open buffer source", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":"A"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a":"A"}')
    helpers.write_file(root .. "/big.ts", 't("a")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/big.ts")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 600000) })
      vim.bo[buf].filetype = "typescript"

      local original_list_bufs = vim.api.nvim_list_bufs
      local notify_before = vim.notify
      local captured = nil
      local warnings = {}
      local ok, err = pcall(function()
        vim.api.nvim_list_bufs = function()
          return { buf }
        end
        vim.notify = function(msg, level)
          table.insert(warnings, { msg = msg, level = level })
        end
        rpc.request = function(_method, params, cb, _opts)
          captured = params
          vim.schedule(function()
            cb(nil, { issues = {}, used_keys = {} })
          end)
        end

        local config = config_mod.setup({ primary_lang = "ja" })
        local done = false
        doctor.diagnose(buf, config, function()
          done = true
        end)
        assert.is_true(vim.wait(500, function()
          return done
        end, 10))
      end)
      vim.notify = notify_before
      vim.api.nvim_list_bufs = original_list_bufs
      assert.is_true(ok, err)
      assert.is_not_nil(captured)
      assert.are.equal(0, #captured.open_buffers)
      assert.are.equal(0, #captured.open_buf_paths)
      assert.is_true(#warnings > 0)
      assert.is_truthy(warnings[#warnings].msg:find("skipped 1 open buffer", 1, true))
    end)
  end)
end)
