local hardcoded = require("i18n-status.hardcoded")

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

describe("hardcoded", function()
  it("detects jsx_text and jsx literal", function()
    local buf = make_buf({
      "export function Page() {",
      '  return <div>Hello {"World"}</div>',
      "}",
    }, "typescriptreact")
    if skip_if_no_parser(buf, "tsx", "typescript") then
      return
    end
    local items = hardcoded.extract(buf, { min_length = 2 })
    local found = {}
    for _, item in ipairs(items) do
      found[item.text] = true
    end
    assert.is_true(found["Hello"])
    assert.is_true(found["World"])
  end)

  it("excludes text inside Trans component", function()
    local buf = make_buf({
      'export function Page() { return <><Trans i18nKey="auth.title">Login</Trans><p>Signup</p></> }',
    }, "typescriptreact")
    if skip_if_no_parser(buf, "tsx", "typescript") then
      return
    end
    local items = hardcoded.extract(buf, {
      min_length = 2,
      exclude_components = { "Trans", "Translation" },
    })
    assert.are.equal(1, #items)
    assert.are.equal("Signup", items[1].text)
  end)

  it("handles multiline jsx_text ranges", function()
    local buf = make_buf({
      "export function Page() {",
      "  return (",
      "    <p>",
      "      This is a very long",
      "      multiline text",
      "    </p>",
      "  )",
      "}",
    }, "typescriptreact")
    if skip_if_no_parser(buf, "tsx", "typescript") then
      return
    end
    local items = hardcoded.extract(buf, { min_length = 2 })
    assert.are.equal(1, #items)
    assert.are.equal("This is a very long multiline text", items[1].text)
    assert.is_true(items[1].end_lnum >= items[1].lnum)
  end)

  it("skips template literal with substitutions", function()
    local buf = make_buf({
      "export function Page(name) {",
      "  return <p>{`Hello ${name}`}</p>",
      "}",
    }, "typescriptreact")
    if skip_if_no_parser(buf, "tsx", "typescript") then
      return
    end
    local items = hardcoded.extract(buf, { min_length = 2 })
    assert.are.equal(0, #items)
  end)

  it("respects range and min_length", function()
    local buf = make_buf({
      "export function Page() {",
      "  return (",
      "    <>",
      "      <p>Ok</p>",
      "      <p>Hi</p>",
      "    </>",
      "  )",
      "}",
    }, "typescriptreact")
    if skip_if_no_parser(buf, "tsx", "typescript") then
      return
    end
    local items = hardcoded.extract(buf, {
      min_length = 3,
      range = { start_line = 3, end_line = 3 },
    })
    assert.are.equal(0, #items)
  end)
end)
