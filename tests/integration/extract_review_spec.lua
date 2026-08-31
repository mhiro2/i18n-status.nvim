local stub = require("luassert.stub")

local config_mod = require("i18n-status.config")
local extract = require("i18n-status.extract")
local key_write = require("i18n-status.key_write")
local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")
local watcher = require("i18n-status.watcher")
local helpers = require("tests.helpers")

local function make_buf(lines, ft, name)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].modified = false
  return buf
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

  it("aborts when opening review windows changes the source", function()
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
      local group = vim.api.nvim_create_augroup("i18n-status-extract-layout-race", { clear = true })
      vim.api.nvim_create_autocmd("WinNew", {
        group = group,
        once = true,
        callback = function()
          vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  return <p>Changed during layout</p>" })
        end,
      })

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      pcall(vim.api.nvim_del_augroup_by_id, group)

      assert.is_nil(ctx)
      assert.are.equal("  return <p>Changed during layout</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("{}", helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_nil(find_review_window("i18n-status-extract-review"))
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

  it("applies candidates back to front across distinct translator declarations", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/first.json", "{}")
    helpers.write_file(root .. "/locales/en/first.json", "{}")
    helpers.write_file(root .. "/locales/ja/second.json", "{}")
    helpers.write_file(root .. "/locales/en/second.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        "export function First() {",
        '  const { t } = useTranslation("first")',
        "  return <p>First text</p>",
        "}",
        "export function Second() {",
        '  const { t } = useTranslation("second")',
        "  return <p>Second text</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal(2, #ctx.candidates)
      assert.are_not.equal(ctx.candidates[1].binding_id, ctx.candidates[2].binding_id)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[3] == '  return <p>{t("first:first-text")}</p>'
          and lines[7] == '  return <p>{t("second:second-text")}</p>'
      end, 10)
      assert.is_true(applied)
      assert.is_truthy(ctx.status_message:find("applied=2", 1, true))
      assert.is_truthy(ctx.status_message:find("failed=0", 1, true))

      local ja_first = vim.json.decode(helpers.read_file(root .. "/locales/ja/first.json"))
      local en_first = vim.json.decode(helpers.read_file(root .. "/locales/en/first.json"))
      local ja_second = vim.json.decode(helpers.read_file(root .. "/locales/ja/second.json"))
      local en_second = vim.json.decode(helpers.read_file(root .. "/locales/en/second.json"))
      assert.are.equal("First text", ja_first["first-text"])
      assert.are.equal("", en_first["first-text"])
      assert.are.equal("Second text", ja_second["second-text"])
      assert.are.equal("", en_second["second-text"])
    end)
  end)

  it("applies JSX literals with expression replacements and semantic resource values", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <>",
        '    <p>{"Hello\\nworld"}</p>',
        "    <p>{`Hello\\u0020template`}</p>",
        "  </>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return lines[4]:find('{t("common:hello-world")}', 1, true) ~= nil
          and lines[5]:find('{t("common:hello-template")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal('    <p>{t("common:hello-world")}</p>', lines[4])
      assert.are.equal('    <p>{t("common:hello-template")}</p>', lines[5])
      assert.is_nil(lines[4]:find("{{", 1, true))

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local en_data = vim.json.decode(helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("Hello\nworld", ja_data["hello-world"])
      assert.are.equal("Hello template", ja_data["hello-template"])
      assert.are.equal("", en_data["hello-world"])
      assert.are.equal("", en_data["hello-template"])
    end)
  end)

  it("stores normalized multiline JSX text instead of indentation", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>",
        "    This is multiline",
        "    JSX text",
        "  </p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
        return data["this-is-multiline-jsx-text"] ~= nil
      end, 10)
      assert.is_true(applied)

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("This is multiline JSX text", ja_data["this-is-multiline-jsx-text"])
    end)
  end)

  it("preserves meaningful JSX boundary spaces in source and resources", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello <strong>dear friend</strong> again friend</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      assert.are.same({ "Hello ", "dear friend", " again friend" }, {
        ctx.candidates[1].text,
        ctx.candidates[2].text,
        ctx.candidates[3].text,
      })

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local line = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
        return line:find('{t("common:again-friend")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal(
        '  return <p>{t("common:hello")}<strong>{t("common:dear-friend")}</strong>{t("common:again-friend")}</p>',
        vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
      )

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("Hello ", ja_data.hello)
      assert.are.equal("dear friend", ja_data["dear-friend"])
      assert.are.equal(" again friend", ja_data["again-friend"])
    end)
  end)

  it("applies byte-column ranges after multibyte JSX siblings", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>日本語<span>Hello world</span></p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      local hello_line = find_candidate_line(ctx, "Hello world")
      assert.is_not_nil(hello_line)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_win_set_cursor(ctx.list_win, { hello_line, 0 })
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('{t("common:hello-world")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal(
        '  return <p>日本語<span>{t("common:hello-world")}</span></p>',
        vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
      )
    end)
  end)

  it("uses relative source keys with scoped next-intl root resources", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/messages/ja.json", "{}")
    helpers.write_file(root .. "/messages/en.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const t = useTranslations("Home")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal("Home:hello-world", ctx.candidates[1].proposed_key)
      assert.are.equal("namespace_relative", ctx.candidates[1].source_key_policy)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('{t("hello-world")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal('  return <p>{t("hello-world")}</p>', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])

      local ja_data = vim.json.decode(helpers.read_file(root .. "/messages/ja.json"))
      local en_data = vim.json.decode(helpers.read_file(root .. "/messages/en.json"))
      assert.are.equal("Hello world", ja_data.Home["hello-world"])
      assert.are.equal("", en_data.Home["hello-world"])
    end)
  end)

  it("uses relative source keys with awaited next-intl namespace resources", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/messages/ja/Home.json", "{}")
    helpers.write_file(root .. "/messages/en/Home.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        "export async function Page() {",
        '  const t = (await (getTranslations("Home"))) as Translator',
        "  return <p>Hello server</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal("getTranslations", ctx.candidates[1].hook)
      assert.are.equal("namespace_relative", ctx.candidates[1].source_key_policy)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('{t("hello-server")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal('  return <p>{t("hello-server")}</p>', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])

      local ja_data = vim.json.decode(helpers.read_file(root .. "/messages/ja/Home.json"))
      assert.are.equal("Hello server", ja_data["hello-server"])
    end)
  end)

  it("keeps mixed framework catalogs, previews, and writes isolated", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/fr/common.json", "{}")
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/fr/Home.json", '{"modern-text":"i18next existing"}')
    helpers.write_file(root .. "/locales/ja/Home.json", '{"modern-text":"i18next existing"}')
    helpers.write_file(root .. "/messages/de.json", '{"common":{"legacy-text":"next-intl existing"}}')
    helpers.write_file(root .. "/messages/en.json", '{"common":{"legacy-text":"next-intl existing"}}')

    helpers.with_cwd(root, function()
      local buf = make_buf({
        "export function Legacy() {",
        '  const { t: legacyT } = useTranslation("common")',
        "  return <p>Legacy text</p>",
        "}",
        "export function Modern() {",
        '  const modernT = useTranslations("Home")',
        "  return <p>Modern text</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "en" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal(2, #ctx.candidates)
      local legacy = ctx.candidates[1]
      local modern = ctx.candidates[2]
      assert.are.equal("i18next", legacy.framework)
      assert.are.same({ "fr", "ja" }, legacy.languages)
      assert.are.equal("fr", legacy.primary_lang)
      assert.are.equal("ready", legacy.status)
      assert.are.equal("next_intl", modern.framework)
      assert.are.same({ "de", "en" }, modern.languages)
      assert.are.equal("en", modern.primary_lang)
      assert.are.equal("ready", modern.status)

      local legacy_preview = table.concat(vim.api.nvim_buf_get_lines(ctx.resource_buf, 0, -1, false), "\n")
      assert.is_truthy(legacy_preview:find("locales/fr/common.json", 1, true))
      assert.is_nil(legacy_preview:find("messages/", 1, true))

      local modern_line = find_candidate_line(ctx, "Modern text")
      vim.api.nvim_win_set_cursor(ctx.list_win, { modern_line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ctx.list_buf })
      local modern_preview = table.concat(vim.api.nvim_buf_get_lines(ctx.resource_buf, 0, -1, false), "\n")
      assert.is_truthy(modern_preview:find("messages/en.json", 1, true))
      assert.is_nil(modern_preview:find("locales/", 1, true))

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("applied=2", 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal('  return <p>{legacyT("common:legacy-text")}</p>', lines[3])
      assert.are.equal('  return <p>{modernT("modern-text")}</p>', lines[7])

      local fr_common = vim.json.decode(helpers.read_file(root .. "/locales/fr/common.json"))
      local ja_common = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      local fr_home = vim.json.decode(helpers.read_file(root .. "/locales/fr/Home.json"))
      local en_messages = vim.json.decode(helpers.read_file(root .. "/messages/en.json"))
      local de_messages = vim.json.decode(helpers.read_file(root .. "/messages/de.json"))
      assert.are.equal("Legacy text", fr_common["legacy-text"])
      assert.are.equal("", ja_common["legacy-text"])
      assert.are.equal("i18next existing", fr_home["modern-text"])
      assert.are.equal("Modern text", en_messages.Home["modern-text"])
      assert.are.equal("", de_messages.Home["modern-text"])
      assert.are.equal("next-intl existing", en_messages.common["legacy-text"])
    end)
  end)

  it("refuses ambiguous same-framework resource roots", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(root .. "/public/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/public/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})

      assert.is_nil(ctx)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("{}", helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/public/locales/ja/common.json"))
    end)
  end)

  it("writes through the exact project identity instead of a watched child cache", function()
    local root = helpers.tmpdir()
    local child_root = root .. "/packages/child"
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(child_root .. "/locales/ja/common.json", "{}")
    helpers.write_file(child_root .. "/locales/en/common.json", "{}")
    vim.fn.mkdir(child_root .. "/src", "p")

    helpers.with_cwd(root, function()
      local child_cache = resources.ensure_index(child_root .. "/src", { exact = true })
      add_stub(watcher, "is_watching", function(key)
        return key == child_cache.key
      end)
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/page.tsx")

      local cfg = config_mod.setup({ primary_lang = "ja", resource_watch = { enabled = false } })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))["hello-world"] ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal(
        "Hello world",
        vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))["hello-world"]
      )
      assert.are.same({}, vim.json.decode(helpers.read_file(child_root .. "/locales/ja/common.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(child_root .. "/locales/en/common.json")))
    end)
  end)

  it("refuses unawaited getTranslations through TypeScript wrappers", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/messages/ja/Home.json", "{}")
    helpers.write_file(root .. "/messages/en/Home.json", "{}")

    helpers.with_cwd(root, function()
      local source_line = '  const t = (getTranslations("Home") as unknown) satisfies Translator'
      local buf = make_buf({
        "export async function Page() {",
        source_line,
        "  return <p>Hello server</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})

      assert.is_nil(ctx)
      assert.are.equal(source_line, vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
      assert.are.equal("  return <p>Hello server</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/messages/ja/Home.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/messages/en/Home.json")))
    end)
  end)

  it("refuses extraction when no translation function is in scope", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})

      assert.is_nil(ctx)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/en/common.json")))
    end)
  end)

  for _, translator_line in ipairs({
    'const { t } = useTranslation("common", { keyPrefix: "page" })',
    'const { t } = useTranslation("common", translationOptions)',
  }) do
    it("refuses extraction when useTranslation options can change key semantics", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/locales/ja/common.json", "{}")
      helpers.write_file(root .. "/locales/en/common.json", "{}")

      helpers.with_cwd(root, function()
        local buf = make_buf({
          translator_line,
          "export function Page() {",
          "  return <p>Hello world</p>",
          "}",
        }, "typescriptreact", root .. "/src/page.tsx")

        local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})

        assert.is_nil(ctx)
        assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
        assert.are.equal("{}", helpers.read_file(root .. "/locales/ja/common.json"))
        assert.are.equal("{}", helpers.read_file(root .. "/locales/en/common.json"))
      end)
    end)
  end

  it("does not use a translation function from a sibling lexical scope", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        "export function Page(condition) {",
        "  if (condition) {",
        '    const { t } = useTranslation("common")',
        "    return <p>Inside text</p>",
        "  }",
        "  return <p>Outside text</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal(1, #ctx.candidates)
      assert.are.equal("Inside text", ctx.candidates[1].text)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find('{t("common:inside-text")}', 1, true) ~= nil
      end, 10)
      assert.is_true(applied)
      assert.are.equal("  return <p>Outside text</p>", vim.api.nvim_buf_get_lines(buf, 5, 6, false)[1])

      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("Inside text", ja_data["inside-text"])
      assert.is_nil(ja_data["outside-text"])
    end)
  end)

  it("uses a detected locale when configured primary is absent", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/fr/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "en" }), {})
      assert.is_not_nil(ctx)
      assert.are.equal(ctx.languages[1], ctx.primary_lang)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        local ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
        local fr = vim.json.decode(helpers.read_file(root .. "/locales/fr/common.json"))
        return ja["hello-world"] ~= nil and fr["hello-world"] ~= nil
      end, 10)
      assert.is_true(applied)

      local values = {
        ja = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))["hello-world"],
        fr = vim.json.decode(helpers.read_file(root .. "/locales/fr/common.json"))["hello-world"],
      }
      assert.are.equal("Hello world", values[ctx.primary_lang])
      local other_lang = ctx.primary_lang == "ja" and "fr" or "ja"
      assert.are.equal("", values[other_lang])
    end)
  end)

  it("rejects a candidate whose tracked source changed after review opened", function()
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

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      vim.api.nvim_buf_set_text(buf, 2, 12, 2, 23, { "Changed text" })

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local rejected = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(rejected)
      assert.are.equal("  return <p>Changed text</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/en/common.json")))
    end)
  end)

  for _, case in ipairs({
    {
      name = "exact",
      key = "common:account",
      json = '{"account":"external"}',
    },
    {
      name = "ancestor",
      key = "common:account.title",
      json = '{"account":"external"}',
    },
    {
      name = "descendant",
      key = "common:account",
      json = '{"account":{"title":"external"}}',
    },
  }) do
    it("rejects an externally created " .. case.name .. " target after review opens", function()
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
        local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
        assert.is_not_nil(ctx)
        ctx.candidates[1].proposed_key = case.key
        ctx.candidates[1].new_key = case.key
        ctx.candidates[1].selected = true

        helpers.write_file(root .. "/locales/ja/common.json", case.json)
        helpers.write_file(root .. "/locales/en/common.json", case.json)

        vim.api.nvim_set_current_win(ctx.list_win)
        vim.api.nvim_feedkeys("\r", "x", false)

        local rejected = vim.wait(1000, function()
          return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
        end, 10)
        assert.is_true(rejected)
        assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
        assert.is_false(vim.bo[buf].modified)
        assert.are.equal(case.json, helpers.read_file(root .. "/locales/ja/common.json"))
        assert.are.equal(case.json, helpers.read_file(root .. "/locales/en/common.json"))
        assert.is_truthy(ctx.candidates[1].apply_error:find("target key already exists", 1, true))
        assert.are.equal(ctx.candidates[1].apply_error, ctx.candidates[1].error)
      end)
    end)
  end

  it("rejects a source buffer moved to another project after review opens", function()
    local root = helpers.tmpdir()
    local other_root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")
    helpers.write_file(other_root .. "/locales/ja/common.json", "{}")
    helpers.write_file(other_root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      vim.api.nvim_buf_set_name(buf, other_root .. "/src/page.tsx")

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local rejected = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(rejected)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("{}", helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("{}", helpers.read_file(other_root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(other_root .. "/locales/en/common.json"))
      assert.is_truthy(ctx.candidates[1].error:find("source buffer name changed", 1, true))
    end)
  end)

  it("rejects changed JSX syntax even when the candidate text is unchanged", function()
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
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  return <span>Hello world</span>" })

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local rejected = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(rejected)
      assert.are.equal("  return <span>Hello world</span>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("{}", helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/locales/en/common.json"))
    end)
  end)

  it("rejects a candidate shadowed after review opened at its moved extmark", function()
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

      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)
      local planned_binding_id = ctx.candidates[1].binding_id
      assert.are.equal("string", type(planned_binding_id))
      vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "  const t = format" })

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local rejected = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(rejected)
      assert.are.equal("  const t = format", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1])
      assert.is_true(ctx.candidates[1].stale)
      assert.are.equal("error", ctx.candidates[1].status)
      assert.is_truthy(ctx.candidates[1].error:find("translation context changed", 1, true))
      assert.are.equal(planned_binding_id, ctx.candidates[1].binding_id)
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/en/common.json")))
    end)
  end)

  it("applies byte ranges after multibyte source without shifting JSX text", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        '  const 前置き = "😀"; return <p>Hello world</p>',
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local candidate_line = find_candidate_line(ctx, "Hello world")
      assert.is_not_nil(candidate_line)
      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_win_set_cursor(ctx.list_win, { candidate_line, 0 })
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local applied = vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
          == '  const 前置き = "😀"; return <p>{t("common:hello-world")}</p>'
      end, 10)
      assert.is_true(applied)
      local ja_data = vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("Hello world", ja_data["hello-world"])
    end)
  end)

  it("leaves a clean source untouched when a resource commit fails", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", "{}")
    helpers.write_file(root .. "/locales/en/common.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const { t } = useTranslation("common")',
        "export function Page() {",
        '  return <p>{"Hello\\nworld"}</p>',
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local before_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local before_en = helpers.read_file(root .. "/locales/en/common.json")

      add_stub(key_write, "prepare_translations", function()
        return {
          label = "resources common:hello-world",
          validate = function()
            return true, nil
          end,
          validate_committed = function()
            return false, "resource commit is unavailable"
          end,
          commit = function()
            return false, "simulated resource failure", false
          end,
          rollback = function()
            return true, nil
          end,
          cleanup = function()
            return true, nil
          end,
        },
          2,
          {},
          nil
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal('  return <p>{"Hello\\nworld"}</p>', lines[3])
      assert.is_false(vim.bo[buf].modified)
      assert.is_truthy(ctx.candidates[1].apply_error:find("simulated resource failure", 1, true))

      local after_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local after_en = helpers.read_file(root .. "/locales/en/common.json")
      assert.are.equal(before_ja, after_ja)
      assert.are.equal(before_en, after_en)
    end)
  end)

  it("rolls resources back while preserving a concurrent source edit", function()
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
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)

      local before_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local before_en = helpers.read_file(root .. "/locales/en/common.json")
      local original_commit = resources.commit_json_write
      local commits = 0
      add_stub(resources, "commit_json_write", function(plan)
        local committed, commit_err = original_commit(plan)
        if committed then
          commits = commits + 1
          if commits == 2 then
            vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  return <p>Concurrent edit</p>" })
          end
        end
        return committed, commit_err
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)
      assert.are.equal("  return <p>Concurrent edit</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_true(vim.bo[buf].modified)
      assert.are.equal(before_ja, helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal(before_en, helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_truthy(ctx.candidates[1].apply_error:find("source buffer changed", 1, true))
    end)
  end)

  it("rechecks committed resources immediately before updating source", function()
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
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)

      local rolled_back = false
      add_stub(key_write, "prepare_translations", function()
        return {
          label = "resources common:hello-world",
          validate = function()
            return true, nil
          end,
          validate_committed = function()
            return false, "external resource revision"
          end,
          commit = function()
            return true, nil, true
          end,
          rollback = function()
            rolled_back = true
            return false, "recovery artifact preserved at /tmp/i18n-status-recovery"
          end,
          cleanup = function()
            return true, nil
          end,
        },
          2,
          {},
          nil
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)
      assert.is_true(rolled_back)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_false(vim.bo[buf].modified)
      assert.is_truthy(ctx.candidates[1].apply_error:find("external resource revision", 1, true))
      assert.is_truthy(ctx.candidates[1].apply_error:find("recovery artifact preserved", 1, true))
      assert.are.equal(ctx.candidates[1].apply_error, ctx.candidates[1].error)
    end)
  end)

  it("rolls resource writes back when a locale appears before the source update", function()
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
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)

      local before_ja = helpers.read_file(root .. "/locales/ja/common.json")
      local before_en = helpers.read_file(root .. "/locales/en/common.json")
      local original_commit = resources.commit_json_write
      local commits = 0
      add_stub(resources, "commit_json_write", function(plan)
        local committed, commit_err = original_commit(plan)
        if committed then
          commits = commits + 1
          if commits == 2 then
            helpers.write_file(root .. "/locales/fr/common.json", "{}")
          end
        end
        return committed, commit_err
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_false(vim.bo[buf].modified)
      assert.are.equal(before_ja, helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal(before_en, helpers.read_file(root .. "/locales/en/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/locales/fr/common.json"))
      assert.is_truthy(ctx.candidates[1].apply_error:find("resource languages changed", 1, true))
    end)
  end)

  it("preserves a locale edited during final catalog validation", function()
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
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)

      local concurrent_ja = '{"external":"edit"}'
      local original_build = resource_catalog.build
      local raced = false
      add_stub(resource_catalog, "build", function(...)
        local catalog, catalog_err = original_build(...)
        if catalog and catalog.existing_keys["common:hello-world"] and not raced then
          raced = true
          helpers.write_file(root .. "/locales/ja/common.json", concurrent_ja)
        end
        return catalog, catalog_err
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)
      assert.is_true(raced)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_false(vim.bo[buf].modified)
      assert.are.equal(concurrent_ja, helpers.read_file(root .. "/locales/ja/common.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/locales/en/common.json"))
      assert.is_truthy(ctx.candidates[1].apply_error:find("resource changed on disk", 1, true))
    end)
  end)

  it("rejects a next-intl root file introduced during final catalog validation", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/messages/ja/Home.json", "{}")
    helpers.write_file(root .. "/messages/en/Home.json", "{}")

    helpers.with_cwd(root, function()
      local buf = make_buf({
        'const t = useTranslations("Home")',
        "export function Page() {",
        "  return <p>Hello world</p>",
        "}",
      }, "typescriptreact", root .. "/src/page.tsx")
      local ctx = extract.run(buf, config_mod.setup({ primary_lang = "ja" }), {})
      assert.is_not_nil(ctx)

      local concurrent_root = '{"external":"edit"}'
      local original_build = resource_catalog.build
      local raced = false
      add_stub(resource_catalog, "build", function(...)
        local catalog, catalog_err = original_build(...)
        if catalog and catalog.existing_keys["Home:hello-world"] and not raced then
          raced = true
          helpers.write_file(root .. "/messages/ja.json", concurrent_root)
        end
        return catalog, catalog_err
      end)

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("a", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      assert.is_true(finished)
      assert.is_true(raced)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
      assert.is_false(vim.bo[buf].modified)
      assert.are.equal("{}", helpers.read_file(root .. "/messages/ja/Home.json"))
      assert.are.equal("{}", helpers.read_file(root .. "/messages/en/Home.json"))
      assert.are.equal(concurrent_root, helpers.read_file(root .. "/messages/ja.json"))
      assert.is_truthy(ctx.candidates[1].apply_error:find("effective resource path changed", 1, true))
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

  it("rejects a reuse target removed during final source validation", function()
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

      local cfg = config_mod.setup({ primary_lang = "ja" })
      local ctx = extract.run(buf, cfg, {})
      assert.is_not_nil(ctx)

      local context_calls = 0
      local original_translation_context_at = scan.translation_context_at
      add_stub(scan, "translation_context_at", function(...)
        context_calls = context_calls + 1
        if context_calls == 2 then
          helpers.write_file(root .. "/locales/ja/common.json", "{}")
          helpers.write_file(root .. "/locales/en/common.json", "{}")
        end
        return original_translation_context_at(...)
      end)

      local original_select = vim.ui.select
      vim.ui.select = function(items, _opts, on_choice)
        on_choice(items[1])
      end

      vim.api.nvim_set_current_win(ctx.list_win)
      vim.api.nvim_feedkeys("u", "x", false)
      vim.api.nvim_feedkeys("\r", "x", false)

      local finished = vim.wait(1000, function()
        return type(ctx.status_message) == "string" and ctx.status_message:find("failed=1", 1, true) ~= nil
      end, 10)
      vim.ui.select = original_select

      assert.is_true(finished)
      assert.are.equal("  return <p>Hello world</p>", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[3])
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/ja/common.json")))
      assert.are.same({}, vim.json.decode(helpers.read_file(root .. "/locales/en/common.json")))
      assert.is_truthy(ctx.candidates[1].apply_error:find("reuse target changed", 1, true))
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
