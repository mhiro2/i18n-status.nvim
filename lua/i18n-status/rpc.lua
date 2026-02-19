---@class I18nStatusRpc
local M = {}

local uv = vim.uv

---@type uv_process_t|nil
local process = nil
---@type uv_pipe_t|nil
local stdin_pipe = nil
---@type uv_pipe_t|nil
local stdout_pipe = nil
---@type uv_pipe_t|nil
local stderr_pipe = nil

local next_id = 1
---@type table<integer, { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil }>
local pending = {}

---@type table<string, fun(params: any)[]>
local notification_handlers = {}

local DEFAULT_TIMEOUT_MS = 30000
local DOCTOR_TIMEOUT_MS = 120000
local FORCE_KILL_DELAY_MS = 3000

---@type string
local read_buffer = ""
local exit_hook_registered = false
---@type uv_timer_t|nil
local stop_kill_timer = nil

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

---@param id integer
---@return { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil }|nil
local function take_pending(id)
  local entry = pending[id]
  if not entry then
    return nil
  end
  pending[id] = nil
  stop_and_close_timer(entry.timer)
  return entry
end

local function clear_stop_kill_timer()
  if stop_kill_timer then
    pcall(function()
      if not stop_kill_timer:is_closing() then
        stop_kill_timer:stop()
        stop_kill_timer:close()
      end
    end)
    stop_kill_timer = nil
  end
end

---@return string|nil
local function find_binary()
  -- 1. Check plugin directory
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local candidates = {
    vim.fs.joinpath(plugin_root, "rust", "target", "release", "i18n-status-core"),
    vim.fs.joinpath(plugin_root, "rust", "target", "debug", "i18n-status-core"),
    vim.fs.joinpath(plugin_root, "bin", "i18n-status-core"),
  }

  -- 2. Check standard data directory
  local data_dir = vim.fn.stdpath("data")
  if data_dir then
    table.insert(candidates, vim.fs.joinpath(data_dir, "i18n-status", "bin", "i18n-status-core"))
  end

  for _, path in ipairs(candidates) do
    if uv.fs_stat(path) then
      return path
    end
  end

  -- 3. Check PATH
  local found = vim.fn.exepath("i18n-status-core")
  if found and found ~= "" then
    return found
  end

  return nil
end

---@param data string
local function on_stdout(data)
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
        if msg.id ~= nil then
          -- Response
          local id = msg.id
          if type(id) == "number" then
            local entry = take_pending(id)
            if entry then
              vim.schedule(function()
                if msg.error then
                  entry.cb(msg.error.message or "rpc error", nil)
                else
                  entry.cb(nil, msg.result)
                end
              end)
            end
          end
        elseif msg.method then
          -- Notification
          local handlers = notification_handlers[msg.method]
          if handlers then
            for _, handler in ipairs(handlers) do
              local handler_fn = handler
              local params = msg.params
              vim.schedule(function()
                handler_fn(params)
              end)
            end
          end
        end
      end
    end
  end
end

---@param data string
local function on_stderr(data)
  -- Log to stderr for debugging
  for line in data:gmatch("[^\n]+") do
    -- Only show warnings/errors to user, suppress info messages
    if line:find("error") or line:find("fatal") then
      vim.schedule(function()
        vim.notify("i18n-status-core: " .. line, vim.log.levels.ERROR)
      end)
    end
  end
end

function M.is_running()
  return process ~= nil
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
    return true
  end

  ensure_exit_hook()

  local binary = find_binary()
  if not binary then
    vim.notify(
      "i18n-status: binary not found. Run :checkhealth i18n-status or build with 'cd rust && cargo build --release'",
      vim.log.levels.ERROR
    )
    return false
  end

  stdin_pipe = uv.new_pipe(false)
  stdout_pipe = uv.new_pipe(false)
  stderr_pipe = uv.new_pipe(false)

  local handle, pid
  handle, pid = uv.spawn(binary, {
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    detached = false,
  }, function(code)
    -- on exit
    vim.schedule(function()
      clear_stop_kill_timer()
      process = nil
      -- Fail all pending requests
      for id, entry in pairs(pending) do
        pending[id] = nil
        stop_and_close_timer(entry.timer)
        entry.cb("process exited (code=" .. tostring(code) .. ")", nil)
      end
      read_buffer = ""
      -- Close handles
      if stdin_pipe and not stdin_pipe:is_closing() then
        stdin_pipe:close()
      end
      if stdout_pipe and not stdout_pipe:is_closing() then
        stdout_pipe:close()
      end
      if stderr_pipe and not stderr_pipe:is_closing() then
        stderr_pipe:close()
      end
      stdin_pipe = nil
      stdout_pipe = nil
      stderr_pipe = nil
    end)
  end)

  if not handle then
    vim.notify("i18n-status: failed to start binary: " .. tostring(pid), vim.log.levels.ERROR)
    if stdin_pipe then
      stdin_pipe:close()
    end
    if stdout_pipe then
      stdout_pipe:close()
    end
    if stderr_pipe then
      stderr_pipe:close()
    end
    stdin_pipe = nil
    stdout_pipe = nil
    stderr_pipe = nil
    return false
  end

  process = handle
  pcall(function()
    process:unref()
  end)
  pcall(function()
    stdin_pipe:unref()
  end)
  pcall(function()
    stdout_pipe:unref()
  end)
  pcall(function()
    stderr_pipe:unref()
  end)

  stdout_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      on_stdout(data)
    end
  end)

  stderr_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      on_stderr(data)
    end
  end)

  -- Send initialize
  M.request("initialize", {}, function() end)

  return true
end

function M.stop()
  if not process then
    return
  end

  -- Send shutdown, then close
  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = next_id,
    method = "shutdown",
    params = vim.empty_dict(),
  }) .. "\n"
  next_id = next_id + 1

  if stdin_pipe then
    pcall(function()
      stdin_pipe:write(msg)
    end)
  end

  local target = process

  pcall(function()
    target:kill(15) -- SIGTERM
  end)

  clear_stop_kill_timer()
  stop_kill_timer = uv.new_timer()
  if stop_kill_timer then
    pcall(function()
      stop_kill_timer:unref()
    end)
    stop_kill_timer:start(FORCE_KILL_DELAY_MS, 0, function()
      if process ~= target then
        clear_stop_kill_timer()
        return
      end
      pcall(function()
        target:kill(9) -- SIGKILL
      end)
      clear_stop_kill_timer()
    end)
  end
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: any)
---@param opts? { timeout_ms?: integer }
---@return integer|nil request_id
function M.request(method, params, cb, opts)
  if not process then
    if not M.start() then
      cb("process not running", nil)
      return nil
    end
  end

  local id = next_id
  next_id = next_id + 1

  local timeout_ms = (opts and opts.timeout_ms) or DEFAULT_TIMEOUT_MS
  if method == "doctor/diagnose" then
    timeout_ms = DOCTOR_TIMEOUT_MS
  end

  local timer = uv.new_timer()
  pcall(function()
    timer:unref()
  end)
  timer:start(timeout_ms, 0, function()
    local entry = take_pending(id)
    if entry then
      vim.schedule(function()
        entry.cb("timeout after " .. timeout_ms .. "ms", nil)
      end)
    end
  end)

  pending[id] = { cb = cb, timer = timer }

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }) .. "\n"

  if stdin_pipe then
    stdin_pipe:write(msg)
  else
    take_pending(id)
    cb("stdin not available", nil)
    return nil
  end
  return id
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
  local request_id = M.request(method, params, function(e, r)
    err = e
    result = r
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
  if not process or not stdin_pipe then
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
