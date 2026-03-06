local stub = require("luassert.stub")

local review_shared_ui = require("i18n-status.review_shared_ui")

describe("review shared ui", function()
  local stubs = {}

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    stubs[#stubs + 1] = s
    return s
  end

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) then
        local ft = vim.bo[buf].filetype
        if ft == "i18n-status-review-help" or ft == "i18n-status-extract-review-help" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local ft = vim.bo[buf].filetype
        if ft == "i18n-status-review-help" or ft == "i18n-status-extract-review-help" then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end)

  it("normalizes filter query with optional lowercase", function()
    assert.is_nil(review_shared_ui.normalize_filter_query(nil))
    assert.is_nil(review_shared_ui.normalize_filter_query("   "))
    assert.are.equal("MixedCase", review_shared_ui.normalize_filter_query("  MixedCase  "))
    assert.are.equal("mixedcase", review_shared_ui.normalize_filter_query("  MixedCase  ", { lowercase = true }))
  end)

  it("prompts filter and forwards normalized value", function()
    local captured = {}
    add_stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("  Query  ")
    end)

    review_shared_ui.prompt_filter({}, {
      prompt = "Filter: ",
      lowercase = true,
      on_confirm = function(_, normalized, raw_input)
        captured.normalized = normalized
        captured.raw_input = raw_input
      end,
    })

    assert.are.equal("query", captured.normalized)
    assert.are.equal("  Query  ", captured.raw_input)
  end)

  it("skips prompt confirmation when skip callback returns true", function()
    local called = false
    add_stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("value")
    end)

    review_shared_ui.prompt_filter({}, {
      prompt = "Filter: ",
      skip = function()
        return true
      end,
      on_confirm = function()
        called = true
      end,
    })

    assert.is_false(called)
  end)

  it("opens and toggles help window", function()
    local ctx = {}

    review_shared_ui.toggle_help_window(ctx, {
      title = "Shared keymaps",
      keymaps = {
        { keys = "q", desc = "Close" },
      },
      filetype = "i18n-status-review-help",
    })

    assert.is_number(ctx.help_win)
    assert.is_true(vim.api.nvim_win_is_valid(ctx.help_win))
    assert.is_number(ctx.help_buf)
    assert.is_true(vim.api.nvim_buf_is_valid(ctx.help_buf))
    assert.are.equal("i18n-status-review-help", vim.bo[ctx.help_buf].filetype)

    review_shared_ui.toggle_help_window(ctx, {
      title = "Shared keymaps",
      keymaps = {
        { keys = "q", desc = "Close" },
      },
      filetype = "i18n-status-review-help",
    })

    assert.is_nil(ctx.help_win)
    assert.is_nil(ctx.help_buf)
  end)

  it("binds context keymaps with before hook", function()
    local callbacks = {}
    add_stub(vim.keymap, "set", function(_, lhs, rhs, opts)
      callbacks[lhs] = {
        cb = rhs,
        opts = opts,
      }
    end)

    local state = {
      [11] = { count = 0, before_count = 0 },
    }

    review_shared_ui.bind_context_keymaps({
      bufnr = 11,
      state = state,
      before = function(ctx)
        ctx.before_count = ctx.before_count + 1
      end,
      bindings = {
        {
          lhs = "x",
          handler = function(ctx)
            ctx.count = ctx.count + 1
          end,
        },
        {
          lhs = "y",
          nowait = false,
          silent = false,
          handler = function(ctx)
            ctx.count = ctx.count + 10
          end,
        },
      },
    })

    assert.is_not_nil(callbacks.x)
    assert.is_not_nil(callbacks.y)

    callbacks.x.cb()
    callbacks.y.cb()

    assert.are.equal(11, state[11].count)
    assert.are.equal(2, state[11].before_count)
    assert.is_true(callbacks.x.opts.nowait)
    assert.is_true(callbacks.x.opts.silent)
    assert.is_false(callbacks.y.opts.nowait)
    assert.is_false(callbacks.y.opts.silent)
  end)
end)
