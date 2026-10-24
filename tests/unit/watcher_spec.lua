local watcher = require("i18n-status.watcher")
local helpers = require("tests.helpers")

---@param opts? { fs_event_start_error?: string }
---@return table
local function install_fake_uv(opts)
  opts = opts or {}
  local fs_events = helpers.fake_fs_events({ start_error = opts.fs_event_start_error })
  local timers = helpers.fake_timers()
  return {
    fs_events = fs_events.handles,
    timers = timers.timers,
    open_timers = timers.open,
    restore = function()
      fs_events.restore()
      timers.restore()
    end,
  }
end

local flush_scheduled = helpers.flush_scheduled

describe("watcher", function()
  local fake_uv

  before_each(function()
    watcher.stop()
    watcher.watchers = {}
    watcher.refcounts = {}
  end)

  after_each(function()
    watcher.stop()
    watcher.watchers = {}
    watcher.refcounts = {}
    if fake_uv then
      fake_uv.restore()
      fake_uv = nil
    end
  end)

  describe("reference counting", function()
    it("increments refcount on start", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.are.equal(1, watcher.refcounts["key1"])
    end)

    it("increments refcount on multiple starts", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.are.equal(2, watcher.refcounts["key1"])
    end)

    it("skips refcount when skip_refcount is true", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
        skip_refcount = true,
      })
      assert.is_nil(watcher.refcounts["key1"])
    end)

    it("decrements refcount on stop_for_buffer", function()
      watcher.refcounts["key1"] = 2
      local stopped = watcher.stop_for_buffer("key1")
      assert.is_false(stopped)
      assert.are.equal(1, watcher.refcounts["key1"])
    end)

    it("stops watcher when refcount reaches zero", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.is_true(watcher.is_watching("key1"))

      local stopped = watcher.stop_for_buffer("key1")
      assert.is_true(stopped)
      assert.is_false(watcher.is_watching("key1"))
      assert.is_nil(watcher.refcounts["key1"])
    end)

    it("returns false for stop_for_buffer with nil key", function()
      local stopped = watcher.stop_for_buffer(nil)
      assert.is_false(stopped)
    end)

    it("returns false for stop_for_buffer with zero refcount", function()
      watcher.refcounts["key1"] = 0
      local stopped = watcher.stop_for_buffer("key1")
      assert.is_false(stopped)
    end)

    it("inc_refcount increments manually", function()
      watcher.inc_refcount("manual_key")
      assert.are.equal(1, watcher.refcounts["manual_key"])
      watcher.inc_refcount("manual_key")
      assert.are.equal(2, watcher.refcounts["manual_key"])
    end)
  end)

  describe("is_watching", function()
    it("returns false for unknown key", function()
      assert.is_false(watcher.is_watching("nonexistent"))
    end)

    it("returns true for active watcher", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.is_true(watcher.is_watching("key1"))
    end)

    it("returns false after stop", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.stop("key1")
      assert.is_false(watcher.is_watching("key1"))
    end)
  end)

  describe("stop", function()
    it("stops specific watcher by key", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.start("key2", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.stop("key1")
      assert.is_false(watcher.is_watching("key1"))
      assert.is_true(watcher.is_watching("key2"))
    end)

    it("stops all watchers when key is nil", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.start("key2", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.stop()
      assert.is_false(watcher.is_watching("key1"))
      assert.is_false(watcher.is_watching("key2"))
    end)
  end)

  describe("start", function()
    it("reuses the existing handles and routes events to the latest callback", function()
      local root = helpers.tmpdir()
      local file = root .. "/test.json"
      helpers.write_file(file, "{}")
      fake_uv = install_fake_uv()
      local first_events = {}
      local second_events = {}
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function(event)
          table.insert(first_events, event)
        end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.are.equal(1, #fake_uv.fs_events)
      local handle = fake_uv.fs_events[1]

      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function(event)
          table.insert(second_events, event)
        end,
        debounce_ms = 200,
        restart_fn = function() end,
      })

      assert.are.equal(1, #fake_uv.fs_events)
      assert.is_false(handle.closed)
      assert.is_true(watcher.is_watching("key1"))

      handle.cb(nil, "test.json", {})
      local timers = fake_uv.open_timers()
      assert.are.equal(1, #timers)
      assert.are.equal(200, timers[1].timeout)

      timers[1].cb()
      flush_scheduled()
      assert.are.same({}, first_events)
      assert.are.same({ { paths = { file }, needs_rebuild = false } }, second_events)
    end)

    it("recreates the handles when the watched paths change", function()
      local root = helpers.tmpdir()
      local file = root .. "/test.json"
      helpers.write_file(file, "{}")
      fake_uv = install_fake_uv()
      local opts = {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      }
      watcher.start("key1", opts)
      watcher.start("key1", vim.tbl_extend("force", opts, { paths = { root, file } }))

      assert.are.equal(3, #fake_uv.fs_events)
      assert.is_true(fake_uv.fs_events[1].closed)
      assert.are.equal(root, fake_uv.fs_events[2].path)
      assert.are.equal(file, fake_uv.fs_events[3].path)
      assert.is_true(watcher.is_watching("key1"))
    end)

    it("debounces rapid events into one notification with unique paths", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/a.json", "{}")
      helpers.write_file(root .. "/b.json", "{}")
      fake_uv = install_fake_uv()
      local events = {}
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function(event)
          table.insert(events, event)
        end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      local handle = fake_uv.fs_events[1]

      handle.cb(nil, "a.json", {})
      handle.cb(nil, "b.json", {})
      handle.cb(nil, "a.json", {})

      -- Each event restarts the debounce window, so only the latest timer stays open.
      assert.are.equal(3, #fake_uv.timers)
      local timers = fake_uv.open_timers()
      assert.are.equal(1, #timers)
      assert.are.equal(fake_uv.timers[3], timers[1])
      flush_scheduled()
      assert.are.same({}, events)

      timers[1].cb()
      flush_scheduled()
      assert.are.equal(1, #events)
      assert.is_false(events[1].needs_rebuild)
      table.sort(events[1].paths)
      assert.are.same({ root .. "/a.json", root .. "/b.json" }, events[1].paths)
    end)

    it("resolves file and directory events to the changed file paths", function()
      local root = helpers.tmpdir()
      local file = root .. "/test.json"
      local other = root .. "/other.json"
      helpers.write_file(file, "{}")
      helpers.write_file(other, "{}")
      fake_uv = install_fake_uv()
      local events = {}
      watcher.start("key1", {
        paths = { root, file },
        rescan_paths = {},
        on_change = function(event)
          table.insert(events, event)
        end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      local dir_handle = fake_uv.fs_events[1]
      local file_handle = fake_uv.fs_events[2]
      assert.are.equal(root, dir_handle.path)
      assert.are.equal(file, file_handle.path)

      -- A file watch reports its own basename; a directory watch reports the child name.
      file_handle.cb(nil, "test.json", {})
      dir_handle.cb(nil, "test.json", {})
      dir_handle.cb(nil, "other.json", {})
      fake_uv.open_timers()[1].cb()
      flush_scheduled()

      assert.are.equal(1, #events)
      table.sort(events[1].paths)
      assert.are.same({ other, file }, events[1].paths)
    end)

    it("requests a rebuild and restart when a rescan path changes", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/a.json", "{}")
      fake_uv = install_fake_uv()
      local events = {}
      local restarts = 0
      watcher.start("key1", {
        paths = { root },
        rescan_paths = { [root] = true },
        on_change = function(event)
          table.insert(events, event)
        end,
        debounce_ms = 100,
        restart_fn = function()
          restarts = restarts + 1
        end,
      })

      fake_uv.fs_events[1].cb(nil, "a.json", {})
      fake_uv.open_timers()[1].cb()
      flush_scheduled()

      assert.are.same({ { paths = {}, needs_rebuild = true } }, events)
      assert.are.equal(1, restarts)
    end)

    it("handles empty paths gracefully", function()
      watcher.start("key1", {
        paths = {},
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      assert.is_false(watcher.is_watching("key1"))
    end)

    it("falls back to polling when fs_event start fails", function()
      local root = helpers.tmpdir()
      local file = root .. "/test.json"
      helpers.write_file(file, "{}")
      fake_uv = install_fake_uv({ fs_event_start_error = "EMFILE" })

      local original_notify = vim.notify
      local fallback_notice = nil
      local events = {}
      local restarts = 0
      local ok, err = pcall(function()
        vim.notify = function(msg, _level)
          if msg:find("watcher fallback enabled", 1, true) then
            fallback_notice = msg
          end
        end

        watcher.start("key1", {
          paths = { root, file },
          rescan_paths = {},
          on_change = function(event)
            table.insert(events, event)
          end,
          debounce_ms = 100,
          restart_fn = function()
            restarts = restarts + 1
          end,
        })
        flush_scheduled()
      end)
      vim.notify = original_notify
      assert.is_true(ok, err)

      assert.is_not_nil(fallback_notice)
      assert.is_false(watcher.is_watching("key1"))
      assert.are.same({ { paths = {}, needs_rebuild = true } }, events)
      assert.are.equal(1, restarts)

      local timers = fake_uv.open_timers()
      assert.are.equal(1, #timers)
      local poll = timers[1]
      assert.are.equal(3000, poll.timeout)
      assert.are.equal(3000, poll.repeat_ms)

      -- A poll without changes stays silent.
      poll.cb()
      flush_scheduled()
      assert.are.equal(1, #events)

      helpers.write_file(file, '{"changed":true}')
      poll.cb()
      flush_scheduled()
      assert.are.equal(2, #events)
      assert.are.same({ paths = {}, needs_rebuild = true }, events[2])
      -- Restarts are throttled after the initial attempt.
      assert.are.equal(1, restarts)

      poll.cb()
      flush_scheduled()
      assert.are.equal(2, #events)
    end)
  end)
end)
