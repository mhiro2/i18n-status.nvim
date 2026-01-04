local ui = require("i18n-status.ui")

describe("ui.select", function()
  local original_modules
  local function stub_module(name, value)
    if original_modules[name] == nil then
      original_modules[name] = package.loaded[name]
    end
    package.loaded[name] = value
  end

  before_each(function()
    original_modules = {}
  end)

  after_each(function()
    for name, value in pairs(original_modules) do
      package.loaded[name] = value
    end
  end)

  it("uses a default formatter when telescope is available", function()
    local selected_entry
    local actions = {}
    actions.select_default = {
      replace = function(_, cb)
        actions._callback = cb
      end,
    }
    actions.close = function() end

    local action_state = {}
    action_state.get_selected_entry = function()
      return selected_entry
    end

    stub_module("telescope.config", {
      values = {
        generic_sorter = function()
          return function() end
        end,
      },
    })

    stub_module("telescope.finders", {
      new_table = function(tbl)
        return tbl
      end,
    })

    stub_module("telescope.actions", actions)
    stub_module("telescope.actions.state", action_state)

    stub_module("telescope.pickers", {
      new = function(_, opts)
        return {
          find = function()
            selected_entry = opts.finder.entry_maker(opts.finder.results[1])
            opts.attach_mappings(0)
            actions._callback()
          end,
        }
      end,
    })

    local choice
    ui.select({ "missing", "ok" }, { prompt = "filter" }, function(item)
      choice = item
    end)

    assert.are.equal("missing", choice)
  end)
end)
