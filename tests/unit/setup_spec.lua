local stub = require("luassert.stub")

local state = require("i18n-status.state")
local core = require("i18n-status.core")
local resources = require("i18n-status.resources")

describe("setup reconfiguration", function()
  local i18n
  local stubs
  local fake_cache
  local watcher_key
  local start_watch_calls
  local stop_watch_for_buffer_calls
  local should_refresh
  local refresh_calls

  local function reload_module()
    package.loaded["i18n-status"] = nil
    i18n = require("i18n-status")
  end

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    table.insert(stubs, s)
    return s
  end

  before_each(function()
    stubs = {}
    fake_cache = {
      key = "__project__",
      languages = { "ja", "en" },
      index = {},
    }
    watcher_key = "__project__"
    start_watch_calls = 0
    stop_watch_for_buffer_calls = 0
    should_refresh = false
    refresh_calls = 0

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return fake_cache
    end)
    add_stub(resources, "get_watcher_key", function()
      return watcher_key
    end)
    add_stub(resources, "start_watch", function()
      start_watch_calls = start_watch_calls + 1
      return watcher_key
    end)
    add_stub(resources, "stop_watch_for_buffer", function()
      stop_watch_for_buffer_calls = stop_watch_for_buffer_calls + 1
      return true
    end)
    add_stub(resources, "stop_watch", function() end)

    add_stub(core, "refresh_all", function() end)
    add_stub(core, "refresh", function()
      refresh_calls = refresh_calls + 1
    end)
    add_stub(core, "should_refresh", function()
      return should_refresh
    end)

    state.init("ja", {})
    reload_module()
  end)

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
  end)

  it("keeps current language when toggling auto_hover", function()
    i18n.setup({ primary_lang = "ja" })

    local bufnr = vim.api.nvim_get_current_buf()
    local _, key = state.project_for_buf(bufnr)
    state.set_languages(key, { "ja", "en" })
    state.set_current(key, "en")

    i18n.setup({ auto_hover = { enabled = false } })
    assert.are.equal("en", state.project_for_key(key).current_lang)

    i18n.setup({ auto_hover = { enabled = true } })
    assert.are.equal("en", state.project_for_key(key).current_lang)
  end)

  it("does not start watcher repeatedly for the same buffer/key", function()
    should_refresh = true
    i18n.setup({ primary_lang = "ja" })

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
    vim.wait(100, function()
      return refresh_calls > 0
    end)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
    vim.wait(100, function()
      return refresh_calls > 1
    end)

    assert.are.equal(1, start_watch_calls)
    assert.are.equal(0, stop_watch_for_buffer_calls)
  end)

  it("switches watcher references only when watcher key changes", function()
    should_refresh = true
    i18n.setup({ primary_lang = "ja" })

    local bufnr = vim.api.nvim_get_current_buf()
    watcher_key = "__project2__"
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
    vim.wait(100, function()
      return start_watch_calls >= 2 and stop_watch_for_buffer_calls >= 1
    end)

    assert.are.equal(2, start_watch_calls)
    assert.are.equal(1, stop_watch_for_buffer_calls)
    assert.are.equal("__project2__", state.buf_watcher_keys[bufnr])
  end)

  it("does not start watcher for unsupported buffers", function()
    should_refresh = false
    i18n.setup({ primary_lang = "ja" })

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
    vim.wait(20, function()
      return false
    end)

    assert.are.equal(0, start_watch_calls)
    assert.are.equal(0, stop_watch_for_buffer_calls)
    assert.is_nil(state.buf_watcher_keys[bufnr])
  end)
end)
