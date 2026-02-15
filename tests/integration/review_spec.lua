local review = require("i18n-status.review")
local config_mod = require("i18n-status.config")
local core = require("i18n-status.core")
local review_ui = require("i18n-status.review_ui")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

---@param buf integer
---@return string[], string[]
local function list_item_keys(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local keys = {}
  for _, line in ipairs(lines) do
    local key = line:match("^%s+([^%s]+)%s+%[[^%]]+%]$")
    if key then
      table.insert(keys, key)
    end
  end
  return keys, lines
end

describe("doctor review", function()
  it("shows list and detail in floating window", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"alpha":"Alpha","beta":"Beta"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"alpha":"アルファ","gamma":"ガンマ"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("alpha")', 't("beta")', 't("gamma")' }, "typescript")

      -- Create mock issues
      local issues = {
        { kind = "missing", key = "common:beta", severity = vim.log.levels.ERROR },
        { kind = "drift_missing", key = "common:beta", severity = vim.log.levels.WARN },
        { kind = "drift_extra", key = "common:gamma", severity = vim.log.levels.WARN },
      }

      -- Create mock context
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      local list_buf = ctx.list_buf
      local detail_buf = ctx.detail_buf

      -- Check that windows are valid
      assert.is_true(vim.api.nvim_win_is_valid(ctx.list_win))
      assert.is_true(vim.api.nvim_win_is_valid(ctx.detail_win))

      -- Check list content
      local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
      assert.is_true(#lines >= 1)
      -- First line should be summary line
      assert.is_not_nil(lines[1]:match("^Total:"))
      local winbar = vim.wo[ctx.list_win].winbar or ""
      assert.is_not_nil(winbar:find("I18nDoctor"))

      -- Check detail content
      -- Find the first item line (should be after summary, empty line, and section header)
      local item_line = nil
      for i, line in ipairs(lines) do
        if line:match("^%s+common:") then
          item_line = i
          break
        end
      end
      assert.is_not_nil(item_line, "Could not find item line")

      vim.api.nvim_win_set_cursor(ctx.list_win, { item_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = list_buf })

      local detail_lines = vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false)
      local found_header = false
      local found_row = false
      for _, line in ipairs(detail_lines) do
        -- Match header with flexible spacing (due to padding)
        if line:match("Locale%s*|%s*Value%s*|%s*Source") then
          found_header = true
        elseif line:match("^%s*%w+") and line:find("|") then
          found_row = true
        end
      end
      assert.is_true(found_header)
      assert.is_true(found_row)

      -- Test section toggle
      -- Find section header line (looks for pattern like "Missing (2)" or "Localized (3)")
      local section_line = nil
      for i, line in ipairs(lines) do
        if
          line:find("Missing")
          or line:find("Localized")
          or line:find("Fallback")
          or line:find("Mismatch")
          or line:find("Same")
        then
          if line:find("%(") then -- Has opening paren (count)
            section_line = i
            break
          end
        end
      end
      assert.is_not_nil(section_line, "Could not find section header. Lines:\n" .. table.concat(lines, "\n"))

      -- Move to section header and toggle
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_win_set_cursor(ctx.list_win, { section_line, 0 })
      vim.api.nvim_feedkeys(" ", "x", false) -- Space to toggle

      -- Check that section is now collapsed (should have fewer lines)
      local collapsed_lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
      assert.is_true(#collapsed_lines < #lines, "Section should be collapsed")

      -- Keymap help toggle
      ctx:toggle_help()
      assert.is_not_nil(ctx.help_win)
      assert.is_true(vim.api.nvim_win_is_valid(ctx.help_win))
      ctx:toggle_help()
      assert.is_nil(ctx.help_win)

      assert.is_false(vim.bo[list_buf].modifiable)
      assert.is_false(vim.bo[detail_buf].modifiable)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("filters items with slash key and preserves state across mode switch", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"alpha":"Alpha","beta":"Beta","gamma":"Gamma"}')
    helpers.write_file(
      root .. "/locales/ja/common.json",
      '{"alpha":"アルファ","beta":"ベータ","gamma":"ガンマ"}'
    )

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("alpha")', 't("beta")', 't("gamma")' }, "typescript")
      local issues = {
        { kind = "missing", key = "common:beta", severity = vim.log.levels.ERROR },
        { kind = "drift_missing", key = "common:beta", severity = vim.log.levels.WARN },
        { kind = "drift_extra", key = "common:gamma", severity = vim.log.levels.WARN },
      }
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)
      vim.api.nvim_set_current_win(ctx.list_win)

      local original_input = vim.ui.input
      local next_input = "beta"
      vim.ui.input = function(_opts, on_confirm)
        on_confirm(next_input)
      end

      vim.api.nvim_feedkeys("/", "x", false)

      local filtered_keys = list_item_keys(ctx.list_buf)
      assert.same({ "common:beta" }, filtered_keys)
      assert.are.equal("beta", ctx.filter_query)

      local filtered_winbar = review_ui.build_review_winbar(120, ctx.mode, ctx.filter_query)
      assert.is_not_nil(filtered_winbar:find("[/beta]", 1, true))

      next_input = nil
      vim.api.nvim_feedkeys("/", "x", false)

      local keys_after_cancel = list_item_keys(ctx.list_buf)
      assert.same({ "common:beta" }, keys_after_cancel)
      assert.are.equal("beta", ctx.filter_query)

      local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
      vim.api.nvim_feedkeys(tab, "x", false)

      local overview_keys = list_item_keys(ctx.list_buf)
      assert.same({ "common:beta" }, overview_keys)

      next_input = ""
      vim.api.nvim_feedkeys("/", "x", false)

      local keys_after_clear = list_item_keys(ctx.list_buf)
      assert.is_true(vim.tbl_contains(keys_after_clear, "common:alpha"))
      assert.is_true(vim.tbl_contains(keys_after_clear, "common:beta"))
      assert.is_true(vim.tbl_contains(keys_after_clear, "common:gamma"))
      assert.is_nil(ctx.filter_query)

      local cleared_winbar = review_ui.build_review_winbar(120, ctx.mode, ctx.filter_query)
      assert.is_nil(cleared_winbar:find("[/", 1, true))

      vim.ui.input = original_input

      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("closes the review UI with q even when help is open", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"alpha":"Alpha"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"alpha":"アルファ"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("alpha")' }, "typescript")
      local issues = {
        { kind = "missing", key = "common:alpha", severity = vim.log.levels.ERROR },
      }
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      ctx:toggle_help()
      assert.is_not_nil(ctx.help_win)
      assert.is_true(vim.api.nvim_win_is_valid(ctx.help_win))

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("q", "x", false)

      vim.wait(50, function()
        return not vim.api.nvim_win_is_valid(ctx.list_win)
      end, 5)

      assert.is_false(vim.api.nvim_win_is_valid(ctx.list_win))
      assert.is_false(vim.api.nvim_win_is_valid(ctx.detail_win))
      assert.is_nil(ctx.help_win)
    end)
  end)

  it("restores eventignore synchronously when closing review", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"alpha":"Alpha"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"alpha":"アルファ"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("alpha")' }, "typescript")
      local issues = {
        { kind = "missing", key = "common:alpha", severity = vim.log.levels.ERROR },
      }
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      local original_eventignore = vim.o.eventignore
      local original_schedule = vim.schedule
      local expected_eventignore = "BufEnter"
      local close_ok, close_err

      vim.schedule = function(_cb) end
      vim.o.eventignore = expected_eventignore
      close_ok, close_err = pcall(function()
        vim.api.nvim_set_current_win(ctx.list_win)
        vim.api.nvim_feedkeys("q", "x", false)
      end)
      vim.schedule = original_schedule

      local observed_eventignore = vim.o.eventignore
      vim.o.eventignore = original_eventignore

      assert.is_true(close_ok, close_err)
      assert.are.equal(expected_eventignore, observed_eventignore)

      local list_valid = vim.api.nvim_win_is_valid(ctx.list_win)
      local detail_valid = vim.api.nvim_win_is_valid(ctx.detail_win)
      if list_valid then
        pcall(vim.api.nvim_win_close, ctx.list_win, true)
      end
      if detail_valid then
        pcall(vim.api.nvim_win_close, ctx.detail_win, true)
      end
      assert.is_false(list_valid)
      assert.is_false(detail_valid)
    end)
  end)

  it("keeps review header highlight linked to title-like groups", function()
    review_ui.ensure_review_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "I18nStatusReviewHeader", link = true })
    assert.is_not_nil(hl)
    assert.is_not_nil(hl.link)
    assert.is_true(hl.link == "TelescopeResultsTitle" or hl.link == "Title")
  end)
end)

describe("doctor review edit", function()
  it("edits primary language value", function()
    state.init("ja", { "ja", "en" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"Old"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      -- Create mock issues
      local issues = {
        { kind = "drift_missing", key = "common:login.title", severity = vim.log.levels.WARN },
      }

      -- Create mock context
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local ctx = review.open_doctor_results(issues, ctx_mock, config)
      vim.api.nvim_win_set_cursor(ctx.list_win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      local original_input = vim.ui.input
      local original_select = vim.ui.select
      vim.ui.select = function(_items, _opts, on_choice)
        -- Select "ja" (primary language)
        on_choice("ja")
      end
      vim.ui.input = function(_opts, on_confirm)
        on_confirm("New")
      end
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("E", "x", false) -- E for locale selection
      vim.ui.input = original_input
      vim.ui.select = original_select

      local data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("New", data.login.title)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("renames key across resources and buffers", function()
    state.init("ja", { "ja", "en" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local buf1 = make_buf({ 't("rename.title")' }, "typescript")
      vim.api.nvim_buf_set_name(buf1, root .. "/src/one.ts")
      local buf2 = make_buf({ 'const label = t("rename.title")' }, "typescript")
      vim.api.nvim_buf_set_name(buf2, root .. "/src/two.ts")

      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf1, config)
      core.refresh_now(buf2, config)

      local issues = {
        { kind = "missing", key = "common:rename.title", severity = vim.log.levels.WARN },
      }
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = buf1,
        cache = cache,
      }

      local ctx = review.open_doctor_results(issues, ctx_mock, config)
      vim.api.nvim_win_set_cursor(ctx.list_win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      local original_input = vim.ui.input
      vim.ui.input = function(_opts, on_confirm)
        on_confirm("common:rename.heading")
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("r", "x", false)

      vim.ui.input = original_input

      local ja = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_nil(ja.rename.title)
      assert.is_nil(en.rename.title)
      assert.are.equal("ログイン", ja.rename.heading)
      assert.are.equal("Login", en.rename.heading)

      local line1 = vim.api.nvim_buf_get_lines(buf1, 0, 1, false)[1]
      local line2 = vim.api.nvim_buf_get_lines(buf2, 0, 1, false)[1]
      assert.is_true(line1:find("rename.heading", 1, true) ~= nil)
      assert.is_true(line2:find("rename.heading", 1, true) ~= nil)

      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("does not call config setup fallback when ctx.config is nil", function()
    state.init("ja", { "ja", "en" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"Old"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      local issues = {
        { kind = "drift_missing", key = "common:login.title", severity = vim.log.levels.WARN },
      }
      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }
      local ctx = review.open_doctor_results(issues, ctx_mock, config)
      vim.api.nvim_win_set_cursor(ctx.list_win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      local original_setup = config_mod.setup
      local setup_calls = 0
      config_mod.setup = function(opts)
        setup_calls = setup_calls + 1
        return original_setup(opts)
      end

      local original_select = vim.ui.select
      local original_input = vim.ui.input
      ctx.config = nil
      vim.ui.select = function(_items, _opts, on_choice)
        on_choice("ja")
      end
      vim.ui.input = function(_opts, on_confirm)
        on_confirm("New")
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("E", "x", false)

      vim.ui.select = original_select
      vim.ui.input = original_input
      config_mod.setup = original_setup

      assert.are.equal(0, setup_calls)

      local data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("New", data.login.title)

      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)
end)
