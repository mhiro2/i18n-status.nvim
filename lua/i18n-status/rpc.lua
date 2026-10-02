---@class I18nStatusRpc
local M = {}

local uv = vim.uv
local contract = require("i18n-status.core_contract")

local next_id = 1
local next_generation = 1
---@type integer|nil
local active_generation = nil
---@type uv_process_t|nil
local process = nil
---@type uv_pipe_t|nil
local stdin_pipe = nil
---@type uv_pipe_t|nil
local stdout_pipe = nil
---@type uv_pipe_t|nil
local stderr_pipe = nil

---@type table<integer, { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil, generation: integer }>
local pending = {}
---@type table<integer, { method: string, params: table, generation: integer }>
local queued_requests = {}
---@type table<integer, uv_timer_t>
local stop_kill_timers = {}

---@type table<string, fun(params: any)[]>
local notification_handlers = {}

local DEFAULT_TIMEOUT_MS = 30000
local HANDSHAKE_TIMEOUT_MS = 3000
local DOCTOR_TIMEOUT_MS = 120000
local FORCE_KILL_DELAY_MS = 3000

---@type string
local read_buffer = ""
local exit_hook_registered = false
local handling_stdin_read_error = false
local configured_binary_path = nil
local selected_binary_path = nil
local selected_binary_source = nil
local core_identity = nil
---@type "stopped"|"initializing"|"ready"|"failed"
local handshake_state = "stopped"
local startup_error = nil

local create_request

---@param handle any
local function close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    local closing = false
    if handle.is_closing then
      closing = handle:is_closing()
    end
    if not closing then
      handle:close()
    end
  end)
end

---@param timer uv_timer_t|nil
local function stop_and_close_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

---@param generation integer
local function clear_stop_kill_timer(generation)
  local timer = stop_kill_timers[generation]
  if timer then
    stop_and_close_timer(timer)
    stop_kill_timers[generation] = nil
  end
end

---@param id integer
---@param generation integer|nil
---@return { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil, generation: integer }|nil
local function take_pending(id, generation)
  local entry = pending[id]
  if not entry or (generation and entry.generation ~= generation) then
    return nil
  end
  pending[id] = nil
  queued_requests[id] = nil
  stop_and_close_timer(entry.timer)
  return entry
end

---@param generation integer
---@param message string
local function fail_generation_pending(generation, message)
  local callbacks = {}
  local ids = {}
  for id, entry in pairs(pending) do
    if entry.generation == generation then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local entry = take_pending(id, generation)
    if entry then
      callbacks[#callbacks + 1] = entry.cb
    end
  end
  for _, callback in ipairs(callbacks) do
    callback(message, nil)
  end
end

---@param line string
---@return string
local function prefixed_core_line(line)
  if line:find("^i18n%-status%-core:") then
    return line
  end
  return "i18n-status-core: " .. line
end

---@param path string
---@return boolean
local function is_executable_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file" and vim.fn.executable(path) == 1
end

---@return string|nil path
---@return string|nil source
local function find_binary()
  if configured_binary_path then
    return configured_binary_path, "core.path"
  end

  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local executable_name = vim.fn.has("win32") == 1 and "i18n-status-core.exe" or "i18n-status-core"
  local candidates = {
    { path = vim.fs.joinpath(plugin_root, "bin", executable_name), source = "plugin bin" },
    {
      path = vim.fs.joinpath(plugin_root, "rust", "target", "release", executable_name),
      source = "source release build",
    },
    {
      path = vim.fs.joinpath(plugin_root, "rust", "target", "debug", executable_name),
      source = "source debug build",
    },
  }

  for _, candidate in ipairs(candidates) do
    if is_executable_file(candidate.path) then
      return candidate.path, candidate.source
    end
  end

  return nil, nil
end

---@param core_config table|nil
function M.configure(core_config)
  local path = core_config and core_config.path or nil
  if path ~= nil then
    path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
  end

  if process and path ~= configured_binary_path then
    error("i18n-status: core.path cannot be changed after the core process starts")
  end

  if path ~= configured_binary_path then
    configured_binary_path = path
    selected_binary_path = nil
    selected_binary_source = nil
    core_identity = nil
    startup_error = nil
    if handshake_state == "failed" then
      handshake_state = "stopped"
    end
  end
end

---@return string|nil path
---@return string|nil source
function M.resolve_binary()
  return find_binary()
end

---@return table
function M.status()
  return {
    state = handshake_state,
    error = startup_error,
    binary_path = selected_binary_path,
    binary_source = selected_binary_source,
    core = core_identity and vim.deepcopy(core_identity) or nil,
    expected = {
      name = contract.core_name,
      version = contract.version,
      protocol_version = contract.protocol_version,
    },
  }
end

---@return boolean
function M.is_ready()
  return handshake_state == "ready" and process ~= nil
end

---@param target uv_process_t
---@param generation integer
---@param input uv_pipe_t|nil
---@param output uv_pipe_t|nil
---@param errors uv_pipe_t|nil
local function terminate_process(target, generation, input, output, errors)
  local shutdown = vim.json.encode({
    jsonrpc = "2.0",
    id = next_id,
    method = "shutdown",
    params = vim.empty_dict(),
  }) .. "\n"
  next_id = next_id + 1

  if input then
    pcall(function()
      input:write(shutdown)
    end)
  end
  pcall(function()
    target:kill(15)
  end)

  close_handle(input)
  close_handle(output)
  close_handle(errors)

  clear_stop_kill_timer(generation)
  local timer = uv.new_timer()
  if not timer then
    return
  end
  stop_kill_timers[generation] = timer
  pcall(function()
    timer:unref()
  end)
  timer:start(FORCE_KILL_DELAY_MS, 0, function()
    if stop_kill_timers[generation] ~= timer then
      return
    end
    pcall(function()
      target:kill(9)
    end)
    close_handle(target)
    clear_stop_kill_timer(generation)
  end)
end

---@param generation integer
---@return uv_process_t|nil, uv_pipe_t|nil, uv_pipe_t|nil, uv_pipe_t|nil
local function detach_generation(generation)
  if active_generation ~= generation then
    return nil, nil, nil, nil
  end
  local target = process
  local input = stdin_pipe
  local output = stdout_pipe
  local errors = stderr_pipe
  active_generation = nil
  process = nil
  stdin_pipe = nil
  stdout_pipe = nil
  stderr_pipe = nil
  read_buffer = ""
  handling_stdin_read_error = false
  return target, input, output, errors
end

---@param generation integer
---@param message string
---@param failed boolean
local function stop_generation(generation, message, failed)
  local target, input, output, errors = detach_generation(generation)
  if not target then
    return
  end

  core_identity = nil
  startup_error = failed and message or nil
  handshake_state = failed and "failed" or "stopped"
  terminate_process(target, generation, input, output, errors)
  fail_generation_pending(generation, message)
end

---@param message string
---@param generation integer
local function reject_core(message, generation)
  if active_generation ~= generation then
    return
  end
  local binary_path = selected_binary_path
  stop_generation(generation, message, true)
  vim.notify(
    "i18n-status: rejected core binary '"
      .. tostring(binary_path)
      .. "': "
      .. message
      .. ". Rebuild this checkout or set core.path to a matching binary, then restart Neovim.",
    vim.log.levels.ERROR
  )
end

---@param timeout_ms integer|nil
---@return boolean ready
---@return string|nil error
function M.ensure_ready(timeout_ms)
  if M.is_ready() then
    return true, nil
  end
  if handshake_state == "failed" then
    return false, startup_error or "core handshake failed"
  end
  if not process and not M.start() then
    return false, startup_error or "core process did not start"
  end

  local wait_ms = timeout_ms or HANDSHAKE_TIMEOUT_MS
  local generation = active_generation
  local completed = vim.wait(wait_ms, function()
    return active_generation ~= generation or handshake_state ~= "initializing"
  end, 10)
  if not completed and generation and active_generation == generation then
    reject_core("core handshake timed out after " .. wait_ms .. "ms", generation)
  end
  if M.is_ready() then
    return true, nil
  end
  return false, startup_error or "core handshake did not complete"
end

---@param data string
---@param generation integer
local function on_stdout(data, generation)
  if active_generation ~= generation then
    return
  end
  read_buffer = read_buffer .. data
  while true do
    local newline = read_buffer:find("\n")
    if not newline then
      break
    end
    local line = read_buffer:sub(1, newline - 1)
    read_buffer = read_buffer:sub(newline + 1)
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == "table" then
        if type(msg.id) == "number" then
          local entry = take_pending(msg.id, generation)
          if entry then
            vim.schedule(function()
              if active_generation ~= generation then
                entry.cb("core process was replaced before response delivery", nil)
              elseif msg.error then
                entry.cb(msg.error.message or "rpc error", nil)
              else
                entry.cb(nil, msg.result)
              end
            end)
          end
        elseif msg.method then
          local handlers = notification_handlers[msg.method]
          if handlers then
            for _, handler in ipairs(handlers) do
              local handler_fn = handler
              local params = msg.params
              vim.schedule(function()
                if active_generation == generation then
                  handler_fn(params)
                end
              end)
            end
          end
        end
      end
    end
  end
end

---@param data string
---@param generation integer
local function on_stderr(data, generation)
  if active_generation ~= generation then
    return
  end
  for line in data:gmatch("[^\n]+") do
    if line:find("read error: failed to read from stdin", 1, true) then
      if not handling_stdin_read_error then
        handling_stdin_read_error = true
        vim.schedule(function()
          if active_generation == generation then
            stop_generation(generation, "core stdin closed", false)
          end
        end)
      end
      return
    end
    if line:find("error") or line:find("fatal") then
      vim.schedule(function()
        if active_generation == generation then
          vim.notify(prefixed_core_line(line), vim.log.levels.ERROR)
        end
      end)
    end
  end
end

function M.is_running()
  return process ~= nil
end

---@param id integer
---@param method string
---@param params table
---@param generation integer
---@return boolean
local function write_request(id, method, params, generation)
  local entry = pending[id]
  if not entry or entry.generation ~= generation or active_generation ~= generation then
    return false
  end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }) .. "\n"

  local input = stdin_pipe
  if not input then
    stop_generation(generation, "stdin not available", false)
    return false
  end

  local write_ok, write_err = pcall(function()
    input:write(msg, function(err)
      if err then
        vim.schedule(function()
          if active_generation == generation then
            stop_generation(generation, "write failed: " .. tostring(err), false)
          end
        end)
      end
    end)
  end)
  if not write_ok then
    stop_generation(generation, "write failed: " .. tostring(write_err), false)
    return false
  end
  return true
end

---@param generation integer
local function flush_queued_requests(generation)
  local ids = {}
  for id, request in pairs(queued_requests) do
    if request.generation == generation then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local request = queued_requests[id]
    queued_requests[id] = nil
    if request and pending[id] then
      write_request(id, request.method, request.params, generation)
    end
  end
end

local function ensure_exit_hook()
  if exit_hook_registered then
    return
  end
  exit_hook_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(function()
        M.stop()
      end)
    end,
  })
end

function M.start()
  if process then
    return handshake_state ~= "failed"
  end
  if handshake_state == "failed" then
    return false
  end

  ensure_exit_hook()

  local binary, binary_source = find_binary()
  if not binary then
    startup_error = "matching core binary not found"
    vim.notify(
      "i18n-status: matching core binary not found. Run 'bash ./scripts/download-binary.sh' or set core.path explicitly",
      vim.log.levels.ERROR
    )
    return false
  end
  if not is_executable_file(binary) then
    startup_error = "configured core binary is not an executable file: " .. binary
    vim.notify("i18n-status: " .. startup_error, vim.log.levels.ERROR)
    return false
  end

  local generation = next_generation
  next_generation = next_generation + 1
  local input = uv.new_pipe(false)
  local output = uv.new_pipe(false)
  local errors = uv.new_pipe(false)

  selected_binary_path = binary
  selected_binary_source = binary_source
  startup_error = nil
  core_identity = nil
  handshake_state = "initializing"
  active_generation = generation
  stdin_pipe = input
  stdout_pipe = output
  stderr_pipe = errors

  local handle, pid
  handle, pid = uv.spawn(binary, {
    stdio = { input, output, errors },
    detached = false,
  }, function(code)
    vim.schedule(function()
      clear_stop_kill_timer(generation)
      close_handle(input)
      close_handle(output)
      close_handle(errors)
      close_handle(handle)

      if active_generation ~= generation then
        return
      end
      local exited_during_handshake = handshake_state == "initializing"
      detach_generation(generation)
      core_identity = nil
      handshake_state = "stopped"
      startup_error = exited_during_handshake and "core process exited during handshake (code=" .. tostring(code) .. ")"
        or nil
      fail_generation_pending(generation, "process exited (code=" .. tostring(code) .. ")")
    end)
  end)

  if not handle then
    detach_generation(generation)
    handshake_state = "stopped"
    startup_error = "failed to start binary: " .. tostring(pid)
    close_handle(input)
    close_handle(output)
    close_handle(errors)
    vim.notify("i18n-status: " .. startup_error, vim.log.levels.ERROR)
    return false
  end

  process = handle
  pcall(function()
    handle:unref()
  end)
  pcall(function()
    input:unref()
  end)
  pcall(function()
    output:unref()
  end)
  pcall(function()
    errors:unref()
  end)

  output:read_start(function(err, data)
    if not err and data then
      on_stdout(data, generation)
    end
  end)

  errors:read_start(function(err, data)
    if not err and data then
      on_stderr(data, generation)
    end
  end)

  create_request("initialize", contract.initialize_params(), function(err, result)
    if active_generation ~= generation or handshake_state ~= "initializing" then
      return
    end
    if err then
      reject_core("core handshake failed: " .. tostring(err), generation)
      return
    end
    local validation_error = contract.validate_initialize_result(result)
    if validation_error then
      reject_core(validation_error, generation)
      return
    end

    core_identity = {
      name = result.core.name,
      version = result.core.version,
      protocol_version = result.protocol_version,
    }
    startup_error = nil
    handshake_state = "ready"
    flush_queued_requests(generation)
  end, { timeout_ms = HANDSHAKE_TIMEOUT_MS }, true, generation)

  return true
end

function M.stop()
  local generation = active_generation
  if not generation or not process then
    return
  end
  stop_generation(generation, "core process stopped", false)
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: any)
---@param opts? { timeout_ms?: integer }
---@param send_now boolean|nil
---@param generation integer
---@return integer|nil request_id
create_request = function(method, params, cb, opts, send_now, generation)
  if active_generation ~= generation then
    cb("core process is not active", nil)
    return nil
  end

  local id = next_id
  next_id = next_id + 1
  local default_timeout_ms = method == "doctor/diagnose" and DOCTOR_TIMEOUT_MS or DEFAULT_TIMEOUT_MS
  local timeout_ms = (opts and opts.timeout_ms) or default_timeout_ms

  local timer = uv.new_timer()
  pcall(function()
    timer:unref()
  end)
  timer:start(timeout_ms, 0, function()
    local entry = take_pending(id, generation)
    if entry then
      vim.schedule(function()
        entry.cb("timeout after " .. timeout_ms .. "ms", nil)
      end)
    end
  end)

  pending[id] = { cb = cb, timer = timer, generation = generation }
  if send_now then
    if not write_request(id, method, params, generation) then
      return nil
    end
  else
    queued_requests[id] = { method = method, params = params, generation = generation }
  end
  return id
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: any)
---@param opts? { timeout_ms?: integer }
---@return integer|nil request_id
function M.request(method, params, cb, opts)
  if handshake_state == "failed" then
    cb(startup_error or "core handshake failed", nil)
    return nil
  end
  if not process and not M.start() then
    cb(startup_error or "process not running", nil)
    return nil
  end

  local generation = active_generation
  if not generation then
    cb("core process is not active", nil)
    return nil
  end
  return create_request(method, params, cb, opts, handshake_state == "ready", generation)
end

---@param method string
---@param params table
---@param timeout_ms? integer
---@return any|nil result
---@return string|nil error
function M.request_sync(method, params, timeout_ms)
  timeout_ms = timeout_ms or DEFAULT_TIMEOUT_MS
  local result, err
  local done = false
  local request_id = M.request(method, params, function(callback_error, callback_result)
    err = callback_error
    result = callback_result
    done = true
  end, { timeout_ms = timeout_ms })

  local ok = vim.wait(timeout_ms, function()
    return done
  end, 10)
  if not ok then
    if request_id then
      take_pending(request_id)
    end
    return nil, "sync request timeout"
  end
  return result, err
end

---@param method string
---@param params table
function M.notify(method, params)
  if not M.is_ready() or not stdin_pipe then
    return
  end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }) .. "\n"
  pcall(function()
    stdin_pipe:write(msg)
  end)
end

---@param method string
---@param cb fun(params: any)
function M.on_notification(method, cb)
  if not notification_handlers[method] then
    notification_handlers[method] = {}
  end
  table.insert(notification_handlers[method], cb)
end

---@param method string
---@param cb fun(params: any)
function M.off_notification(method, cb)
  local handlers = notification_handlers[method]
  if not handlers then
    return
  end
  for i = #handlers, 1, -1 do
    if handlers[i] == cb then
      table.remove(handlers, i)
    end
  end
end

return M
