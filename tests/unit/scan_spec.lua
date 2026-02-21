local scan = require("i18n-status.scan")
local stub = require("luassert.stub")
local rpc = require("i18n-status.rpc")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

---@param bufnr integer
---@param opts? { fallback_namespace?: string, range?: { start_line: integer, end_line: integer } }
---@return table[]
local function extract_async(bufnr, opts)
  local done = false
  local result = nil
  scan.extract_async(bufnr, opts, function(items)
    result = items
    done = true
  end)
  local ok = vim.wait(5000, function()
    return done
  end)
  assert.is_true(ok, "scan.extract_async timed out")
  return result or {}
end

describe("scan", function()
  local stubs = {}

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    table.insert(stubs, s)
    return s
  end

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}
  end)

  it("detects t and namespace", function()
    local buf = make_buf({
      'const { t } = useTranslation("auth")',
      't("login.title")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("detects alias call from useTranslation", function()
    local buf = make_buf({
      'const { t: tr } = useTranslation("auth")',
      'tr("login.title")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("extracts asynchronously", function()
    local buf = make_buf({
      'const { t } = useTranslation("auth")',
      't("login.title")',
    }, "typescript")
    local items = extract_async(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("detects member call", function()
    local buf = make_buf({
      'i18next.t("home.title")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("common:home.title", items[1].key)
  end)

  it("detects useTranslations/getTranslations namespaces", function()
    local buf = make_buf({
      'const t = useTranslations("auth")',
      't("login.title")',
      "async function load() {",
      '  const t = await getTranslations("admin")',
      '  t("dashboard.title")',
      "}",
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    local by_raw = {}
    for _, item in ipairs(items) do
      by_raw[item.raw] = item
    end
    assert.are.equal("auth:login.title", by_raw["login.title"].key)
    assert.are.equal("admin:dashboard.title", by_raw["dashboard.title"].key)
  end)

  it("ignores non literal", function()
    local buf = make_buf({
      "const k = foo()",
      "t(k)",
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(0, #items)
  end)

  it("detects multiple keys in the same line", function()
    local buf = make_buf({
      't("login.title") + t("login.desc")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(2, #items)
    assert.are.equal("common:login.title", items[1].key)
    assert.are.equal("common:login.desc", items[2].key)
  end)

  it("detects keys in TSX", function()
    local buf = make_buf({
      'const { t } = useTranslation("auth")',
      'return <div>{t("login.title")}</div>',
    }, "typescriptreact")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("detects keys in JSX", function()
    local buf = make_buf({
      'const { t } = useTranslation("auth")',
      'return <div>{t("login.title")}</div>',
    }, "javascriptreact")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("ignores comments", function()
    local buf = make_buf({
      '// t("login.title")',
      '/* t("login.desc") */',
      't("login.cta")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("common:login.cta", items[1].key)
  end)

  it("limits extraction when range option is provided", function()
    local buf = make_buf({
      't("k1")',
      't("k2")',
      't("k3")',
    }, "typescript")
    local items = scan.extract(buf, {
      fallback_namespace = "common",
      range = { start_line = 1, end_line = 2 },
    })
    assert.are.equal(2, #items)
    assert.are.equal("common:k2", items[1].key)
    assert.are.equal("common:k3", items[2].key)
  end)

  it("extracts directly from text when parser exists", function()
    local text = table.concat({
      'const t = useTranslation("auth")',
      't("login.title")',
    }, "\n")
    local items = scan.extract_text(text, "typescript", { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("auth:login.title", items[1].key)
  end)

  it("falls back to regex extraction when language missing", function()
    local text = 't("login.title")'
    local items = scan.extract_text(text, nil, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("common:login.title", items[1].key)
  end)

  it("fallback regex handles t() at the start of a line", function()
    local text = 't("start.key")'
    local items = scan.extract_text(text, nil, { fallback_namespace = "common" })
    assert.are.equal(1, #items)
    assert.are.equal("common:start.key", items[1].key)
  end)

  it("extracts keys from namespace resource file", function()
    local buf = make_buf({
      "{",
      '  "login": {',
      '    "title": "ログイン",',
      '    "desc": "説明"',
      "  },",
      '  "plain": "OK"',
      "}",
    }, "json")
    local items = scan.extract_resource(buf, { namespace = "common", is_root = false })
    local keys = {}
    for _, item in ipairs(items) do
      keys[item.key] = true
    end
    assert.is_true(keys["common:login.title"])
    assert.is_true(keys["common:login.desc"])
    assert.is_true(keys["common:plain"])
  end)

  it("extracts keys from next-intl root file", function()
    local buf = make_buf({
      "{",
      '  "common": {',
      '    "title": "Login"',
      "  },",
      '  "auth": {',
      '    "welcome": "Hi"',
      "  }",
      "}",
    }, "json")
    local items = scan.extract_resource(buf, { namespace = nil, is_root = true })
    local keys = {}
    for _, item in ipairs(items) do
      keys[item.key] = true
    end
    assert.is_true(keys["common:title"])
    assert.is_true(keys["auth:welcome"])
  end)

  it("resolves translation function alias by row", function()
    local buf = make_buf({
      'const { t: tr } = useTranslation("auth")',
      "const label = <p>Hello</p>",
    }, "typescriptreact")
    local ctx = scan.translation_context_at(buf, 1, { fallback_namespace = "common" })
    assert.are.equal("tr", ctx.t_func)
    assert.are.equal("auth", ctx.namespace)
    assert.is_true(ctx.found_hook)
  end)

  it("returns has_any_hook=false when translation hook is missing", function()
    local buf = make_buf({
      "const label = <p>Hello</p>",
    }, "typescriptreact")
    local ctx = scan.translation_context_at(buf, 0, { fallback_namespace = "common" })
    assert.are.equal("t", ctx.t_func)
    assert.are.equal("common", ctx.namespace)
    assert.is_false(ctx.has_any_hook)
  end)

  it("reuses cached source while changedtick is unchanged", function()
    local buf = make_buf({
      't("k1")',
    }, "typescript")
    local get_lines_calls = 0
    local original = vim.api.nvim_buf_get_lines
    add_stub(vim.api, "nvim_buf_get_lines", function(...)
      get_lines_calls = get_lines_calls + 1
      return original(...)
    end)

    local first = scan.extract(buf, { fallback_namespace = "common" })
    local second = scan.extract(buf, { fallback_namespace = "common" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "const x = 1" })
    local third = scan.extract(buf, { fallback_namespace = "common" })

    assert.are.equal(1, #first)
    assert.are.equal(1, #second)
    assert.are.equal(1, #third)
    assert.are.equal(2, get_lines_calls)
  end)

  it("avoids expensive retries for non-react buffers", function()
    local buf = make_buf({
      "const x = 1",
      't("k1")',
    }, "typescript")
    local call_count = 0
    add_stub(rpc, "request_sync", function()
      call_count = call_count + 1
      return nil, "parse error"
    end)

    local ctx = scan.translation_context_at(buf, 1, { fallback_namespace = "common" })

    assert.are.equal(1, call_count)
    assert.are.equal("common", ctx.namespace)
    assert.is_false(ctx.found_hook)
  end)

  it("keeps retries for react buffers to recover parser errors", function()
    local buf = make_buf({
      'const { t } = useTranslation("common")',
      "return <div>",
    }, "typescriptreact")
    local call_count = 0
    add_stub(rpc, "request_sync", function()
      call_count = call_count + 1
      return nil, "parse error"
    end)

    local ctx = scan.translation_context_at(buf, 1, { fallback_namespace = "common" })

    assert.are.equal(3, call_count)
    assert.are.equal("common", ctx.namespace)
    assert.is_false(ctx.has_any_hook)
  end)
end)
