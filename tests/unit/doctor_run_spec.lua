local doctor = require("i18n-status.doctor")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local resources = require("i18n-status.resources")

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
        for _, message in ipairs(messages) do
          if message.msg == "i18n-status doctor: ok" then
            return true
          end
        end
        return false
      end)
      assert.is_true(completed, "doctor.run did not finish")
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

  it("shows progress only for the active request", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/src.tsx", 't("login.title")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local handler = nil
      local request_cb = nil
      local echoed = {}
      local completed = false
      local original_echo = vim.api.nvim_echo
      local ok, err = pcall(function()
        rpc.on_notification = function(method, cb)
          assert.are.equal("doctor/progress", method)
          handler = cb
        end
        rpc.request = function(_method, _params, cb, _opts)
          request_cb = cb
          return 42
        end
        vim.api.nvim_echo = function(chunks)
          echoed[#echoed + 1] = chunks[1][1]
        end
        vim.notify = function() end
        package.loaded["i18n-status.review"].open_doctor_results = function()
          completed = true
        end

        doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))
        assert.is_true(vim.wait(500, function()
          return handler ~= nil and request_cb ~= nil
        end, 10))

        handler({ request_id = 41, message = "stale progress" })
        handler({ request_id = 42, message = "current progress" })
        assert.is_true(vim.wait(500, function()
          return #echoed == 1
        end, 10))
        assert.is_truthy(echoed[1]:find("current progress", 1, true))

        request_cb(nil, { issues = {}, used_keys = {} })
        assert.is_true(vim.wait(500, function()
          return completed
        end, 10))
      end)
      vim.api.nvim_echo = original_echo
      assert.is_true(ok, err)
    end)
  end)

  it("starts only the latest deferred run when rapid runs share an event-loop turn", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local original_defer_fn = vim.defer_fn
      local deferred = {}
      local callbacks = {}
      local opened = {}
      local ok, err = pcall(function()
        vim.defer_fn = function(cb)
          deferred[#deferred + 1] = cb
        end
        vim.notify = function() end
        rpc.request = function(_method, _params, cb)
          callbacks[#callbacks + 1] = cb
          return 100 + #callbacks
        end
        package.loaded["i18n-status.review"].open_doctor_results = function(issues)
          opened[#opened + 1] = issues
        end

        local config = config_mod.setup({ primary_lang = "ja" })
        doctor.run(buf, config)
        doctor.run(buf, config)

        assert.are.equal(2, #deferred)
        deferred[2]()
        deferred[1]()
        assert.are.equal(1, #callbacks)

        callbacks[1](nil, {
          issues = {
            { kind = "missing", message = "latest", severity = 1, key = "common:latest" },
          },
          used_keys = {},
        })
        assert.is_true(vim.wait(500, function()
          return #opened == 1
        end, 10))
        assert.are.equal("common:latest", opened[1][1].key)
      end)
      vim.defer_fn = original_defer_fn
      assert.is_true(ok, err)
    end)
  end)

  it("ignores an older callback without clearing the newer job or progress handler", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local original_defer_fn = vim.defer_fn
      local callbacks = {}
      local handlers = {}
      local removed = {}
      local opened = {}
      local ok, err = pcall(function()
        vim.defer_fn = function(cb)
          cb()
        end
        vim.notify = function() end
        rpc.request = function(_method, _params, cb)
          callbacks[#callbacks + 1] = cb
          return 200 + #callbacks
        end
        rpc.on_notification = function(_method, handler)
          handlers[#handlers + 1] = handler
        end
        rpc.off_notification = function(_method, handler)
          removed[#removed + 1] = handler
        end
        package.loaded["i18n-status.review"].open_doctor_results = function(issues)
          opened[#opened + 1] = issues
        end

        local config = config_mod.setup({ primary_lang = "ja" })
        doctor.run(buf, config)
        doctor.run(buf, config)
        assert.are.equal(2, #callbacks)
        assert.are.equal(2, #handlers)
        assert.are.same({ handlers[1] }, removed)

        callbacks[1](nil, { issues = {}, used_keys = {} })
        vim.wait(50)
        assert.are.equal(0, #opened)
        assert.are.same({ handlers[1] }, removed)

        callbacks[2](nil, {
          issues = {
            { kind = "missing", message = "newer", severity = 1, key = "common:newer" },
          },
          used_keys = {},
        })
        assert.is_true(vim.wait(500, function()
          return #opened == 1
        end, 10))
        assert.are.equal("common:newer", opened[1][1].key)
        assert.are.same({ handlers[1], handlers[2] }, removed)
      end)
      vim.defer_fn = original_defer_fn
      assert.is_true(ok, err)
    end)
  end)

  it("signals cancellation and completes once at the overall deadline", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local request_params = nil
      local request_opts = nil
      local request_cb = nil
      local callback_count = 0
      local status = nil
      vim.notify = function() end
      rpc.request = function(_method, params, cb, opts)
        request_params = params
        request_opts = opts
        request_cb = cb
        return 301
      end

      doctor.diagnose(buf, config_mod.setup({ primary_lang = "ja" }), function(_, result_status)
        callback_count = callback_count + 1
        status = result_status
      end, { deadline_ms = 20 })

      assert.is_true(vim.wait(500, function()
        return status ~= nil
      end, 10))
      assert.is_true(status.cancelled)
      assert.is_true(status.deadline)
      assert.is_true(request_params.deadline_ms > 0 and request_params.deadline_ms <= 20)
      assert.are.equal(request_params.deadline_ms + 5000, request_opts.timeout_ms)
      assert.is_not_nil(vim.uv.fs_stat(request_params.cancel_token_path))

      request_cb(nil, { issues = {}, used_keys = {} })
      assert.is_true(vim.wait(500, function()
        return vim.uv.fs_stat(request_params.cancel_token_path) == nil
      end, 10))
      assert.are.equal(1, callback_count)
    end)
  end)

  it("bounds hung resource preflight by the run-wide deadline", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/src.ts", 't("login.title")')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/src.ts")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local resolve_timeout_ms = nil
      local build_calls = 0
      local doctor_calls = 0
      local opened = 0
      local messages = {}
      rpc.request_sync = function(method, _params, timeout_ms)
        if method == "resource/resolveRoots" then
          resolve_timeout_ms = timeout_ms
          vim.wait(timeout_ms, function()
            return false
          end, 1)
          return nil, "sync request timeout"
        end
        if method == "resource/buildIndex" then
          build_calls = build_calls + 1
        end
        return {}, nil
      end
      rpc.request = function(method)
        if method == "doctor/diagnose" then
          doctor_calls = doctor_calls + 1
        end
        return 401
      end
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      package.loaded["i18n-status.review"].open_doctor_results = function()
        opened = opened + 1
      end

      doctor._set_deadline_ms_for_test(25)
      local started_at = vim.uv.hrtime()
      doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))

      assert.is_true(vim.wait(250, function()
        for _, message in ipairs(messages) do
          if message:find("deadline exceeded after 25ms", 1, true) then
            return true
          end
        end
        return false
      end, 1))
      local elapsed_ms = (vim.uv.hrtime() - started_at) / 1000000

      assert.is_not_nil(resolve_timeout_ms)
      assert.is_true(resolve_timeout_ms > 0 and resolve_timeout_ms <= 25)
      assert.are.equal(0, build_calls)
      assert.are.equal(0, doctor_calls)
      assert.are.equal(0, opened)
      assert.is_true(elapsed_ms < 200, "Doctor deadline did not bound resource preflight")
    end)
  end)

  it("reports exhausted Doctor task capacity as a retryable error", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local busy_message =
        "doctor is temporarily busy because task capacity is exhausted; retry after prior tasks finish"
      local notifications = {}
      local status = nil
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end
      rpc.request = function(method, _params, cb)
        assert.are.equal("doctor/diagnose", method)
        vim.schedule(function()
          cb(busy_message, nil)
        end)
        return 402
      end

      doctor.diagnose(buf, config_mod.setup({ primary_lang = "ja" }), function(_, result_status)
        status = result_status
      end)

      assert.is_true(vim.wait(500, function()
        return status ~= nil
      end, 10))
      assert.is_nil(status.cancelled)
      assert.are.equal(busy_message, status.error)
      assert.is_true(#notifications > 0)
      assert.is_truthy(notifications[#notifications].message:find("temporarily busy", 1, true))
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
    end)
  end)

  it("keeps a pending RPC cancel token when the run timer cannot be allocated", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local original_new_timer = vim.uv.new_timer
      local original_defer_fn = vim.defer_fn
      local timer_calls = 0
      local request_params = nil
      local request_cb = nil
      local deadline_seen = false
      local ok, err = pcall(function()
        vim.defer_fn = function(cb)
          cb()
        end
        vim.uv.new_timer = function()
          timer_calls = timer_calls + 1
          if timer_calls == 1 then
            return nil
          end
          return original_new_timer()
        end
        vim.notify = function(message)
          if message:find("deadline exceeded", 1, true) then
            deadline_seen = true
          end
        end
        rpc.request = function(_method, params, cb)
          request_params = params
          request_cb = cb
          return 403
        end

        doctor._set_deadline_ms_for_test(20)
        doctor.run(buf, config_mod.setup({ primary_lang = "ja" }))
        vim.uv.new_timer = original_new_timer

        assert.is_true(vim.wait(500, function()
          return deadline_seen
        end, 10))
        assert.are.equal(2, timer_calls)
        assert.is_not_nil(request_cb)
        assert.is_not_nil(vim.uv.fs_stat(request_params.cancel_token_path))

        request_cb("doctor request cancelled", nil)
        assert.is_true(vim.wait(500, function()
          return vim.uv.fs_stat(request_params.cancel_token_path) == nil
        end, 10))
      end)
      vim.uv.new_timer = original_new_timer
      vim.defer_fn = original_defer_fn
      assert.is_true(ok, err)
    end)
  end)

  it("cleans an old token when a newer run arrives before scheduled response delivery", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.title")' })
      vim.bo[buf].filetype = "typescript"

      local original_defer_fn = vim.defer_fn
      local original_schedule = vim.schedule
      local scheduled = {}
      local callbacks = {}
      local request_params = {}
      local ok, err = pcall(function()
        vim.defer_fn = function(cb)
          cb()
        end
        vim.schedule = function(cb)
          scheduled[#scheduled + 1] = cb
        end
        vim.notify = function() end
        rpc.request = function(_method, params, cb)
          request_params[#request_params + 1] = params
          callbacks[#callbacks + 1] = cb
          return 500 + #callbacks
        end

        local config = config_mod.setup({ primary_lang = "ja" })
        doctor.run(buf, config)
        callbacks[1](nil, { issues = {}, used_keys = {} })
        assert.are.equal(1, #scheduled)

        doctor.run(buf, config)
        local old_token = request_params[1].cancel_token_path
        assert.is_not_nil(vim.uv.fs_stat(old_token))

        scheduled[1]()
        assert.are.equal(2, #scheduled)
        scheduled[2]()
        assert.is_nil(vim.uv.fs_stat(old_token))
        assert.are.equal(2, #callbacks)
      end)
      vim.schedule = original_schedule
      vim.defer_fn = original_defer_fn
      assert.is_true(ok, err)
    end)
  end)

  it("does not publish a stale Doctor index after the resource cache changes", function()
    local root = helpers.tmpdir()
    local resource_file = root .. "/locales/ja/common.json"
    helpers.write_file(resource_file, '{"title":"current"}')
    local canonical_root = vim.uv.fs_realpath(root) or root
    local canonical_resource_file = vim.uv.fs_realpath(resource_file) or resource_file

    helpers.with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("title")' })
      vim.bo[buf].filetype = "typescript"

      local root_list = { { kind = "i18next", path = canonical_root .. "/locales" } }
      local cache_key = resources.cache_key(root_list, canonical_root)
      local cache = {
        key = cache_key,
        rpc_cache_key = cache_key,
        roots = root_list,
        index = {
          ja = {
            ["common:title"] = { value = "current", file = canonical_resource_file, priority = 30 },
          },
        },
        files = {},
        languages = { "ja" },
        errors = {},
        namespaces = { "common" },
        dirty = false,
        checked_at = 0,
        revision = 7,
      }
      resources.caches[cache_key] = cache

      local request_cb = nil
      local completed_ctx = nil
      local ok, err = pcall(function()
        rpc.request_sync = function(method)
          assert.are.equal("resource/resolveRoots", method)
          return { roots = root_list }, nil
        end
        rpc.request = function(_method, _params, cb)
          request_cb = cb
          return 601
        end
        vim.notify = function() end

        doctor.diagnose(buf, config_mod.setup({ primary_lang = "ja" }), function(_, _, ctx)
          completed_ctx = ctx
        end)
        assert.is_not_nil(request_cb)

        resources.mark_dirty(canonical_resource_file)
        assert.is_true(cache.dirty)
        assert.are.equal(8, cache.revision)

        request_cb(nil, {
          issues = {},
          used_keys = {},
          resource_index = {
            cache_key = cache_key,
            index = {
              ja = {
                ["common:title"] = { value = "stale", file = canonical_resource_file, priority = 30 },
              },
            },
            files = {},
            languages = { "ja" },
            errors = {},
            namespaces = { "common" },
          },
        })
        assert.is_true(vim.wait(500, function()
          return completed_ctx ~= nil
        end, 10))

        assert.is_true(resources.caches[cache_key] == cache)
        assert.is_true(completed_ctx.cache == cache)
        assert.are.equal("current", cache.index.ja["common:title"].value)
        assert.is_true(cache.dirty)
        assert.are.equal(8, cache.revision)
      end)
      resources.caches[cache_key] = nil
      assert.is_true(ok, err)
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
