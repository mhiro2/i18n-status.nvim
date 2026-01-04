local core = require("i18n-status.core")
local render = require("i18n-status.render")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

local function skip_if_no_parser(buf, lang)
  local ok = pcall(vim.treesitter.get_parser, buf, lang)
  if ok then
    return false
  end
  pending("treesitter parser not available: " .. lang)
  return true
end

local function inline_text(buf, ns)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  if #marks == 0 then
    return ""
  end
  local text = {}
  for _, chunk in ipairs(marks[1][4].virt_text or {}) do
    table.insert(text, chunk[1])
  end
  return table.concat(text, "")
end

local function inline_texts(buf, ns)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local chunks = {}
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      table.insert(chunks, chunk[1])
    end
    table.insert(out, table.concat(chunks, ""))
  end
  return out
end

describe("render", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("renders extmarks at eol", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal(1, #marks)
      assert.is_not_nil(marks[1][4].virt_text)
    end)
  end)

  it("renders inline after key", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "after_key",
          max_len = 40,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal(1, #marks)
      assert.are.equal("inline", marks[1][4].virt_text_pos)
      local text = inline_text(buf, ns)
      assert.is_true(#text > 0)
      assert.are.equal(" : ", text:sub(1, 3))
    end)
  end)

  it("updates position after config change", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal("eol", marks[1][4].virt_text_pos)

      config.inline.position = "after_key"
      core.refresh_now(buf, config)
      marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal("inline", marks[1][4].virt_text_pos)
    end)
  end)

  it("updates inline after edit", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン","desc":"説明"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login","desc":"Description"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      assert.is_true(inline_text(buf, ns):find("ログイン", 1, true) ~= nil)

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 't("login.desc")' })
      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf, ns):find("説明", 1, true) ~= nil)
    end)
  end)

  it("updates inline on language change", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      assert.is_true(inline_text(buf, ns):find("ログイン", 1, true) ~= nil)

      local _, project_key = state.project_for_buf(buf)
      state.set_current(project_key, "en")
      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf, ns):find("Login", 1, true) ~= nil)
    end)
  end)

  it("renders only visible range when visible_only is true", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"k1":"a","k2":"b","k3":"c","k4":"d"}')
    helpers.write_file(root .. "/locales/en/common.json", '{"k1":"a","k2":"b","k3":"c","k4":"d"}')
    helpers.with_cwd(root, function()
      local buf = make_buf({
        't("k1")',
        't("k2")',
        't("k3")',
        't("k4")',
      }, "typescript")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(vim.api.nvim_win_set_height, 0, 2)
      if not ok then
        pending("window height change not supported in this environment")
        return
      end

      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = true,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.are.equal(2, #marks)
    end)
  end)

  it("truncates long text", function()
    local root = helpers.tmpdir()
    helpers.write_file(
      root .. "/locales/ja/common.json",
      '{"login":{"title":"これはとても長いテキストです"}}'
    )
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"This is a very long text"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 8,
          visible_only = false,
        },
      })
      core.refresh_now(buf, config)
      local ns = render.namespace()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      local text = marks[1][4].virt_text[1][1]
      assert.is_true(text:sub(-3) == "...")
    end)
  end)

  it("forces refresh on language change even when buffer unchanged", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' }, "typescript")
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })
      -- Initial refresh
      core.refresh_now(buf, config)
      local _, project_key = state.project_for_buf(buf)
      local ns = render.namespace()
      assert.is_true(inline_text(buf, ns):find("ログイン", 1, true) ~= nil)

      -- Change language without editing buffer
      state.set_current(project_key, "en")
      -- Without force, refresh should be skipped (changedtick unchanged)
      core.refresh(buf, config, 0)
      -- Should still show Japanese (no refresh happened)
      assert.is_true(inline_text(buf, ns):find("ログイン", 1, true) ~= nil)

      -- With force, refresh should happen
      core.refresh(buf, config, 0, { force = true })
      -- Should now show English
      assert.is_true(inline_text(buf, ns):find("Login", 1, true) ~= nil)
    end)
  end)

  it("renders inline in translation files", function()
    local root = helpers.tmpdir()
    local ja = '{\n  "login": { "title": "ログイン" }\n}'
    local en = '{\n  "login": { "title": "Login" }\n}'
    helpers.write_file(root .. "/locales/ja/common.json", ja)
    helpers.write_file(root .. "/locales/en/common.json", en)
    helpers.with_cwd(root, function()
      local buf = make_buf(vim.split(ja, "\n", { plain = true }), "json")
      vim.api.nvim_buf_set_name(buf, root .. "/locales/ja/common.json")
      if skip_if_no_parser(buf, "json") then
        return
      end
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = {
          position = "eol",
          max_len = 40,
          visible_only = false,
        },
      })

      core.refresh_now(buf, config)
      local ns = render.namespace()
      local texts = inline_texts(buf, ns)
      local has_ja = false
      for _, text in ipairs(texts) do
        if text:find("ログイン", 1, true) then
          has_ja = true
        end
      end
      assert.is_true(has_ja)

      local _, project_key = state.project_for_buf(buf)
      state.set_current(project_key, "en")
      core.refresh_now(buf, config)
      texts = inline_texts(buf, ns)
      local has_en = false
      for _, text in ipairs(texts) do
        if text:find("Login", 1, true) then
          has_en = true
        end
      end
      assert.is_true(has_en)
    end)
  end)
end)
