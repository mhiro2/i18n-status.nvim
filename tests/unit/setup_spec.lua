local stub = require("luassert.stub")

local state = require("i18n-status.state")
local core = require("i18n-status.core")
local resources = require("i18n-status.resources")

describe("setup reconfiguration", function()
  local i18n
  local stubs
  local fake_cache

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

    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return fake_cache
    end)
    add_stub(resources, "start_watch", function() end)
    add_stub(resources, "stop_watch", function() end)

    add_stub(core, "refresh_all", function() end)
    add_stub(core, "refresh", function() end)
    add_stub(core, "should_refresh", function()
      return false
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
end)
