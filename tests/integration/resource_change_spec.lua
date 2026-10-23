local core = require("i18n-status.core")
local render = require("i18n-status.render")
local config_mod = require("i18n-status.config")
local init = require("i18n-status")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")
local watcher = require("i18n-status.watcher")

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
    init.setup({
      primary_lang = "ja",
      resource_watch = { enabled = false },
    })
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
      local initial_rendered = vim.wait(1000, function()
        return inline_text(buf):find("ログイン", 1, true) ~= nil
      end, 10)
      assert.is_true(initial_rendered)

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')
      core.refresh_now(buf, config)
      local updated_rendered = vim.wait(1000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)
      assert.is_true(updated_rendered)
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
      local refreshed = vim.wait(1000, function()
        return inline_text(buf1):find("A", 1, true) ~= nil and inline_text(buf2):find("B", 1, true) ~= nil
      end, 10)
      assert.is_true(refreshed)
    end)
  end)

  ---Open a source file through the public setup so BufEnter registers the production watcher.
  ---@param root string
  ---@return integer buf
  local function open_source_with_watch(root)
    helpers.write_file(root .. "/src/app.ts", 't("login.title")\n')
    init.setup({
      inline = { visible_only = false },
      resource_watch = { enabled = true, debounce_ms = 10 },
    })
    vim.cmd.edit(root .. "/src/app.ts")
    local buf = vim.api.nvim_get_current_buf()
    local ready = vim.wait(2000, function()
      return state.buf_watcher_keys[buf] ~= nil and inline_text(buf):find("ログイン", 1, true) ~= nil
    end, 10)
    assert.is_true(ready, "setup did not register a watcher and render the source")
    return buf
  end

  it("updates inline display after an external edit through the setup watcher", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = open_source_with_watch(root)
      assert.is_true(watcher.is_watching(state.buf_watcher_keys[buf]))

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')

      local ok = vim.wait(3000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)
      assert.is_true(ok, "Inline display was not updated")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("applies watcher paths incrementally through the setup callback", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local fake_events = helpers.fake_fs_events()
    local original_apply_changes = resources.apply_changes
    local original_mark_dirty = resources.mark_dirty
    local apply_calls = {}
    local mark_dirty_calls = 0
    resources.apply_changes = function(cache_key, paths, opts)
      local success, needs_rebuild = original_apply_changes(cache_key, paths, opts)
      table.insert(apply_calls, { paths = paths, success = success })
      return success, needs_rebuild
    end
    resources.mark_dirty = function(...)
      mark_dirty_calls = mark_dirty_calls + 1
      return original_mark_dirty(...)
    end

    local ok, err = pcall(helpers.with_cwd, root, function()
      local buf = open_source_with_watch(root)
      local resource_path = vim.uv.fs_realpath(root .. "/locales/ja/common.json")
      local handle
      for _, candidate in ipairs(fake_events.handles) do
        if not candidate.closed and vim.uv.fs_realpath(candidate.path) == resource_path then
          handle = candidate
        end
      end
      assert.is_not_nil(handle, "resource file is not watched")
      mark_dirty_calls = 0

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')
      handle.cb(nil, "common.json", {})

      local updated = vim.wait(3000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)
      assert.is_true(updated, "Inline display was not updated")
      assert.are.equal(1, #apply_calls)
      assert.are.same({ handle.path }, apply_calls[1].paths)
      assert.is_true(apply_calls[1].success)
      assert.are.equal(0, mark_dirty_calls)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    resources.apply_changes = original_apply_changes
    resources.mark_dirty = original_mark_dirty
    fake_events.restore()
    assert.is_true(ok, err)
  end)

  it("reports the edited resource file from OS watcher events", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local events = {}
      resources.start_watch(root, function(event)
        table.insert(events, event)
      end, { debounce_ms = 10 })

      -- Let the watcher settle before editing the file
      vim.wait(200, function()
        return false
      end, 10)
      local baseline = #events

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"変更後"}}')

      local ok = vim.wait(3000, function()
        return #events > baseline
      end, 10)
      assert.is_true(ok, "Callback was not called")

      local event = events[#events]
      if event.needs_rebuild then
        -- Platforms may report the change on a watched root, which requests a full rebuild instead.
        assert.are.same({}, event.paths)
      else
        local expected = vim.uv.fs_realpath(root .. "/locales/ja/common.json")
        assert.is_true(#event.paths > 0)
        for _, path in ipairs(event.paths) do
          assert.are.equal(expected, vim.uv.fs_realpath(path))
        end
      end
    end)
  end)

  it("applies a resource change when another refresh arrives before it finishes", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)

      helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')
      resources.mark_dirty()
      core.refresh_all(config)
      -- BufEnter, hover, or scrolling refresh the same buffer before the asynchronous result lands.
      core.refresh(buf, config)

      local updated = vim.wait(2000, function()
        return inline_text(buf):find("サインイン", 1, true) ~= nil
      end, 10)
      assert.is_true(updated, "Inline display was not updated")
    end)
  end)
end)
