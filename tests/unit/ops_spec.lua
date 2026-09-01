local ops = require("i18n-status.ops")
local config_mod = require("i18n-status.config")
local fs = require("i18n-status.fs")
local project_identity = require("i18n-status.project_identity")
local state = require("i18n-status.state")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")
local core = require("i18n-status.core")
local helpers = require("tests.helpers")

describe("ops.rename", function()
  local original_extract
  local original_extract_for_refactor

  before_each(function()
    state.init("ja", { "ja", "en" })
    original_extract = scan.extract
    original_extract_for_refactor = scan.extract_for_refactor
    scan.extract_for_refactor = function(bufnr, opts)
      local items = scan.extract(bufnr, opts)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return items,
        {
          bufnr = bufnr,
          tick = vim.api.nvim_buf_get_changedtick(bufnr),
          source = table.concat(lines, "\n"),
          lines = lines,
          name = vim.api.nvim_buf_get_name(bufnr),
          filetype = vim.bo[bufnr].filetype,
        }
    end
  end)

  after_each(function()
    scan.extract = original_extract
    scan.extract_for_refactor = original_extract_for_refactor
  end)

  local function make_buf(path, line, ft)
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
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

  local function span(buf, literal)
    local col, end_col = literal_range(buf, literal)
    return {
      key = "common:rename.title",
      raw = literal,
      namespace = "common",
      lnum = 0,
      col = col,
      end_lnum = 0,
      end_col = end_col,
      refactorable = true,
    }
  end

  local function rename_item(ja_path, en_path)
    return {
      key = "common:rename.title",
      namespace = "common",
      hover = {
        values = {
          ja = { file = ja_path, value = "ログイン" },
          en = { file = en_path, value = "Login" },
        },
      },
    }
  end

  local function with_overrides(overrides, callback)
    local originals = {}
    for _, entry in ipairs(overrides) do
      originals[#originals + 1] = { target = entry.target, key = entry.key, value = entry.target[entry.key] }
      entry.target[entry.key] = entry.value
    end
    local result = { pcall(callback) }
    for index = #originals, 1, -1 do
      local original = originals[index]
      original.target[original.key] = original.value
    end
    if not result[1] then
      error(result[2])
    end
    return result[2], result[3]
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

  it("keeps next-intl namespace moves inside each language root file", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/messages/ja.json"
    local en_path = root .. "/messages/en.json"
    helpers.write_file(ja_path, '{"common":{"rename":{"title":"ログイン"}}}')
    helpers.write_file(en_path, '{"common":{"rename":{"title":"Login"}}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      local source_span = span(source_buf, "rename.title")
      scan.extract = function(bufnr)
        return bufnr == source_buf and { source_span } or {}
      end

      local ok, err = ops.rename({
        item = rename_item(ja_path, en_path),
        source_buf = source_buf,
        new_key = "account:rename.heading",
        config = config,
      })

      assert.is_true(ok, err)
      local ja = vim.json.decode(helpers.read_file(ja_path))
      local en = vim.json.decode(helpers.read_file(en_path))
      assert.is_nil(ja.common.rename.title)
      assert.is_nil(en.common.rename.title)
      assert.are.equal("ログイン", ja.account.rename.heading)
      assert.are.equal("Login", en.account.rename.heading)
      assert.are.equal('t("account:rename.heading")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.is_nil(vim.uv.fs_stat(root .. "/messages/ja/account.json"))
      assert.is_nil(vim.uv.fs_stat(root .. "/messages/en/account.json"))
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

  it("rejects a target in another resource root when the old key is missing", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_target_path = root .. "/messages/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}'
    local original_en = '{"rename":{"heading":"Unrelated"}}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_target_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja" })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local ok, err = ops.rename({
        item = {
          key = "common:rename.title",
          namespace = "common",
          hover = {
            values = {
              ja = { file = ja_path, value = "ログイン" },
              en = { missing = true },
            },
          },
        },
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("target key already exists (en)", 1, true))
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_target_path))
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

  it("rejects a scanner range that points at a different literal", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}'
    local original_en = '{"rename":{"title":"Login"}}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source = 'const unrelated = "other"; t("rename.title")'
      local source_buf = make_buf(root .. "/src/app.ts", source)
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      local col, end_col = literal_range(source_buf, "other")
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
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
        item = rename_item(ja_path, en_path),
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("does not match scanner value", 1, true))
      assert.are.equal(source, vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("rejects an escaped template whose spelling differs from its runtime key", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}'
    local original_en = '{"rename":{"title":"Login"}}'
    local source = [[t(`rename.\u0074itle`)]]
    local literal = [[`rename.\u0074itle`]]
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", source)
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      local start_byte = assert(source:find(literal, 1, true))
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
          return {}
        end
        return {
          {
            key = "common:rename.title",
            raw = "rename.title",
            namespace = "common",
            lnum = 0,
            col = start_byte - 1,
            end_lnum = 0,
            end_col = start_byte - 1 + #literal,
            refactorable = true,
          },
        }
      end

      local ok, err = ops.rename({
        item = rename_item(ja_path, en_path),
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("does not match scanner value", 1, true))
      assert.are.equal(source, vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("rejects a descendant key move", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"a":"ログイン"}'
    local original_en = '{"a":"Login"}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("a")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      local col, end_col = literal_range(source_buf, "a")
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
          return {}
        end
        return {
          {
            key = "common:a",
            raw = "a",
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
          key = "common:a",
          namespace = "common",
          hover = {
            values = {
              ja = { file = ja_path, value = "ログイン" },
              en = { file = en_path, value = "Login" },
            },
          },
        },
        source_buf = source_buf,
        new_key = "common:a.child",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("own descendant", 1, true))
      assert.are.equal('t("a")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("rejects a cached translation leaf that changed to an object", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"a":"ログイン"}'
    local original_en = '{"a":"Login"}'
    local concurrent_ja = '{"a":{"b":"新しい値"}}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("a")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      local col, end_col = literal_range(source_buf, "a")
      local injected = false
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
          return {}
        end
        if not injected then
          injected = true
          helpers.write_file(ja_path, concurrent_ja)
        end
        return {
          {
            key = "common:a",
            raw = "a",
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
          key = "common:a",
          namespace = "common",
          hover = {
            values = {
              ja = { file = ja_path, value = "ログイン" },
              en = { file = en_path, value = "Login" },
            },
          },
        },
        source_buf = source_buf,
        new_key = "common:c",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("no longer a translation leaf", 1, true))
      assert.are.equal('t("a")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(concurrent_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
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

  it("rejects rename while a target resource buffer has unsaved changes", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    helpers.write_file(ja_path, '{"rename":{"title":"ログイン"}}')
    helpers.write_file(en_path, '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local resource_buf = vim.api.nvim_create_buf(true, false)
      vim.bo[resource_buf].swapfile = false
      vim.api.nvim_buf_set_name(resource_buf, ja_path)
      vim.api.nvim_buf_set_lines(resource_buf, 0, -1, false, { '{"rename":{"title":"未保存"}}' })
      vim.bo[resource_buf].modified = true
      local config = config_mod.setup({ primary_lang = "ja" })
      resources.ensure_index(root)

      local col, end_col = literal_range(source_buf, "rename.title")
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
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
              ja = { file = ja_path, value = "ログイン" },
              en = { file = en_path, value = "Login" },
            },
          },
        },
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("unsaved changes", 1, true))
      assert.are.equal("ログイン", vim.json.decode(helpers.read_file(ja_path)).rename.title)
      assert.are.equal("Login", vim.json.decode(helpers.read_file(en_path)).rename.title)
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      vim.api.nvim_buf_delete(resource_buf, { force = true })
    end)
  end)

  it("rejects a namespace file symlinked outside the project", function()
    local root = helpers.tmpdir()
    local outside_root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local outside_ja = outside_root .. "/ja.json"
    local outside_en = outside_root .. "/en.json"
    local outside_ja_bytes = '{"sentinel":"ja"}'
    local outside_en_bytes = '{"sentinel":"en"}'
    helpers.write_file(ja_path, '{"rename":{"title":"ログイン"}}')
    helpers.write_file(en_path, '{"rename":{"title":"Login"}}')
    helpers.write_file(outside_ja, outside_ja_bytes)
    helpers.write_file(outside_en, outside_en_bytes)
    vim.fn.mkdir(root .. "/src", "p")

    local ja_link_ok, ja_link_err = vim.uv.fs_symlink(outside_ja, root .. "/locales/ja/escape.json")
    assert.is_truthy(ja_link_ok, ja_link_err)
    local en_link_ok, en_link_err = vim.uv.fs_symlink(outside_en, root .. "/locales/en/escape.json")
    assert.is_truthy(en_link_ok, en_link_err)

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja" })
      resources.ensure_index(root)

      local col, end_col = literal_range(source_buf, "rename.title")
      scan.extract = function(bufnr)
        if bufnr ~= source_buf then
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
              ja = { file = ja_path, value = "ログイン" },
              en = { file = en_path, value = "Login" },
            },
          },
        },
        source_buf = source_buf,
        new_key = "escape:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("outside project root", 1, true))
      assert.are.equal("ログイン", vim.json.decode(helpers.read_file(ja_path)).rename.title)
      assert.are.equal("Login", vim.json.decode(helpers.read_file(en_path)).rename.title)
      assert.are.equal(outside_ja_bytes, helpers.read_file(outside_ja))
      assert.are.equal(outside_en_bytes, helpers.read_file(outside_en))
    end)

    vim.fn.delete(outside_root, "rf")
  end)

  it("rejects path separators in a new namespace before mutating files", function()
    local root = helpers.tmpdir()
    local outside_root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    helpers.write_file(ja_path, '{"rename":{"title":"ログイン"}}')
    helpers.write_file(en_path, '{"rename":{"title":"Login"}}')
    vim.fn.mkdir(root .. "/src", "p")
    local link_path = root .. "/locales/ja/escape"
    local link_ok, link_err = vim.uv.fs_symlink(outside_root, link_path, { dir = true })
    assert.is_truthy(link_ok, link_err)
    local en_link_path = root .. "/locales/en/escape"
    local en_link_ok, en_link_err = vim.uv.fs_symlink(outside_root, en_link_path, { dir = true })
    assert.is_truthy(en_link_ok, en_link_err)

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja" })
      resources.ensure_index(root)

      local ok, err = ops.rename({
        item = {
          key = "common:rename.title",
          namespace = "common",
          hover = {
            values = {
              ja = { file = ja_path, value = "ログイン" },
              en = { file = en_path, value = "Login" },
            },
          },
        },
        source_buf = source_buf,
        new_key = "escape/new:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("invalid namespace format", 1, true))
      assert.are.equal("ログイン", vim.json.decode(helpers.read_file(ja_path)).rename.title)
      assert.are.equal("Login", vim.json.decode(helpers.read_file(en_path)).rename.title)
      assert.is_nil(vim.uv.fs_stat(outside_root .. "/new.json"))
    end)

    vim.fn.delete(outside_root, "rf")
  end)

  it("scans and mutates only loaded source buffers in the initiating canonical project", function()
    local root = helpers.tmpdir()
    local other_root = root .. "/nested-project"
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local other_ja_path = other_root .. "/locales/ja/common.json"
    local other_en_path = other_root .. "/locales/en/common.json"
    helpers.write_file(ja_path, '{"rename":{"title":"ログイン"}}')
    helpers.write_file(en_path, '{"rename":{"title":"Login"}}')
    helpers.write_file(other_ja_path, '{"rename":{"title":"別プロジェクト"}}')
    helpers.write_file(other_en_path, '{"rename":{"title":"Other project"}}')
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.mkdir(other_root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local other_buf = make_buf(other_root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      resources.ensure_index(other_root)

      local scanned = {}
      scan.extract = function(bufnr)
        scanned[#scanned + 1] = bufnr
        if bufnr == source_buf then
          local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
          return line:find("rename.title", 1, true) and { span(source_buf, "rename.title") } or {}
        end
        error("another project must not be scanned")
      end

      local ok, err = ops.rename({
        item = rename_item(ja_path, en_path),
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_true(ok, err)
      assert.is_true(#scanned >= 1)
      for _, scanned_buf in ipairs(scanned) do
        assert.are.equal(source_buf, scanned_buf)
      end
      assert.are.equal('t("rename.heading")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(other_buf, 0, 1, false)[1])
      assert.are.equal('{"rename":{"title":"別プロジェクト"}}', helpers.read_file(other_ja_path))
      assert.are.equal('{"rename":{"title":"Other project"}}', helpers.read_file(other_en_path))
    end)
  end)

  it("rejects stale resource locations from another project in the same repository", function()
    local repo = helpers.tmpdir()
    local project_a = repo .. "/packages/a"
    local project_b = repo .. "/packages/b"
    local a_ja = project_a .. "/locales/ja/common.json"
    local a_en = project_a .. "/locales/en/common.json"
    local b_ja = project_b .. "/locales/ja/common.json"
    local b_en = project_b .. "/locales/en/common.json"
    vim.fn.mkdir(repo .. "/.git", "p")
    helpers.write_file(a_ja, '{"rename":{"title":"プロジェクトA"}}')
    helpers.write_file(a_en, '{"rename":{"title":"Project A"}}')
    helpers.write_file(b_ja, '{"rename":{"title":"プロジェクトB"}}')
    helpers.write_file(b_en, '{"rename":{"title":"Project B"}}')
    vim.fn.mkdir(project_b .. "/src", "p")

    helpers.with_cwd(repo, function()
      local source_buf = make_buf(project_b .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(project_a)
      resources.ensure_index(project_b)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local ok, err = ops.rename({
        item = rename_item(a_ja, a_en),
        source_buf = source_buf,
        new_key = "common:rename.heading",
        config = config,
      })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("resource location", 1, true))
      assert.is_truthy(err and err:find("refresh before renaming", 1, true))
      assert.are.equal('{"rename":{"title":"プロジェクトA"}}', helpers.read_file(a_ja))
      assert.are.equal('{"rename":{"title":"Project A"}}', helpers.read_file(a_en))
      assert.are.equal('{"rename":{"title":"プロジェクトB"}}', helpers.read_file(b_ja))
      assert.are.equal('{"rename":{"title":"Project B"}}', helpers.read_file(b_en))
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
    end)
  end)

  it("rolls back exact source and resource bytes after the second resource commit fails", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{ "rename": { "title": "ログイン" } }\n'
    local original_en = '{ "rename": { "title": "Login" } }\n'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local first_buf = make_buf(root .. "/src/a.ts", 'const a = t("rename.title")')
      local second_buf = make_buf(root .. "/src/b.ts", 'const b = t("rename.title")')
      vim.bo[first_buf].modified = false
      vim.bo[second_buf].modified = false
      local first_source = vim.api.nvim_buf_get_lines(first_buf, 0, 1, false)[1]
      local second_source = vim.api.nvim_buf_get_lines(second_buf, 0, 1, false)[1]
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        if bufnr == first_buf or bufnr == second_buf then
          return { span(bufnr, "rename.title") }
        end
        return {}
      end

      local original_commit = resources.commit_json_write
      local original_rollback = resources.rollback_json_write
      local original_discard = resources.discard_json_write
      local original_validate_identity = project_identity.validate
      local commits = 0
      local identity_validations = 0
      local rollbacks = {}
      local cleanups = {}
      local refreshes = 0
      local language_updates = 0
      local project_updates = 0
      local ok, err = with_overrides({
        {
          target = project_identity,
          key = "validate",
          value = function(...)
            identity_validations = identity_validations + 1
            if identity_validations > 4 then
              error("resource identity must not be resolved during source rollback")
            end
            return original_validate_identity(...)
          end,
        },
        {
          target = resources,
          key = "commit_json_write",
          value = function(plan)
            commits = commits + 1
            if commits == 2 then
              return false, "injected second locale failure"
            end
            return original_commit(plan)
          end,
        },
        {
          target = resources,
          key = "rollback_json_write",
          value = function(plan)
            rollbacks[#rollbacks + 1] = plan.atomic.target
            return original_rollback(plan)
          end,
        },
        {
          target = resources,
          key = "discard_json_write",
          value = function(plan)
            cleanups[#cleanups + 1] = plan.atomic.target
            return original_discard(plan)
          end,
        },
        {
          target = core,
          key = "refresh_now",
          value = function()
            refreshes = refreshes + 1
          end,
        },
        {
          target = state,
          key = "set_languages",
          value = function()
            language_updates = language_updates + 1
          end,
        },
        {
          target = state,
          key = "set_buf_project",
          value = function()
            project_updates = project_updates + 1
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = first_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("injected second locale failure", 1, true))
      assert.are.equal(2, commits)
      assert.are.equal(4, identity_validations)
      local canonical_ja = assert(vim.uv.fs_realpath(ja_path))
      local canonical_en = assert(vim.uv.fs_realpath(en_path))
      assert.are.same({ canonical_en }, rollbacks)
      assert.are.same({ canonical_ja, canonical_en }, cleanups)
      assert.are.equal(first_source, vim.api.nvim_buf_get_lines(first_buf, 0, 1, false)[1])
      assert.are.equal(second_source, vim.api.nvim_buf_get_lines(second_buf, 0, 1, false)[1])
      assert.is_false(vim.bo[first_buf].modified)
      assert.is_false(vim.bo[second_buf].modified)
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
      assert.are.equal(0, refreshes)
      assert.are.equal(0, language_updates)
      assert.are.equal(0, project_updates)
    end)
  end)

  it("rolls back a resource participant that fails after its atomic commit", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}\n'
    local original_en = '{"rename":{"title":"Login"}}\n'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local original_commit = resources.commit_json_write
      local original_rollback = resources.rollback_json_write
      local commits = 0
      local rollbacks = {}
      local ok, err = with_overrides({
        {
          target = resources,
          key = "commit_json_write",
          value = function(plan)
            commits = commits + 1
            local committed, commit_err = original_commit(plan)
            assert.is_true(committed, commit_err)
            return false, "injected post-commit failure"
          end,
        },
        {
          target = resources,
          key = "rollback_json_write",
          value = function(plan)
            rollbacks[#rollbacks + 1] = plan.atomic.target
            return original_rollback(plan)
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = source_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("injected post-commit failure", 1, true))
      assert.are.equal(1, commits)
      assert.are.same({ assert(vim.uv.fs_realpath(en_path)) }, rollbacks)
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("protects recovery artifacts when resource rollback raises", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    helpers.write_file(ja_path, '{"rename":{"title":"ログイン"}}\n')
    helpers.write_file(en_path, '{"rename":{"title":"Login"}}\n')
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source = 't("rename.title")'
      local source_buf = make_buf(root .. "/src/app.ts", source)
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local original_commit = resources.commit_json_write
      local original_protect = resources.protect_json_write
      local commits = 0
      local protected_plan
      local ok, err = with_overrides({
        {
          target = resources,
          key = "commit_json_write",
          value = function(plan)
            commits = commits + 1
            if commits == 2 then
              return false, "injected later resource failure"
            end
            return original_commit(plan)
          end,
        },
        {
          target = resources,
          key = "rollback_json_write",
          value = function()
            error("injected rollback exception")
          end,
        },
        {
          target = resources,
          key = "protect_json_write",
          value = function(plan)
            protected_plan = plan
            return original_protect(plan)
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = source_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("resource rollback raised", 1, true))
      assert.is_truthy(err and err:find("protected recovery files", 1, true))
      assert.are.equal(2, commits)
      assert.is_not_nil(protected_plan)
      assert.are.equal(source, vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])

      local preserved_original = false
      for name, disposition in pairs(protected_plan.atomic.artifacts) do
        if disposition == "protect" then
          local path = vim.fs.joinpath(protected_plan.atomic.parent_path, name)
          local read_ok, bytes = pcall(helpers.read_file, path)
          if read_ok and bytes == protected_plan.atomic.expected.content then
            preserved_original = true
          end
        end
      end
      assert.is_true(preserved_original)
    end)
  end)

  it("discards staged resources when a later directory revalidation fails", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}\n'
    local original_en = '{"rename":{"title":"Login"}}\n'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local original_ensure_dir = fs.ensure_dir_within
      local original_prepare = resources.prepare_json_write
      local original_discard = resources.discard_json_write
      local prepared_count = 0
      local discarded_count = 0
      local prepared_plan
      local stage_path
      local ok, err = with_overrides({
        {
          target = fs,
          key = "ensure_dir_within",
          value = function(...)
            if prepared_count == 1 then
              return false, "injected directory replacement"
            end
            return original_ensure_dir(...)
          end,
        },
        {
          target = resources,
          key = "prepare_json_write",
          value = function(...)
            local plan, prepare_err = original_prepare(...)
            if plan then
              prepared_count = prepared_count + 1
              prepared_plan = plan
              stage_path = plan.atomic.stage
            end
            return plan, prepare_err
          end,
        },
        {
          target = resources,
          key = "discard_json_write",
          value = function(plan)
            discarded_count = discarded_count + 1
            return original_discard(plan)
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = source_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("injected directory replacement", 1, true))
      assert.are.equal(1, prepared_count)
      assert.are.equal(1, discarded_count)
      assert.is_true(prepared_plan.atomic.closed)
      assert.is_nil(vim.uv.fs_stat(stage_path))
      assert.are.equal('t("rename.title")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("finishes every preflight before mutating source or resources", function()
    for _, scenario in ipairs({ "stale resource", "renamed source", "changed source" }) do
      local root = helpers.tmpdir()
      local ja_path = root .. "/locales/ja/common.json"
      local en_path = root .. "/locales/en/common.json"
      local original_ja = '{"rename":{"title":"ログイン"}}'
      local original_en = '{"rename":{"title":"Login"}}'
      helpers.write_file(ja_path, original_ja)
      helpers.write_file(en_path, original_en)
      vim.fn.mkdir(root .. "/src", "p")

      helpers.with_cwd(root, function()
        local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
        local expected_source = 't("rename.title")'
        local expected_name = vim.api.nvim_buf_get_name(source_buf)
        local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
        resources.ensure_index(root)
        scan.extract = function(bufnr)
          return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
        end

        local original_prepare = resources.prepare_json_write
        local original_discard = resources.discard_json_write
        local injected = false
        local commits = 0
        local cleanups = 0
        local overrides = {
          {
            target = resources,
            key = "commit_json_write",
            value = function()
              commits = commits + 1
              error("preflight failure must prevent commit")
            end,
          },
          {
            target = resources,
            key = "discard_json_write",
            value = function(plan)
              cleanups = cleanups + 1
              return original_discard(plan)
            end,
          },
        }
        if scenario == "stale resource" then
          overrides[#overrides + 1] = {
            target = resources,
            key = "validate_json_write",
            value = function()
              return false, "injected stale resource"
            end,
          }
        else
          overrides[#overrides + 1] = {
            target = resources,
            key = "prepare_json_write",
            value = function(...)
              local plan, prepare_err = original_prepare(...)
              if plan and not injected then
                injected = true
                if scenario == "renamed source" then
                  vim.api.nvim_buf_set_name(source_buf, root .. "/src/renamed.ts")
                  expected_name = vim.api.nvim_buf_get_name(source_buf)
                else
                  expected_source = 't("user.changed")'
                  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { expected_source })
                end
              end
              return plan, prepare_err
            end,
          }
        end

        local ok, err = with_overrides(overrides, function()
          return ops.rename({
            item = rename_item(ja_path, en_path),
            source_buf = source_buf,
            new_key = "common:rename.heading",
            config = config,
          })
        end)

        assert.is_false(ok, scenario)
        if scenario == "stale resource" then
          assert.is_truthy(err and err:find("injected stale resource", 1, true))
        elseif scenario == "renamed source" then
          assert.is_truthy(err and err:find("source buffer name changed", 1, true))
        else
          assert.is_truthy(err and err:find("source buffer changed before rename", 1, true))
        end
        assert.are.equal(0, commits)
        assert.are.equal(2, cleanups)
        assert.are.equal(expected_name, vim.api.nvim_buf_get_name(source_buf))
        assert.are.equal(expected_source, vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
        assert.are.equal(original_ja, helpers.read_file(ja_path))
        assert.are.equal(original_en, helpers.read_file(en_path))
      end)
    end
  end)

  it("rolls back an earlier source buffer when a later source apply fails", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}'
    local original_en = '{"rename":{"title":"Login"}}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local first_buf = make_buf(root .. "/src/a.ts", 'const a = t("rename.title")')
      local second_buf = make_buf(root .. "/src/b.ts", 'const b = t("rename.title")')
      vim.bo[first_buf].modified = false
      vim.bo[second_buf].modified = false
      local first_source = vim.api.nvim_buf_get_lines(first_buf, 0, 1, false)[1]
      local second_source = vim.api.nvim_buf_get_lines(second_buf, 0, 1, false)[1]
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        if bufnr == first_buf or bufnr == second_buf then
          return { span(bufnr, "rename.title") }
        end
        return {}
      end

      local original_set_text = vim.api.nvim_buf_set_text
      local resource_commits = 0
      local ok, err = with_overrides({
        {
          target = vim.api,
          key = "nvim_buf_set_text",
          value = function(bufnr, ...)
            if bufnr == second_buf then
              error("injected source apply failure")
            end
            return original_set_text(bufnr, ...)
          end,
        },
        {
          target = resources,
          key = "commit_json_write",
          value = function()
            resource_commits = resource_commits + 1
            error("resource commit must not run")
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = first_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("injected source apply failure", 1, true))
      assert.are.equal(0, resource_commits)
      assert.are.equal(first_source, vim.api.nvim_buf_get_lines(first_buf, 0, 1, false)[1])
      assert.are.equal(second_source, vim.api.nvim_buf_get_lines(second_buf, 0, 1, false)[1])
      assert.is_false(vim.bo[first_buf].modified)
      assert.is_false(vim.bo[second_buf].modified)
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("preserves an unplanned source mutation produced during apply", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}'
    local original_en = '{"rename":{"title":"Login"}}'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      vim.bo[source_buf].modified = false
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local original_set_text = vim.api.nvim_buf_set_text
      local resource_commits = 0
      local ok, err = with_overrides({
        {
          target = vim.api,
          key = "nvim_buf_set_text",
          value = function(bufnr, start_row, start_col, end_row, end_col)
            return original_set_text(bufnr, start_row, start_col, end_row, end_col, { '"concurrent.source"' })
          end,
        },
        {
          target = resources,
          key = "commit_json_write",
          value = function()
            resource_commits = resource_commits + 1
            error("resource commit must not run")
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = source_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("rollback errors", 1, true))
      assert.is_truthy(err and err:find("preserving concurrent edits", 1, true))
      assert.are.equal(0, resource_commits)
      assert.are.equal('t("concurrent.source")', vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.is_true(vim.bo[source_buf].modified)
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  it("preserves concurrent source and resource bytes when rollback CAS checks fail", function()
    local root = helpers.tmpdir()
    local ja_path = root .. "/locales/ja/common.json"
    local en_path = root .. "/locales/en/common.json"
    local original_ja = '{"rename":{"title":"ログイン"}}\n'
    local original_en = '{"rename":{"title":"Login"}}\n'
    local concurrent_resource = '{"concurrent":"resource"}\n'
    local concurrent_source = 't("concurrent.source")'
    helpers.write_file(ja_path, original_ja)
    helpers.write_file(en_path, original_en)
    vim.fn.mkdir(root .. "/src", "p")

    helpers.with_cwd(root, function()
      local source_buf = make_buf(root .. "/src/app.ts", 't("rename.title")')
      vim.bo[source_buf].modified = false
      local config = config_mod.setup({ primary_lang = "ja", inline = { visible_only = false } })
      resources.ensure_index(root)
      scan.extract = function(bufnr)
        return bufnr == source_buf and { span(source_buf, "rename.title") } or {}
      end

      local original_commit = resources.commit_json_write
      local original_discard = resources.discard_json_write
      local first_resource
      local first_plan
      local commits = 0
      local cleanups = 0
      local refreshes = 0
      local language_updates = 0
      local project_updates = 0
      local ok, err = with_overrides({
        {
          target = resources,
          key = "commit_json_write",
          value = function(plan)
            commits = commits + 1
            if commits == 1 then
              local committed, commit_err = original_commit(plan)
              assert.is_true(committed, commit_err)
              first_plan = plan
              first_resource = plan.atomic.target
              return true
            end
            vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { concurrent_source })
            helpers.write_file(first_resource, concurrent_resource)
            return false, "injected later resource failure"
          end,
        },
        {
          target = resources,
          key = "discard_json_write",
          value = function(plan)
            cleanups = cleanups + 1
            return original_discard(plan)
          end,
        },
        {
          target = core,
          key = "refresh_now",
          value = function()
            refreshes = refreshes + 1
          end,
        },
        {
          target = state,
          key = "set_languages",
          value = function()
            language_updates = language_updates + 1
          end,
        },
        {
          target = state,
          key = "set_buf_project",
          value = function()
            project_updates = project_updates + 1
          end,
        },
      }, function()
        return ops.rename({
          item = rename_item(ja_path, en_path),
          source_buf = source_buf,
          new_key = "common:rename.heading",
          config = config,
        })
      end)

      assert.is_false(ok)
      assert.is_truthy(err and err:find("rollback errors", 1, true))
      assert.is_truthy(err and err:find("preserving concurrent", 1, true))
      assert.are.equal(2, commits)
      assert.are.equal(2, cleanups)
      assert.are.equal(concurrent_source, vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1])
      assert.is_true(vim.bo[source_buf].modified)
      local canonical_ja = assert(vim.uv.fs_realpath(ja_path))
      local canonical_en = assert(vim.uv.fs_realpath(en_path))
      local original_first = first_resource == canonical_en and original_en or original_ja
      assert.are.equal(concurrent_resource, helpers.read_file(first_resource))
      local preserved_original = false
      for name, disposition in pairs(first_plan.atomic.artifacts) do
        if disposition == "protect" then
          local candidate = vim.fs.joinpath(first_plan.atomic.parent_path, name)
          local read_ok, bytes = pcall(helpers.read_file, candidate)
          if read_ok and bytes == original_first then
            preserved_original = true
          end
        end
      end
      assert.is_true(preserved_original)
      local untouched_path = first_resource == canonical_en and canonical_ja or canonical_en
      local untouched_bytes = untouched_path == canonical_ja and original_ja or original_en
      assert.are.equal(untouched_bytes, helpers.read_file(untouched_path))
      assert.are.equal(0, refreshes)
      assert.are.equal(0, language_updates)
      assert.are.equal(0, project_updates)
    end)
  end)
end)
