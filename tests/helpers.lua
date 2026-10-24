---@class TestHelpers
local M = {}

local uv = vim.uv

---@return string
function M.tmpdir()
  local dir = vim.fn.tempname()
  uv.fs_mkdir(dir, 448)
  return dir
end

---@param path string
---@param content string
function M.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = uv.fs_open(path, "w", 420)
  assert(fd, "failed to open file")
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
end

---@param dir string
---@param fn fun()
function M.with_cwd(dir, fn)
  local cwd = vim.fn.getcwd()
  vim.fn.chdir(dir)
  local ok, err = pcall(fn)
  vim.fn.chdir(cwd)
  if not ok then
    error(err)
  end
end

---@param path string
---@return string
function M.read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  assert(fd, "failed to open file")
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

---@return table
local function fake_handle()
  local handle = { closed = false }
  function handle:stop() end
  function handle:close()
    self.closed = true
  end
  function handle:is_closing()
    return self.closed
  end
  function handle:unref() end
  return handle
end

---Replace vim.uv.new_fs_event with handles that never receive OS events.
---Each fake records its watched path and callback so a test can fire events itself.
---@param opts? { start_error?: string }
---@return { handles: table[], find: fun(path: string): table|nil, restore: fun() }
function M.fake_fs_events(opts)
  opts = opts or {}
  local original = uv.new_fs_event
  local fake = { handles = {} }

  uv.new_fs_event = function()
    local handle = fake_handle()
    function handle:start(path, _flags, cb)
      self.path = path
      self.cb = cb
      if opts.start_error then
        return nil, opts.start_error
      end
      return 0
    end
    table.insert(fake.handles, handle)
    return handle
  end

  function fake.find(path)
    for _, handle in ipairs(fake.handles) do
      if handle.path == path and not handle.closed then
        return handle
      end
    end
    return nil
  end

  function fake.restore()
    uv.new_fs_event = original
  end

  return fake
end

---Replace vim.uv.new_timer with timers that only fire when a test calls their callback.
---@return { timers: table[], open: fun(): table[], restore: fun() }
function M.fake_timers()
  local original = uv.new_timer
  local fake = { timers = {} }

  uv.new_timer = function()
    local timer = fake_handle()
    function timer:start(timeout, repeat_ms, cb)
      self.timeout = timeout
      self.repeat_ms = repeat_ms
      self.cb = cb
      return 0
    end
    table.insert(fake.timers, timer)
    return timer
  end

  function fake.open()
    local open = {}
    for _, timer in ipairs(fake.timers) do
      if not timer.closed then
        open[#open + 1] = timer
      end
    end
    return open
  end

  function fake.restore()
    uv.new_timer = original
  end

  return fake
end

---Run every callback scheduled so far.
function M.flush_scheduled()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(
    vim.wait(1000, function()
      return done
    end, 5),
    "scheduled callbacks did not run"
  )
end

return M
