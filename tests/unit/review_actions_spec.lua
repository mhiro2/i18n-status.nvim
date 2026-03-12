local stub = require("luassert.stub")

local core = require("i18n-status.core")
local key_write = require("i18n-status.key_write")
local ops = require("i18n-status.ops")
local resources = require("i18n-status.resources")
local review_actions = require("i18n-status.review_actions")
local util = require("i18n-status.util")

describe("review actions", function()
  local stubs = {}

  local function add_stub(tbl, key, impl)
    local handle = stub(tbl, key, impl)
    stubs[#stubs + 1] = handle
    return handle
  end

  after_each(function()
    for _, handle in ipairs(stubs) do
      handle:revert()
    end
    stubs = {}
  end)

  it("edits the focused locale and refreshes doctor state", function()
    local written = nil
    local refresh_calls = 0
    local refresh_all_calls = 0
    local handlers = review_actions.new({
      refresh_doctor_async = function()
        refresh_calls = refresh_calls + 1
      end,
      close_review = function() end,
    })

    add_stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("updated text")
    end)
    add_stub(resources, "start_dir", function()
      return "/project"
    end)
    add_stub(resources, "project_root", function(start_dir)
      return start_dir
    end)
    add_stub(util, "sanitize_path", function(path)
      return path, nil
    end)
    add_stub(util, "ensure_dir", function() end)
    add_stub(resources, "read_json_table", function()
      return {}, { indent = 2 }
    end)
    add_stub(resources, "key_path_for_file", function()
      return "greeting"
    end)
    add_stub(resources, "write_json_table", function(_, data)
      written = data
      return true
    end)
    add_stub(core, "refresh_all", function()
      refresh_all_calls = refresh_all_calls + 1
    end)

    handlers.edit_focus({
      source_buf = 7,
      config = { primary_lang = "en" },
      cache = { languages = { "en", "ja" } },
      primary_lang = "en",
      display_lang = "ja",
      is_doctor_review = true,
      detail_item = {
        key = "common:greeting",
        hover = {
          values = {
            ja = { value = "old", file = "/project/locales/ja/common.json" },
          },
        },
      },
    })

    assert.are.same({ greeting = "updated text" }, written)
    assert.are.equal(1, refresh_all_calls)
    assert.are.equal(1, refresh_calls)
  end)

  it("selects a locale and edits the chosen translation", function()
    local wrote_path = nil
    local wrote_data = nil
    local handlers = review_actions.new({
      refresh_doctor_async = function() end,
      close_review = function() end,
    })

    add_stub(vim.ui, "select", function(_, _, on_choice)
      on_choice("ja")
    end)
    add_stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("translated")
    end)
    add_stub(resources, "start_dir", function()
      return "/project"
    end)
    add_stub(resources, "project_root", function(start_dir)
      return start_dir
    end)
    add_stub(util, "sanitize_path", function(path)
      return path, nil
    end)
    add_stub(util, "ensure_dir", function() end)
    add_stub(resources, "read_json_table", function()
      return {}, {}
    end)
    add_stub(resources, "key_path_for_file", function()
      return "greeting"
    end)
    add_stub(resources, "write_json_table", function(path, data)
      wrote_path = path
      wrote_data = data
      return true
    end)
    add_stub(core, "refresh_all", function() end)

    handlers.edit_locale_select({
      source_buf = 9,
      config = { primary_lang = "en" },
      cache = {
        languages = { "en", "ja", "fr", "de", "it", "es", "pt", "ko", "zh", "nl" },
      },
      is_doctor_review = false,
      detail_item = {
        key = "common:greeting",
        hover = {
          values = {
            ja = { value = "old", file = "/project/locales/ja/common.json" },
          },
        },
      },
    })

    assert.are.equal("/project/locales/ja/common.json", wrote_path)
    assert.are.same({ greeting = "translated" }, wrote_data)
  end)

  it("reports rename errors without refreshing doctor state", function()
    local refresh_calls = 0
    local notify_msg = nil
    local handlers = review_actions.new({
      refresh_doctor_async = function()
        refresh_calls = refresh_calls + 1
      end,
      close_review = function() end,
    })

    add_stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("common:new-key")
    end)
    add_stub(ops, "rename", function()
      return false, "rename failed"
    end)
    add_stub(vim, "notify", function(msg)
      notify_msg = msg
    end)

    handlers.rename_item({
      source_buf = 3,
      config = { primary_lang = "en" },
      is_doctor_review = true,
      detail_item = {
        key = "common:old-key",
      },
    })

    assert.are.equal("i18n-status review: rename failed", notify_msg)
    assert.are.equal(0, refresh_calls)
  end)

  it("adds translations for a missing key and refreshes", function()
    local prompts = { "Hello", "こんにちは" }
    local written = nil
    local refresh_calls = 0
    local refresh_all_calls = 0
    local handlers = review_actions.new({
      refresh_doctor_async = function()
        refresh_calls = refresh_calls + 1
      end,
      close_review = function() end,
    })

    add_stub(vim.ui, "input", function(_, on_confirm)
      local next_value = table.remove(prompts, 1)
      on_confirm(next_value)
    end)
    add_stub(resources, "start_dir", function()
      return "/project"
    end)
    add_stub(key_write, "write_translations", function(namespace, key_path, translations, root, languages)
      written = {
        namespace = namespace,
        key_path = key_path,
        translations = vim.deepcopy(translations),
        root = root,
        languages = vim.deepcopy(languages),
      }
      return #languages, {}
    end)
    add_stub(core, "refresh_all", function()
      refresh_all_calls = refresh_all_calls + 1
    end)
    add_stub(vim, "notify", function() end)

    handlers.add_key({
      source_buf = 1,
      config = { primary_lang = "en" },
      cache = { languages = { "en", "ja" } },
      is_doctor_review = true,
      detail_item = {
        key = "common:new-key",
        status = "×",
      },
    })

    assert.are.same({
      namespace = "common",
      key_path = "new-key",
      translations = { en = "Hello", ja = "こんにちは" },
      root = "/project",
      languages = { "en", "ja" },
    }, written)
    assert.are.equal(1, refresh_all_calls)
    assert.are.equal(1, refresh_calls)
  end)

  it("jumps to the overview definition file for the display locale", function()
    local closed = 0
    local opened = nil
    local handlers = review_actions.new({
      refresh_doctor_async = function() end,
      close_review = function()
        closed = closed + 1
      end,
    })

    add_stub(resources, "start_dir", function()
      return "/project"
    end)
    add_stub(resources, "project_root", function(start_dir)
      return start_dir
    end)
    add_stub(util, "sanitize_path", function(path)
      return path, nil
    end)
    add_stub(vim.api, "nvim_cmd", function(cmd)
      opened = cmd.args[1]
    end)

    handlers.jump_to_definition({
      is_doctor_review = true,
      mode = "overview",
      display_lang = "ja",
      primary_lang = "en",
      detail_item = {
        hover = {
          values = {
            ja = { file = "/project/locales/ja/common.json" },
            en = { file = "/project/locales/en/common.json" },
          },
        },
      },
    })

    assert.are.equal(1, closed)
    assert.are.equal("/project/locales/ja/common.json", opened)
  end)
end)
