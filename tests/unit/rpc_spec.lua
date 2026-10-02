local contract = require("i18n-status.core_contract")

describe("rpc", function()
  local uv
  local original_new_pipe
  local original_spawn
  local original_new_timer
  local original_fs_stat
  local original_has
  local original_executable
  local original_wait
  local original_notify

  local all_pipes
  local auto_initialize
  local initialize_result
  local kill_signals
  local rpc
  local spawn_records
  local spawned_binary
  local timers
  local write_error
  local writes

  local function record_for_stdin(input)
    for _, record in ipairs(spawn_records) do
      if record.pipes[1] == input then
        return record
      end
    end
    return nil
  end

  local function emit_response(record, request, result, err)
    local response = {
      jsonrpc = "2.0",
      id = request.id,
      result = result,
      error = err,
    }
    record.pipes[2].on_read(nil, vim.json.encode(response) .. "\n")
  end

  local function make_pipe()
    local pipe = {
      closed = false,
      on_read = nil,
    }
    function pipe:unref() end
    function pipe:read_start(cb)
      self.on_read = cb
    end
    function pipe:write(data, cb)
      local ok, request = pcall(vim.json.decode, data)
      if ok and type(request) == "table" then
        writes[#writes + 1] = { request = request, pipe = self }
        local record = record_for_stdin(self)
        if request.method == "initialize" and auto_initialize and not write_error then
          vim.schedule(function()
            emit_response(record, request, vim.deepcopy(initialize_result), nil)
          end)
        end
      end
      if cb then
        cb(write_error)
      end
    end
    function pipe:close()
      self.closed = true
    end
    function pipe:is_closing()
      return self.closed
    end
    all_pipes[#all_pipes + 1] = pipe
    return pipe
  end

  before_each(function()
    uv = vim.uv
    original_new_pipe = uv.new_pipe
    original_spawn = uv.spawn
    original_new_timer = uv.new_timer
    original_fs_stat = uv.fs_stat
    original_has = vim.fn.has
    original_executable = vim.fn.executable
    original_wait = vim.wait
    original_notify = vim.notify

    all_pipes = {}
    auto_initialize = true
    initialize_result = {
      core = { name = contract.core_name, version = contract.version },
      protocol_version = contract.protocol_version,
    }
    kill_signals = {}
    spawn_records = {}
    spawned_binary = nil
    timers = {}
    write_error = nil
    writes = {}
    vim.notify = function() end

    uv.new_pipe = function()
      return make_pipe()
    end
    uv.fs_stat = function()
      return { type = "file" }
    end
    uv.new_timer = function()
      local timer = {
        closed = false,
        delay = nil,
        cb = nil,
      }
      function timer:unref() end
      function timer:start(delay, _repeat_ms, cb)
        self.delay = delay
        self.cb = cb
      end
      function timer:stop() end
      function timer:close()
        self.closed = true
      end
      function timer:is_closing()
        return self.closed
      end
      timers[#timers + 1] = timer
      return timer
    end
    uv.spawn = function(binary, opts, on_exit)
      spawned_binary = binary
      local record = {
        exit_cb = on_exit,
        pipes = opts.stdio,
      }
      local handle = {
        closed = false,
      }
      function handle:unref() end
      function handle:kill(signal)
        kill_signals[#kill_signals + 1] = { record = record, signal = signal }
      end
      function handle:close()
        self.closed = true
      end
      function handle:is_closing()
        return self.closed
      end
      record.handle = handle
      spawn_records[#spawn_records + 1] = record
      return handle, 12000 + #spawn_records
    end

    package.loaded["i18n-status.rpc"] = nil
    rpc = require("i18n-status.rpc")
    rpc.configure({ path = "/bin/sh" })
  end)

  after_each(function()
    for _, record in ipairs(spawn_records) do
      if not record.handle.closed then
        record.exit_cb(0)
      end
    end
    vim.wait(20, function()
      return false
    end, 1)

    uv.new_pipe = original_new_pipe
    uv.spawn = original_spawn
    uv.new_timer = original_new_timer
    uv.fs_stat = original_fs_stat
    vim.fn.has = original_has
    vim.fn.executable = original_executable
    vim.wait = original_wait
    vim.notify = original_notify
    package.loaded["i18n-status.rpc"] = nil
  end)

  it("delays SIGKILL after SIGTERM in stop()", function()
    assert.is_true(rpc.start())

    rpc.stop()

    assert.are.equal(15, kill_signals[1].signal)
    local force_kill_timer = nil
    for _, timer in ipairs(timers) do
      if timer.delay == 3000 and not timer.closed then
        force_kill_timer = timer
        break
      end
    end
    assert.is_not_nil(force_kill_timer)

    force_kill_timer.cb()
    assert.are.equal(9, kill_signals[2].signal)
  end)

  it("honors a Doctor-specific deadline without changing interactive defaults", function()
    assert.is_true(rpc.start())

    rpc.request("doctor/diagnose", {}, function() end, { timeout_ms = 4321 })
    assert.are.equal(4321, timers[#timers].delay)

    rpc.request("scan/extract", {}, function() end)
    assert.are.equal(30000, timers[#timers].delay)
  end)

  it("does not send a queued Doctor request after its deadline expires", function()
    auto_initialize = false
    assert.is_true(rpc.start())

    local callback_error = nil
    rpc.request("doctor/diagnose", {}, function(err)
      callback_error = err
    end, { timeout_ms = 4321 })

    assert.are.equal(1, #writes)
    assert.are.equal("initialize", writes[1].request.method)
    local request_timer = timers[#timers]
    assert.are.equal(4321, request_timer.delay)

    request_timer.cb()
    assert.is_true(vim.wait(100, function()
      return callback_error ~= nil
    end, 1))
    assert.are.equal("timeout after 4321ms", callback_error)
    assert.is_true(request_timer.closed)

    emit_response(spawn_records[1], writes[1].request, initialize_result, nil)
    assert.is_true(vim.wait(100, function()
      return rpc.is_ready()
    end, 1))
    assert.are.equal(1, #writes)
  end)

  it("queues requests until the exact source contract handshake succeeds", function()
    auto_initialize = false
    assert.is_true(rpc.start())

    local callback_result = nil
    rpc.request("scan/extract", {}, function(err, result)
      callback_result = { err = err, result = result }
    end)

    assert.are.equal(1, #writes)
    assert.are.equal("initialize", writes[1].request.method)
    assert.are.same({ name = contract.client_name, version = contract.version }, writes[1].request.params.client)
    assert.are.equal(contract.protocol_version, writes[1].request.params.protocol_version)

    emit_response(spawn_records[1], writes[1].request, initialize_result, nil)
    vim.wait(100, function()
      return #writes == 2
    end, 1)

    assert.are.equal("scan/extract", writes[2].request.method)
    assert.is_true(rpc.is_ready())
    assert.is_nil(callback_result)
  end)

  it("rejects a core from a different revision and fails queued requests", function()
    auto_initialize = false
    assert.is_true(rpc.start())

    local callback_error = nil
    rpc.request("scan/extract", {}, function(err)
      callback_error = err
    end)

    initialize_result.core.version = "9.9.9"
    emit_response(spawn_records[1], writes[1].request, initialize_result, nil)
    vim.wait(100, function()
      return callback_error ~= nil
    end, 1)

    assert.is_truthy(callback_error:find("core version mismatch", 1, true))
    assert.are.equal(15, kill_signals[1].signal)
    assert.are.equal("failed", rpc.status().state)
    assert.is_false(rpc.is_ready())
  end)

  it("cleans an exited generation before callbacks and permits an immediate restart", function()
    auto_initialize = false
    assert.is_true(rpc.start())
    local first = spawn_records[1]
    local restarted = false
    rpc.request("scan/extract", {}, function(err)
      assert.are.equal("process exited (code=7)", err)
      assert.is_false(rpc.is_running())
      assert.is_true(first.handle.closed)
      restarted = rpc.start()
    end)

    first.exit_cb(7)
    vim.wait(100, function()
      return restarted
    end, 1)

    assert.is_true(restarted)
    assert.are.equal(2, #spawn_records)
    assert.is_true(rpc.is_running())
  end)

  it("ignores an old exit callback after a new generation starts", function()
    auto_initialize = false
    assert.is_true(rpc.start())
    local first = spawn_records[1]
    rpc.stop()
    assert.is_true(rpc.start())
    local second = spawn_records[2]

    first.exit_cb(0)
    vim.wait(50, function()
      return first.handle.closed
    end, 1)

    assert.is_true(first.handle.closed)
    assert.is_false(second.handle.closed)
    assert.is_true(rpc.is_running())
    assert.are.equal("initializing", rpc.status().state)
    assert.is_false(second.pipes[1].closed)
  end)

  it("fails closed and terminates queued work when the handshake wait times out", function()
    auto_initialize = false
    assert.is_true(rpc.start())
    local callback_error = nil
    rpc.request("scan/extract", {}, function(err)
      callback_error = err
    end)
    vim.wait = function()
      return false
    end

    local ready, err = rpc.ensure_ready(42)

    assert.is_false(ready)
    assert.is_truthy(err:find("timed out after 42ms", 1, true))
    assert.are.equal(err, callback_error)
    assert.are.equal("failed", rpc.status().state)
    assert.is_false(rpc.is_running())
    assert.are.equal(15, kill_signals[1].signal)
  end)

  it("uses only the explicitly configured external binary", function()
    assert.is_true(rpc.start())
    assert.are.equal("/bin/sh", spawned_binary)
    local path, source = rpc.resolve_binary()
    assert.are.equal("/bin/sh", path)
    assert.are.equal("core.path", source)
  end)

  it("prefers the managed plugin binary over stale source builds", function()
    rpc.configure({})
    vim.fn.has = function(feature)
      if feature == "win32" then
        return 0
      end
      return original_has(feature)
    end
    vim.fn.executable = function()
      return 1
    end

    local path, source = rpc.resolve_binary()

    assert.is_truthy(path:find("bin/i18n-status-core", 1, true))
    assert.are.equal("plugin bin", source)
  end)

  it("selects the Windows executable name for managed binaries", function()
    rpc.configure({})
    vim.fn.has = function(feature)
      if feature == "win32" then
        return 1
      end
      return original_has(feature)
    end
    vim.fn.executable = function(path)
      return vim.endswith(path, ".exe") and 1 or 0
    end

    local path, source = rpc.resolve_binary()

    assert.is_truthy(path:find("bin/i18n-status-core.exe", 1, true))
    assert.are.equal("plugin bin", source)
  end)

  it("cleans a pending sync request when vim.wait times out first", function()
    assert.is_true(rpc.start())
    vim.wait = function()
      return false
    end

    local result, err =
      rpc.request_sync("scan/extract", { source = "", lang = "tsx", fallback_namespace = "common" }, 1234)
    assert.is_nil(result)
    assert.are.equal("sync request timeout", err)

    local request_timer = nil
    for _, timer in ipairs(timers) do
      if timer.delay == 1234 then
        request_timer = timer
        break
      end
    end
    assert.is_not_nil(request_timer)
    assert.is_true(request_timer.closed)
  end)

  it("stops the owning generation on a stdin read error", function()
    assert.is_true(rpc.start())
    local errors = spawn_records[1].pipes[3]
    errors.on_read(nil, "i18n-status-core: read error: failed to read from stdin\n")
    vim.wait(50, function()
      return #kill_signals >= 1
    end, 1)

    assert.are.equal(15, kill_signals[1].signal)
    assert.is_false(rpc.is_running())
  end)

  it("fails a sync request immediately when stdin write fails", function()
    assert.is_true(rpc.start())
    write_error = "broken pipe"

    local result, err =
      rpc.request_sync("scan/extract", { source = "", lang = "tsx", fallback_namespace = "common" }, 1234)

    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.is_true(err:find("write failed", 1, true) ~= nil)
    assert.are.equal(15, kill_signals[1].signal)
  end)
end)
