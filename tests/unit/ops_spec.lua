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
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
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

      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
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
      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
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

      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
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
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
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
      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
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
      assert.is_true(err:find("failed to read translation reference", 1, true) ~= nil)
      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("ログイン", ja.rename.title)
      assert.are.equal("Login", en.rename.title)
      assert.is_nil(ja.rename.heading)
      assert.is_nil(en.rename.heading)
    end)
  end)

  it("uses byte ranges without corrupting multibyte source", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", 'const 前置き = "値"; t("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local col, end_col = literal_range(buf, "rename.title")
      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
          },
        }
      end

      local ok, err = ops.rename({
        item = {
          key = "common:rename.title",
          namespace = "common",
          hover = {
            values = {
              ja = { file = root .. "/locales/ja/common.json", value = "ログイン" },
              en = { file = root .. "/locales/en/common.json", value = "Login" },
            },
          },
        },
        source_buf = buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_true(ok, err or "rename failed")
      assert.are.equal('const 前置き = "値"; t("rename.heading")', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    end)
  end)

  it("applies multiple edits on the same line from right to left", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source = 'const labels = [t("rename.title"), t("rename.title")]'
      local buf = make_buf(root .. "/src/app.ts", source)
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local first = assert(source:find('"rename.title"', 1, true)) - 1
      local second = assert(source:find('"rename.title"', first + 2, true)) - 1
      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        local function item_at(col)
          return {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_lnum = 0,
            end_col = col + #'"rename.title"',
            refactorable = true,
          }
        end
        return { item_at(first), item_at(second) }
      end

      local ok, err = ops.rename({
        item = {
          key = "common:rename.title",
          namespace = "common",
          hover = {
            values = {
              ja = { file = root .. "/locales/ja/common.json", value = "ログイン" },
              en = { file = root .. "/locales/en/common.json", value = "Login" },
            },
          },
        },
        source_buf = buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_true(ok, err or "rename failed")
      assert.are.equal(
        'const labels = [t("rename.heading"), t("rename.heading")]',
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      )
    end)
  end)

  it("refuses computed references before changing resources", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", "t(")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "t(",
        "  enabled",
        '    ? "rename.title"',
        '    : "other"',
        ")",
      })
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 1,
            col = 2,
            end_lnum = 3,
            end_col = 13,
            refactorable = false,
          },
        }
      end

      local ok, err = ops.rename({
        item = {
          key = "common:rename.title",
          namespace = "common",
          hover = {
            values = {
              ja = { file = root .. "/locales/ja/common.json", value = "ログイン" },
              en = { file = root .. "/locales/en/common.json", value = "Login" },
            },
          },
        },
        source_buf = buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("computed translation reference", 1, true))
      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("ログイン", ja.rename.title)
      assert.are.equal("Login", en.rename.title)
      assert.is_nil(ja.rename.heading)
      assert.is_nil(en.rename.heading)
    end)
  end)

  it("rejects unsafe key syntax before changing source or resources", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      for _, new_key in ipairs({ 'common:rename."heading', [[common:rename.\heading]] }) do
        local ok, err = ops.rename({
          item = { key = "common:rename.title", namespace = "common" },
          source_buf = buf,
          new_key = new_key,
          config = config,
        })

        assert.is_false(ok)
        assert.is_truthy(err and err:find("invalid key path format", 1, true))
      end
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("ログイン", ja.rename.title)
    end)
  end)

  it("rejects resource file paths outside project root", function()
    local root = helpers.tmpdir()
    local outside_root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"rename":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"rename":{"title":"Login"}}')
    helpers.write_file(outside_root .. "/common.json", '{"rename":{"title":"Outside"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)

      local col, end_col = literal_range(buf, "rename.title")
      scan.extract = function(bufnr)
        if bufnr ~= buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = col,
            end_lnum = 0,
            end_col = end_col,
            refactorable = true,
          },
        }
      end

      local item = {
        key = "common:rename.title",
        namespace = "common",
        hover = {
          values = {
            ja = { file = outside_root .. "/common.json", value = "Outside" },
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

      assert.is_false(ok)
      assert.is_truthy(err and err:find("outside project root", 1, true))

      local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("ログイン", ja.rename.title)
      assert.are.equal("Login", en.rename.title)
      assert.is_nil(ja.rename.heading)
      assert.is_nil(en.rename.heading)
    end)
  end)
end)
