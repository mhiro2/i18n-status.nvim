local core = require("i18n-status.core")
local render = require("i18n-status.render")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")
local key_write = require("i18n-status.key_write")
local ops = require("i18n-status.ops")
local scan = require("i18n-status.scan")

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

describe("failure scenarios", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("recovers when a language disappears", function()
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
      local project, project_key = state.project_for_buf(buf)
      assert.is_true(#project.languages >= 2)
      state.set_current(project_key, "en")

      vim.fn.delete(root .. "/locales/en", "rf")
      core.refresh_now(buf, config)

      project = state.project_for_key(project_key)
      assert.are.equal("ja", project.current_lang)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)
    end)
  end)

  it("renders without crash when resolved has fewer items than scan", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")', 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      -- Provide fewer resolved items than scan items to simulate resolve failure
      local items = {
        { lnum = 0, col = 0, end_col = 15, key = "common:login.title" },
        { lnum = 1, col = 0, end_col = 15, key = "common:login.title" },
      }
      local resolved = {
        { text = "ログイン", status = "=" },
        -- second item intentionally nil
      }

      -- Should not crash
      local ok, err = pcall(render.apply, buf, items, resolved, config)
      assert.is_true(ok, err)

      -- First item should still have a mark
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal(1, #marks)
    end)
  end)

  it("write_json_table returns false on write failure", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"key":"value"}')
    helpers.with_cwd(root, function()
      -- Make the target path a directory to force write failure
      local bad_path = root .. "/readonly_dir"
      vim.fn.mkdir(bad_path, "p")
      -- Writing to a directory path should fail
      local original_notify = vim.notify
      vim.notify = function() end
      local ok, err = resources.write_json_table(bad_path, { a = "b" }, { indent = "  " })
      vim.notify = original_notify
      assert.is_false(ok)
      assert.is_truthy(err)
    end)
  end)

  it("key_write returns false when write_json_table fails", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"key":"value"}')
    helpers.with_cwd(root, function()
      resources.ensure_index(root)

      -- Stub write_json_table to simulate failure
      local original_write = resources.write_json_table
      resources.write_json_table = function()
        return false, "simulated failure"
      end

      local ok = key_write.write_single_translation("common", "new.key", "ja", "test", root)

      resources.write_json_table = original_write
      assert.is_false(ok)
    end)
  end)

  it("ops.rename returns false when write_json_table fails", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      state.init("ja", { "ja", "en" })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("rename.title")' })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_buf_set_name(buf, root .. "/src/app.ts")
      vim.api.nvim_set_current_buf(buf)

      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local original_extract = scan.extract
      scan.extract = function()
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = 2,
            end_col = 16,
          },
        }
      end

      -- Stub write_json_table to simulate failure
      local original_write = resources.write_json_table
      resources.write_json_table = function()
        return false, "disk full"
      end

      local item = {
        key = "common:rename.title",
        namespace = "common",
        hover = {
          values = {
            ja = { file = root .. "/locales/ja/common.json", value = "ログイン" },
            en = { file = root .. "/locales/en/common.json", value = "Login" },
          },
        },
      }

      local ok, err = ops.rename({
        item = item,
        source_buf = buf,
        new_key = "common:rename.heading",
        config = config,
      })

      resources.write_json_table = original_write
      scan.extract = original_extract

      assert.is_false(ok)
      assert.is_truthy(err and err:find("disk full", 1, true))
    end)
  end)

  it("handles large buffers without error", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local lines = {}
    for _ = 1, 400 do
      table.insert(lines, 't("login.title")')
    end
    helpers.with_cwd(root, function()
      local buf = make_buf(lines)
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)
    end)
  end)
end)
