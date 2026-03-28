local stub = require("luassert.stub")

local config_mod = require("i18n-status.config")
local extract = require("i18n-status.extract")
local key_write = require("i18n-status.key_write")
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

---@param ft string
---@return integer|nil
local function find_review_window(ft)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == ft then
      return win
    end
  end
  return nil
end

---@param buf integer
---@param needle string
---@return integer|nil
local function find_line(buf, needle)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

---@param ctx I18nStatusExtractReviewCtx
---@param text string
---@return integer|nil line number (1-based)
local function find_candidate_line(ctx, text)
  for _, candidate in ipairs(ctx.candidates) do
    if candidate.text == text then
      for line, id in pairs(ctx.line_to_candidate) do
        if id == candidate.id then
          return line
        end
      end
    end
  end
  return nil
end

---@param ctx I18nStatusExtractReviewCtx
---@param text string
---@return boolean
local function has_view_candidate(ctx, text)
  for _, c in ipairs(ctx.view_candidates or {}) do
    if c.text == text then
      return true
    end
  end
  return false
end

describe("extract review integration", function()
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
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype or ""
        if ft == "i18n-status-extract-review" or ft == "i18n-status-extract-review-help" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end)

  it("opens review UI when extraction starts", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local opened = vim.wait(500, function()
        return find_review_window("i18n-status-extract-review") ~= nil
      end, 10)

      assert.is_true(opened)
      assert.is_not_nil(find_review_window("i18n-status-extract-review"))
    end)
  end)

  it("focuses the first candidate when review opens", function()
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
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local focused = vim.wait(500, function()
        if not vim.api.nvim_win_is_valid(ctx.list_win) then
          return false
        end
        local first_line = find_candidate_line(ctx, "First text")
        if not first_line then
          return false
        end
        return vim.api.nvim_win_get_cursor(ctx.list_win)[1] == first_line
      end, 10)

      assert.is_true(focused)
    end)
  end)

  it("does not duplicate help hint in list body on open", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local duplicated = find_line(ctx.list_buf, "?:help q:quit")
      assert.is_nil(duplicated)
    end)
  end)

  it("toggles keymap help with ?", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("?", "x", false)

      local opened = vim.wait(500, function()
        return find_review_window("i18n-status-extract-review-help") ~= nil
      end, 10)
      assert.is_true(opened)

      vim.api.nvim_feedkeys("?", "x", false)
      local closed = vim.wait(500, function()
        return find_review_window("i18n-status-extract-review-help") == nil
      end, 10)
      assert.is_true(closed)
    end)
  end)

  it("filters candidates with slash key", function()
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
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local original_input = vim.ui.input
      vim.ui.input = function(_opts, on_confirm)
        on_confirm("second")
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("/", "x", false)

      local filtered = vim.wait(500, function()
        return has_view_candidate(ctx, "Second text") and not has_view_candidate(ctx, "First text")
      end, 10)

      vim.ui.input = original_input
      assert.is_true(filtered)
    end)
  end)

  it("does not apply current candidate with <CR> when unselected", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("\r", "x", false)
      local unchanged = vim.wait(500, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[3] == "  return <p>Hello world</p>"
      end, 10)
      assert.is_true(unchanged)

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en_data = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_nil(ja_data["hello-world"])
      assert.is_nil(en_data["hello-world"])
    end)
  end)

  it("applies only selected candidates with <CR>", function()
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
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local first_line = find_candidate_line(ctx, "First text")
      assert.is_not_nil(first_line)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_win_set_cursor(ctx.list_win, { first_line, 0 })
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[4]:find('{t("common:first-text")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[4]:find('{t("common:first-text")}', 1, true) ~= nil)
      assert.are.equal("    <p>Second text</p>", lines[5])

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en_data = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("First text", ja_data["first-text"])
      assert.are.equal("", en_data["first-text"])
      assert.is_nil(ja_data["second-text"])
    end)
  end)

  it("rolls back source replacement when resource writes fail", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local before_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local before_en = helpers.read_file(root .. "/locales/en/common.json")

      add_stub(key_write, "write_translations", function()
        return 0, { "ja", "en" }
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal("  return <p>Hello world</p>", lines[3])

      local after_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local after_en = helpers.read_file(root .. "/locales/en/common.json")
      assert.are.equal(before_ja, after_ja)
      assert.are.equal(before_en, after_en)
    end)
  end)

  it("applies extraction only within specified range", function()
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
      local ctx = extract.run(buf, cfg, {
        range = {
          start_line = 3,
          end_line = 3,
        },
      })
      assert.is_not_nil(ctx)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[4]:find('{t("common:first-text")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[4]:find('{t("common:first-text")}', 1, true) ~= nil)
      assert.are.equal("    <p>Second text</p>", lines[5])
    end)
  end)

  it("reuses existing key without writing resource files", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"hello-world":"登録済み"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"hello-world":"Registered"}')

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local before_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local before_en = helpers.read_file(root .. "/locales/en/common.json")

      local original_select = vim.ui.select
      vim.ui.select = function(items, _opts, on_choice)
        on_choice(items[1])
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("u", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[3]:find('{t("common:hello-world")}', 1, true) ~= nil
      end, 10)

      vim.ui.select = original_select
      assert.is_true(applied)

      local after_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local after_en = helpers.read_file(root .. "/locales/en/common.json")
      assert.are.equal(before_ja, after_ja)
      assert.are.equal(before_en, after_en)
    end)
  end)

  it("cleans up review state when closed with :q", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      if skip_if_no_parser(buf, "tsx", "typescript") then
        return
      end

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local ns = vim.api.nvim_get_namespaces()["i18n-status-extract-review-track"]
      assert.is_not_nil(ns)

      local marks_before = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      assert.is_true(#marks_before > 0)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.cmd("q")

      local closed = vim.wait(500, function()
        return find_review_window("i18n-status-extract-review") == nil
      end, 10)
      assert.is_true(closed)

      local marks_after = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      assert.are.equal(0, #marks_after)
    end)
  end)
end)
