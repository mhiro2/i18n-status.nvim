local TARGET_MODULES = {
  "i18n-status.types",
  "i18n-status.config",
  "i18n-status.core",
  "i18n-status.state",
  "i18n-status.actions",
  "i18n-status.resources",
  "i18n-status.doctor",
  "i18n-status.util",
  "i18n-status.extract",
  "i18n-status.rpc",
}

---@param modules string[]
local function clear_loaded(modules)
  for _, name in ipairs(modules) do
    package.loaded[name] = nil
  end
end

describe("init lazy loading", function()
  before_each(function()
    clear_loaded(TARGET_MODULES)
    package.loaded["i18n-status"] = nil
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "i18n-status")
    clear_loaded(TARGET_MODULES)
    package.loaded["i18n-status"] = nil
  end)

  it("does not eagerly load runtime modules on require", function()
    require("i18n-status")
    for _, name in ipairs(TARGET_MODULES) do
      assert.is_nil(package.loaded[name], name .. " should remain unloaded until setup")
    end
  end)
end)
