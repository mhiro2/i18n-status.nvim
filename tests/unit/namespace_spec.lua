local scan = require("i18n-status.scan")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
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

describe("namespace resolver", function()
  it("uses nearest namespace scope", function()
    local buf = make_buf({
      'const { t } = useTranslation("outer")',
      "function View() {",
      '  const { t } = useTranslation("inner")',
      '  t("inside")',
      "}",
      't("outside")',
    }, "typescript")
    if skip_if_no_parser(buf, "typescript") then
      return
    end
    local items = scan.extract(buf, { fallback_namespace = "common" })
    local by_raw = {}
    for _, item in ipairs(items) do
      by_raw[item.raw] = item
    end
    assert.are.equal("inner:inside", by_raw.inside.key)
    assert.are.equal("outer:outside", by_raw.outside.key)
  end)

  it("does not override explicit namespace", function()
    local buf = make_buf({
      'const { t } = useTranslation("outer")',
      't("common:hello")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "fallback" })
    assert.are.equal(1, #items)
    assert.are.equal("common:hello", items[1].key)
    assert.are.equal("common", items[1].namespace)
  end)

  it("uses fallback namespace when none detected", function()
    local buf = make_buf({
      't("hello")',
    }, "typescript")
    local items = scan.extract(buf, { fallback_namespace = "fallback" })
    assert.are.equal(1, #items)
    assert.are.equal("fallback:hello", items[1].key)
  end)
end)
