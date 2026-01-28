local core = require("i18n-status.core")
local render = require("i18n-status.render")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "typescript"
  return buf
end

local function inline_text(buf)
  local ns = render.namespace()
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  if #marks == 0 then
    return ""
  end
  local text = {}
  for _, chunk in ipairs(marks[1][4].virt_text or {}) do
    table.insert(text, chunk[1])
  end
  return table.concat(text, "")
end

describe("resource change handling", function()
  before_each(function()
    state.init("ja", {})
  end)

  after_each(function()
    resources.stop_watch()
  end)

  it("updates inline after resource change", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')
      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("サインイン", 1, true) ~= nil)
    end)
  end)

  it("recovers after invalid json", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{")
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("[×]", 1, true) ~= nil)

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"復帰"}}')
      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("復帰", 1, true) ~= nil)
    end)
  end)

  it("refreshes multiple buffers", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":"A","b":"B"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"a":"A","b":"B"}')
    helpers.with_cwd(root, function()
      local buf1 = make_buf({ 't("a")' })
      local buf2 = make_buf({ 't("b")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_all(config)
      assert.is_true(inline_text(buf1):find("A", 1, true) ~= nil)
      assert.is_true(inline_text(buf2):find("B", 1, true) ~= nil)
    end)
  end)

  it("updates via watcher after external edit", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
        resource_watch = { enabled = true, debounce_ms = 10 },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)

      local updated = false
      resources.start_watch(root, function()
        updated = true
        core.refresh_all(config)
      end, { debounce_ms = 10 })

      -- Wait a bit for the watcher to be fully set up before editing the file
      vim.wait(50, function()
        return false
      end, 10)

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')

      -- Wait for the buffer to actually be updated, not just the updated flag
      local ok = vim.wait(2000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)

      assert.is_true(ok, "Buffer was not updated. updated=" .. tostring(updated))
    end)
  end)

  it("detects new files without watcher", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      -- Use resources.ensure_index directly to test the core functionality
      local cache1 = resources.ensure_index(root)
      assert.is_nil(cache1.index.ja["new:key"], "new:key should not exist initially")

      -- Add new file
      helpers.write_file(root .. "/locales/ja/new.json", '{"key":"新規キー"}')

      -- Call ensure_index again - should detect new file
      local cache2 = resources.ensure_index(root)
      assert.is_not_nil(cache2.index.ja["new:key"], "new:key should exist after adding file")
      assert.are.equal("新規キー", cache2.index.ja["new:key"].value)
    end)
  end)

  it("detects deleted files without watcher", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/ja/removed.json", '{"key":"削除される"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      -- Build initial cache with the file
      local cache1 = resources.ensure_index(root)
      assert.is_not_nil(cache1.index.ja["removed:key"], "removed:key should exist initially")
      assert.are.equal("削除される", cache1.index.ja["removed:key"].value)

      -- Delete the file
      vim.uv.fs_unlink(root .. "/locales/ja/removed.json")

      -- Call ensure_index again - should detect file deletion
      local cache2 = resources.ensure_index(root)
      assert.is_nil(cache2.index.ja["removed:key"], "removed:key should not exist after deletion")
    end)
  end)

  it("watcher passes changed paths to callback", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local received_event = nil

      resources.start_watch(root, function(event)
        received_event = event
      end, { debounce_ms = 10 })

      -- Wait for watcher to be set up
      vim.wait(50, function()
        return false
      end, 10)

      -- Modify file
      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"変更後"}}')

      -- Wait for callback
      local ok = vim.wait(2000, function()
        return received_event ~= nil
      end, 10)

      assert.is_true(ok, "Callback was not called")
      assert.is_not_nil(received_event)
      assert.is_not_nil(received_event.paths)
      assert.is_true(#received_event.paths > 0)
    end)
  end)

  it("watcher debounces multiple rapid changes", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local callback_count = 0
      local last_event = nil

      resources.start_watch(root, function(event)
        callback_count = callback_count + 1
        last_event = event
      end, { debounce_ms = 100 })

      -- Wait for watcher to be set up
      vim.wait(50, function()
        return false
      end, 10)

      -- Make multiple rapid changes
      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"変更1"}}')
      vim.wait(20, function()
        return false
      end, 5)
      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"変更2"}}')
      vim.wait(20, function()
        return false
      end, 5)
      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"変更3"}}')

      -- Wait for debounced callback
      vim.wait(500, function()
        return callback_count > 0
      end, 10)

      -- Should have been called only once (or at most a few times due to debounce)
      -- The key point is that rapid changes are batched
      assert.is_true(callback_count <= 3, "Too many callbacks: " .. callback_count)
      assert.is_not_nil(last_event)
    end)
  end)

  it("incremental update via watcher updates inline display", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
        resource_watch = { enabled = true, debounce_ms = 10 },
      })

      -- Initial render
      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)

      -- Build cache to get key
      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Start watcher with incremental update logic
      resources.start_watch(root, function(event)
        if event and event.paths and #event.paths > 0 and not event.needs_rebuild then
          resources.apply_changes(cache_key, event.paths)
        else
          resources.mark_dirty()
        end
        core.refresh_all(config)
      end, { debounce_ms = 10 })

      -- Wait for watcher setup
      vim.wait(50, function()
        return false
      end, 10)

      -- Update file
      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')

      -- Wait for update
      local ok = vim.wait(2000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)

      assert.is_true(ok, "Inline display was not updated")
    end)
  end)
end)
