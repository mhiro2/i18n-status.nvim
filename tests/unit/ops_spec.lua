local ops = require("i18n-status.ops")
local config_mod = require("i18n-status.config")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")
local helpers = require("tests.helpers")

describe("ops.rename", function()
  local original_extract

  before_each(function()
    state.init("ja", { "ja", "en" })
    original_extract = scan.extract
  end)

  after_each(function()
    scan.extract = original_extract
  end)

  local function make_buf(path, line, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.bo[buf].filetype = ft or "typescript"
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  local function literal_range(buf, literal)
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    local start_byte = line:find('"' .. literal:gsub("(%p)", "%%%1") .. '"')
    assert.is_not_nil(start_byte, 'literal "' .. literal .. '" not found')
    local col = start_byte - 1
    local end_col = col + (#literal + 2)
    return col, end_col
  end

  it("renames key across resources and open buffers", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf1 = make_buf(root .. "/src/one.ts", 't("rename.title")')
      local buf2 = make_buf(root .. "/src/two.ts", 'const label = t("rename.title")')

      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      resources.ensure_index(root)

      local rename_spans = {}
      local function register_span(buf, literal)
        local col, end_col = literal_range(buf, literal)
        rename_spans[buf] = {
          {
            key = "common:rename.title",
            raw = literal,
            namespace = "common",
            lnum = 0,
            col = col,
            end_col = end_col,
          },
        }
      end

      register_span(buf1, "rename.title")
      register_span(buf2, "rename.title")

      scan.extract = function(bufnr)
        return rename_spans[bufnr] or {}
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
        source_buf = buf1,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_true(ok, err or "rename failed")

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
    end)
  end)

  it("aborts when target key already exists", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン","heading":"既存"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", 't("rename.title")')

      resources.ensure_index(root)

      local col, end_col = literal_range(buf, "rename.title")
      scan.extract = function()
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_col = end_col,
          },
        }
      end

      local config = config_mod.setup({ primary_lang = "ja" })
      local item = {
        key = "common:rename.title",
        namespace = "common",
        hover = {
          values = {
            ja = { file = root .. "/locales/ja/common.json", value = "ログイン" },
          },
        },
      }

      local ok, err = ops.rename({
        item = item,
        source_buf = buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err)

      local ja = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("ログイン", ja.rename.title)
      assert.are.equal("既存", ja.rename.heading)
    end)
  end)

  it("skips non-target filetypes when renaming", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local ts_buf = make_buf(root .. "/src/app.ts", 't("rename.title")', "typescript")
      local md_buf = make_buf(root .. "/src/notes.md", 't("rename.title")', "markdown")

      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local rename_spans = {}
      local function register_span(buf, literal)
        local col, end_col = literal_range(buf, literal)
        rename_spans[buf] = {
          {
            key = "common:rename.title",
            raw = literal,
            namespace = "common",
            lnum = 0,
            col = col,
            end_col = end_col,
          },
        }
      end
      register_span(ts_buf, "rename.title")
      register_span(md_buf, "rename.title")

      scan.extract = function(bufnr)
        return rename_spans[bufnr] or {}
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
        source_buf = ts_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_true(ok, err or "rename failed")

      local ts_line = vim.api.nvim_buf_get_lines(ts_buf, 0, 1, false)[1]
      local md_line = vim.api.nvim_buf_get_lines(md_buf, 0, 1, false)[1]
      assert.is_true(ts_line:find("rename.heading", 1, true) ~= nil)
      assert.is_true(md_line:find("rename.title", 1, true) ~= nil)
      assert.is_true(md_line:find("rename.heading", 1, true) == nil)
    end)
  end)

  it("returns failure when buffer text update fails during rename", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local col, end_col = literal_range(buf, "rename.title")
      scan.extract = function()
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_col = end_col,
          },
        }
      end

      local original_get_text = vim.api.nvim_buf_get_text
      local original_set_text = vim.api.nvim_buf_set_text
      vim.api.nvim_buf_get_text = function()
        error("simulated get_text failure")
      end
      vim.api.nvim_buf_set_text = function()
        error("simulated set_text failure")
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

      vim.api.nvim_buf_get_text = original_get_text
      vim.api.nvim_buf_set_text = original_set_text

      assert.is_false(ok)
      assert.is_truthy(err)
      assert.is_true(err:find("resource files were renamed", 1, true) ~= nil)
      local ja = vim.fn.json_decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.fn.json_decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_nil(ja.rename.title)
      assert.is_nil(en.rename.title)
      assert.are.equal("ログイン", ja.rename.heading)
      assert.are.equal("Login", en.rename.heading)
    end)
  end)
end)
