local watcher = require("i18n-status.watcher")
local helpers = require("tests.helpers")

describe("watcher", function()
  before_each(function()
    watcher.stop()
    watcher.watchers = {}
    watcher.refcounts = {}
  end)

  after_each(function()
    watcher.stop()
    watcher.watchers = {}
    watcher.refcounts = {}
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

  describe("signature", function()
    it("returns nil for unknown key", function()
      assert.is_nil(watcher.signature("nonexistent"))
    end)

    it("returns signature for active watcher", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root, root .. "/test.json" },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      local sig = watcher.signature("key1")
      assert.is_not_nil(sig)
      assert.are.equal(root .. "|" .. root .. "/test.json", sig)
    end)

    it("set_signature updates watcher signature", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = function() end,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      watcher.set_signature("key1", "new_signature")
      assert.are.equal("new_signature", watcher.signature("key1"))
    end)

    it("set_signature is no-op for unknown key", function()
      watcher.set_signature("nonexistent", "sig")
      assert.is_nil(watcher.signature("nonexistent"))
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
    it("reuses existing watcher when paths unchanged", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/test.json", "{}")
      local cb1 = function() end
      local cb2 = function() end
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = cb1,
        debounce_ms = 100,
        restart_fn = function() end,
      })
      -- Start again with same paths but different callback
      watcher.start("key1", {
        paths = { root },
        rescan_paths = {},
        on_change = cb2,
        debounce_ms = 200,
        restart_fn = function() end,
      })
      -- Should still be watching (reused, not recreated)
      assert.is_true(watcher.is_watching("key1"))
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
      helpers.write_file(root .. "/test.json", "{}")

      local original_new_fs_event = vim.uv.new_fs_event
      local original_notify = vim.notify
      local fallback_notice = nil
      local events = {}
      local ok, err = pcall(function()
        vim.uv.new_fs_event = function()
          return {
            start = function()
              return nil, "EMFILE"
            end,
            stop = function() end,
            close = function() end,
            is_closing = function()
              return false
            end,
            unref = function() end,
          }
        end
        vim.notify = function(msg, _level)
          if msg:find("watcher fallback enabled", 1, true) then
            fallback_notice = msg
          end
        end

        watcher.start("key1", {
          paths = { root },
          rescan_paths = {},
          on_change = function(event)
            table.insert(events, event)
          end,
          debounce_ms = 100,
          restart_fn = function() end,
        })

        local triggered = vim.wait(500, function()
          return #events > 0
        end, 10)
        assert.is_true(triggered)
      end)
      vim.notify = original_notify
      vim.uv.new_fs_event = original_new_fs_event
      assert.is_true(ok, err)
      assert.is_not_nil(fallback_notice)
      assert.is_true(events[1].needs_rebuild)
      assert.are.same({}, events[1].paths)
    end)
  end)
end)
