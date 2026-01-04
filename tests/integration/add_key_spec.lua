local review = require("i18n-status.review")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

describe("add_key from Doctor UI", function()
  it("adds missing key across all languages", function()
    state.init("en", { "en", "ja", "zh" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"existing":"Existing"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"existing":"既存"}')
    helpers.write_file(root .. "/locales/zh/common.json", '{"existing":"现有"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("existing")', 't("newkey")' }, "typescript")

      -- Create mock issues with missing key
      local issues = {
        { kind = "missing", key = "common:newkey", severity = vim.log.levels.ERROR },
      }

      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      -- Find the missing key line
      local lines = vim.api.nvim_buf_get_lines(ctx.list_buf, 0, -1, false)
      local item_line = nil
      for i, line in ipairs(lines) do
        if line:match("common:newkey") then
          item_line = i
          break
        end
      end
      assert.is_not_nil(item_line, "Could not find newkey item")

      -- Move cursor to the missing key
      vim.api.nvim_win_set_cursor(ctx.list_win, { item_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      -- Mock vim.ui.input to simulate user input for each language
      local original_input = vim.ui.input
      local input_count = 0
      local expected_prompts = { "en", "ja", "zh" }
      local input_values = {
        en = "New Key",
        ja = "新しいキー",
        zh = "新键",
      }

      vim.ui.input = function(opts, on_confirm)
        input_count = input_count + 1
        local prompt = opts.prompt or ""

        -- Verify prompt contains the correct locale
        local locale = expected_prompts[input_count]
        assert.is_not_nil(locale, "Too many input prompts")
        assert.is_true(prompt:find(locale, 1, true) ~= nil, "Prompt should contain locale: " .. locale)

        -- Provide the translation
        on_confirm(input_values[locale])
      end

      -- Trigger add key action with "a" key
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)

      vim.ui.input = original_input

      -- Verify all three languages were prompted
      assert.are.equal(3, input_count)

      -- Verify files were written correctly
      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local zh_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/zh/common.json"))

      assert.are.equal("New Key", en_data.newkey)
      assert.are.equal("新しいキー", ja_data.newkey)
      assert.are.equal("新键", zh_data.newkey)

      -- Verify existing keys are preserved
      assert.are.equal("Existing", en_data.existing)
      assert.are.equal("既存", ja_data.existing)
      assert.are.equal("现有", zh_data.existing)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("does not add key when status is not missing", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"existing":"Existing"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"existing":"既存"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("existing")' }, "typescript")

      -- Create mock issues (key exists, not missing)
      local issues = {
        { kind = "drift_missing", key = "common:existing", severity = vim.log.levels.WARN },
      }

      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      -- Find the item line
      local lines = vim.api.nvim_buf_get_lines(ctx.list_buf, 0, -1, false)
      local item_line = nil
      for i, line in ipairs(lines) do
        if line:match("common:existing") then
          item_line = i
          break
        end
      end
      assert.is_not_nil(item_line)

      vim.api.nvim_win_set_cursor(ctx.list_win, { item_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      -- Mock vim.ui.input (should not be called)
      local original_input = vim.ui.input
      local input_called = false
      vim.ui.input = function(_opts, _on_confirm)
        input_called = true
      end

      -- Trigger add key action
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)

      vim.ui.input = original_input

      -- Verify input was not called (since key already exists)
      assert.is_false(input_called)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("handles cancellation gracefully", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"existing":"Existing"}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"existing":"既存"}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("newkey")' }, "typescript")

      local issues = {
        { kind = "missing", key = "common:newkey", severity = vim.log.levels.ERROR },
      }

      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      local lines = vim.api.nvim_buf_get_lines(ctx.list_buf, 0, -1, false)
      local item_line = nil
      for i, line in ipairs(lines) do
        if line:match("common:newkey") then
          item_line = i
          break
        end
      end
      assert.is_not_nil(item_line)

      vim.api.nvim_win_set_cursor(ctx.list_win, { item_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      -- Mock vim.ui.input to cancel on first prompt
      local original_input = vim.ui.input
      vim.ui.input = function(_opts, on_confirm)
        on_confirm(nil) -- User cancels
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)

      vim.ui.input = original_input

      -- Verify files were not modified
      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      assert.is_nil(en_data.newkey)
      assert.is_nil(ja_data.newkey)
      assert.are.equal("Existing", en_data.existing)
      assert.are.equal("既存", ja_data.existing)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)

  it("adds nested key correctly", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", '{"form":{"login":{"existing":"Old"}}}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"form":{"login":{"existing":"古い"}}}')

    helpers.with_cwd(root, function()
      local src = make_buf({ 't("form.login.title")' }, "typescript")

      local issues = {
        { kind = "missing", key = "common:form.login.title", severity = vim.log.levels.ERROR },
      }

      local cache = resources.ensure_index(root)
      local ctx_mock = {
        bufnr = src,
        cache = cache,
      }

      local config = config_mod.setup({ primary_lang = "en" })
      local ctx = review.open_doctor_results(issues, ctx_mock, config)

      local lines = vim.api.nvim_buf_get_lines(ctx.list_buf, 0, -1, false)
      local item_line = nil
      for i, line in ipairs(lines) do
        if line:match("form%.login%.title") then
          item_line = i
          break
        end
      end
      assert.is_not_nil(item_line)

      vim.api.nvim_win_set_cursor(ctx.list_win, { item_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })

      local original_input = vim.ui.input
      local input_values = { "Login Title", "ログインタイトル" }
      local input_index = 0
      vim.ui.input = function(_opts, on_confirm)
        input_index = input_index + 1
        on_confirm(input_values[input_index])
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)

      vim.ui.input = original_input

      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      assert.are.equal("Login Title", en_data.form.login.title)
      assert.are.equal("ログインタイトル", ja_data.form.login.title)
      assert.are.equal("Old", en_data.form.login.existing)
      assert.are.equal("古い", ja_data.form.login.existing)

      -- Clean up
      pcall(vim.api.nvim_win_close, ctx.list_win, true)
      pcall(vim.api.nvim_win_close, ctx.detail_win, true)
    end)
  end)
end)

describe("I18nAddKey command", function()
  it("adds new key with namespace", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("newkey")' }, "typescript")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "en" })

      -- Mock project state
      local cache = resources.ensure_index(root)
      local project_key = root
      state.set_languages(project_key, { "en", "ja" })
      state.projects[project_key] = {
        key = project_key,
        cache = cache,
        languages = { "en", "ja" },
        primary_lang = "en",
        current_lang = "en",
      }
      state.buf_project[buf] = project_key

      local original_input = vim.ui.input
      local input_sequence = { "common:hello.world", "Hello World", "こんにちは世界" }
      local input_index = 0

      vim.ui.input = function(_opts, on_confirm)
        input_index = input_index + 1
        on_confirm(input_sequence[input_index])
      end

      review.add_key_command(config)

      vim.ui.input = original_input

      assert.are.equal(3, input_index)

      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      assert.are.equal("Hello World", en_data.hello.world)
      assert.are.equal("こんにちは世界", ja_data.hello.world)
    end)
  end)

  it("adds new key without namespace (uses default)", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("test")' }, "typescript")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "en" })

      local cache = resources.ensure_index(root)
      local project_key = root
      state.set_languages(project_key, { "en", "ja" })
      state.projects[project_key] = {
        key = project_key,
        cache = cache,
        languages = { "en", "ja" },
        primary_lang = "en",
        current_lang = "en",
      }
      state.buf_project[buf] = project_key

      local original_input = vim.ui.input
      local input_sequence = { "test.key", "Test", "テスト" }
      local input_index = 0

      vim.ui.input = function(_opts, on_confirm)
        input_index = input_index + 1
        on_confirm(input_sequence[input_index])
      end

      review.add_key_command(config)

      vim.ui.input = original_input

      -- Should have asked for key name + 2 languages
      assert.are.equal(3, input_index)

      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      assert.are.equal("Test", en_data.test.key)
      assert.are.equal("テスト", ja_data.test.key)
    end)
  end)

  it("rejects invalid key names", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({}, "typescript")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "en" })

      local cache = resources.ensure_index(root)
      local project_key = root
      state.set_languages(project_key, { "en", "ja" })
      state.projects[project_key] = {
        key = project_key,
        cache = cache,
        languages = { "en", "ja" },
        primary_lang = "en",
        current_lang = "en",
      }
      state.buf_project[buf] = project_key

      local test_cases = {
        { input = "", should_reject = true, description = "empty string" },
        { input = "key..name", should_reject = true, description = "consecutive dots" },
        { input = ".keyname", should_reject = true, description = "leading dot" },
        { input = "keyname.", should_reject = true, description = "trailing dot" },
        { input = "key name", should_reject = true, description = "space character" },
        { input = "key:with:multiple:colons", should_reject = true, description = "multiple colons" },
      }

      for _, test_case in ipairs(test_cases) do
        local original_input = vim.ui.input
        local input_count = 0

        vim.ui.input = function(_opts, on_confirm)
          input_count = input_count + 1
          if input_count == 1 then
            on_confirm(test_case.input)
          else
            -- Should not reach here for invalid keys
            on_confirm("value")
          end
        end

        review.add_key_command(config)

        vim.ui.input = original_input

        if test_case.should_reject then
          -- Should only have called input once (for key name, then rejected)
          assert.are.equal(1, input_count, "Failed for: " .. test_case.description)
        end
      end
    end)
  end)

  it("rejects empty values for any language", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({}, "typescript")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "en" })

      local cache = resources.ensure_index(root)
      local project_key = root
      state.set_languages(project_key, { "en", "ja" })
      state.projects[project_key] = {
        key = project_key,
        cache = cache,
        languages = { "en", "ja" },
        primary_lang = "en",
        current_lang = "en",
      }
      state.buf_project[buf] = project_key

      local original_input = vim.ui.input
      local input_sequence = { "test.key", "Valid Value", "" } -- Empty for ja
      local input_index = 0

      vim.ui.input = function(_opts, on_confirm)
        input_index = input_index + 1
        on_confirm(input_sequence[input_index])
      end

      review.add_key_command(config)

      vim.ui.input = original_input

      -- Should have prompted for all inputs
      assert.are.equal(3, input_index)

      -- But files should not be written due to empty value
      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      -- Should still be empty because validation failed
      assert.is_nil(en_data.test)
      assert.is_nil(ja_data.test)
    end)
  end)

  it("handles user cancellation", function()
    state.init("en", { "en", "ja" })

    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({}, "typescript")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "en" })

      local cache = resources.ensure_index(root)
      local project_key = root
      state.set_languages(project_key, { "en", "ja" })
      state.projects[project_key] = {
        key = project_key,
        cache = cache,
        languages = { "en", "ja" },
        primary_lang = "en",
        current_lang = "en",
      }
      state.buf_project[buf] = project_key

      local original_input = vim.ui.input
      vim.ui.input = function(_opts, on_confirm)
        on_confirm(nil) -- User cancels
      end

      review.add_key_command(config)

      vim.ui.input = original_input

      -- Files should remain empty
      local en_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      local ja_data = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))

      assert.are.same({}, en_data)
      assert.are.same({}, ja_data)
    end)
  end)
end)
