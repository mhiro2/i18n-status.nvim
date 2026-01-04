local core = require("i18n-status.core")
local render = require("i18n-status.render")
local config_mod = require("i18n-status.config")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "typescript"
  return buf
end

local function inline_text(buf)
  local ns = render.namespace()
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

describe("failure scenarios", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("recovers when a language disappears", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    helpers.with_cwd(root, function()
      local buf = make_buf({ 't("login.title")' })
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      local project, project_key = state.project_for_buf(buf)
      assert.is_true(#project.languages >= 2)
      state.set_current(project_key, "en")

      vim.fn.delete(root .. "/locales/en", "rf")
      core.refresh_now(buf, config)

      project = state.project_for_key(project_key)
      assert.are.equal("ja", project.current_lang)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)
    end)
  end)

  it("handles large buffers without error", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local lines = {}
    for _ = 1, 400 do
      table.insert(lines, 't("login.title")')
    end
    helpers.with_cwd(root, function()
      local buf = make_buf(lines)
      local config = config_mod.setup({
        primary_lang = "ja",
        inline = { visible_only = false },
      })

      core.refresh_now(buf, config)
      assert.is_true(inline_text(buf):find("ログイン", 1, true) ~= nil)
    end)
  end)
end)
