local config_mod = require("i18n-status.config")
local extract = require("i18n-status.extract")
local helpers = require("tests.helpers")

local function make_buf(lines, ft, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

local function skip_if_no_parser(buf, lang, fallback_lang)
  local ok = pcall(vim.treesitter.get_parser, buf, lang)
  if ok then
    return false
  end
  if fallback_lang then
    local ok_fallback = pcall(vim.treesitter.get_parser, buf, fallback_lang)
    if ok_fallback then
      return false
    end
  end
  pending("treesitter parser not available: " .. lang)
  return true
end

describe("extract integration", function()
  local original_input

  before_each(function()
    original_input = vim.ui.input
  end)

  after_each(function()
    vim.ui.input = original_input
  end)

  it("extracts hardcoded JSX text with alias function and skips Trans", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t: tr } = useTranslation("common")',
        "export function Page() {",
        '  return <><p>Hello world</p><Trans i18nKey="common:already">Ignore</Trans></>',
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end
      local cfg = config_mod.setup({ primary_lang = "ja" })

      vim.ui.input = function(opts, on_confirm)
        on_confirm(opts.default)
      end

      extract.run(buf, cfg, {})

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[3]:find('{tr("common:hello-world")}', 1, true) ~= nil)
      assert.is_true(lines[3]:find("<Trans", 1, true) ~= nil)
      assert.is_true(lines[3]:find("Ignore", 1, true) ~= nil)

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en_data = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("Hello world", ja_data["hello-world"])
      assert.are.equal("", en_data["hello-world"])
    end)
  end)

  it("applies extraction only within the specified range", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <>",
        "    <p>First text</p>",
        "    <p>Second text</p>",
        "  </>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end
      local cfg = config_mod.setup({ primary_lang = "ja" })

      vim.ui.input = function(opts, on_confirm)
        on_confirm(opts.default)
      end

      extract.run(buf, cfg, {
        range = { start_line = 3, end_line = 3 },
      })

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[4]:find('{t("common:first-text")}', 1, true) ~= nil)
      assert.are.equal("    <p>Second text</p>", lines[5])
    end)
  end)
end)
