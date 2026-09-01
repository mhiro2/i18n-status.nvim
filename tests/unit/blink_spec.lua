local blink = require("i18n-status.blink")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")

local function with_cwd(dir, fn)
  local current = vim.fn.getcwd()
  vim.fn.chdir(dir)
  local ok, err = pcall(fn)
  vim.fn.chdir(current)
  if not ok then
    error(err)
  end
end

describe("blink", function()
  before_each(function()
    state.init("ja", {})
  end)

  it("returns completion items", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    with_cwd(root, function()
      local result = nil
      blink.complete({}, function(items)
        result = items
      end)
      assert.is_true(#result > 0)
      local found = false
      for _, item in ipairs(result) do
        if item.label == "common:login.title" then
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)

  it("returns no items outside first argument", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    with_cwd(root, function()
      local result = nil
      local line = 't("login.title", { count = 1 })'
      blink.complete({ line = line, cursor = #line }, function(items)
        result = items
      end)
      assert.are.equal(0, #result)
    end)
  end)

  it("filters by namespace scope and strips namespace", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/auth.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"home":{"title":"ホーム"}}')
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'const { t } = useTranslation("auth")',
        't("',
      })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 3 })

      local result = nil
      blink.complete({ bufnr = buf, line = 't("', cursor = { 2, 3 } }, function(items)
        result = items
      end)

      assert.are.equal(1, #result)
      assert.are.equal("login.title", result[1].label)
      assert.is_nil(result[1].label:match(":"))
    end)
  end)

  it("does not complete through a shadowed translation symbol", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'const { t } = useTranslation("common")',
        "function render(t) {",
        '  t("',
        "}",
      })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 5 })

      local result = nil
      blink.complete({ bufnr = buf, line = '  t("', cursor = { 3, 5 } }, function(items)
        result = items
      end)

      assert.are.same({}, result)
    end)
  end)

  it("does not borrow a hook namespace for member calls", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/auth.json", '{"login":{"title":"ログイン"}}')
    helpers.write_file(root .. "/locales/ja/common.json", '{"home":{"title":"ホーム"}}')
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'const { t } = useTranslation("auth")',
        'i18n.t("',
      })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 8 })

      local result = nil
      blink.complete({ bufnr = buf, line = 'i18n.t("', cursor = { 2, 8 } }, function(items)
        result = items
      end)

      local labels = {}
      for _, item in ipairs(result) do
        labels[item.label] = true
      end
      assert.is_true(labels["auth:login.title"])
      assert.is_true(labels["common:home.title"])
    end)
  end)

  it("prioritizes missing-like values (empty or key path)", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"a":{"ok":"OK"},"z":{"missing":"z.missing"}}')
    with_cwd(root, function()
      local result = nil
      blink.complete({}, function(items)
        result = items
      end)
      assert.is_true(#result >= 2)
      assert.are.equal("common:z.missing", result[1].label)
    end)
  end)

  it("returns sorted items even when reaching the completion limit", function()
    local root = helpers.tmpdir()
    -- Create enough keys to exceed the internal limit
    local keys = {}
    for i = 1, 120 do
      keys[string.format("k%03d", i)] = string.format("v%03d", i)
    end
    helpers.write_file(root .. "/locales/ja/common.json", vim.json.encode(keys))
    with_cwd(root, function()
      local result = nil
      blink.complete({}, function(items)
        result = items
      end)
      assert.is_true(#result >= 2)
      -- Verify items are sorted by sortText
      for i = 2, #result do
        assert.is_true(
          result[i - 1].sortText <= result[i].sortText,
          string.format("items not sorted at index %d: %s > %s", i, result[i - 1].sortText, result[i].sortText)
        )
      end
    end)
  end)
end)
