local scan = require("i18n-status.scan")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
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
