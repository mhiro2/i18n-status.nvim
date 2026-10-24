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

  ---@param source_line string
  ---@return string[]
  local function complete_next_intl(source_line)
    local root = helpers.tmpdir()
    helpers.write_file(
      root .. "/messages/ja.json",
      '{"Home":{"title":"ホーム","Form":{"submit":"送信"}},"Auth":{"login":"ログイン"}}'
    )
    local labels = {}
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { source_line, 't("' })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 3 })

      blink.complete({ bufnr = buf, line = 't("', cursor = { 2, 3 } }, function(items)
        for _, item in ipairs(items) do
          labels[#labels + 1] = item.insertText
        end
      end)
    end)
    table.sort(labels)
    return labels
  end

  it("completes next-intl keys relative to a nested namespace", function()
    assert.are.same({ "submit" }, complete_next_intl('const t = useTranslations("Home.Form")'))
  end)

  it("completes full message paths for a root next-intl translator", function()
    assert.are.same(
      { "Auth.login", "Home.Form.submit", "Home.title" },
      complete_next_intl("const t = useTranslations()")
    )
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

  it("completes only inside the first string argument of a translation call", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "typescript"
    local source = blink.new()
    ---@param line string
    ---@return boolean
    local function available(line)
      return source:is_available({ bufnr = buf, line = line, cursor = { 1, #line } })
    end

    for _, line in ipairs({
      't("',
      "i18n.t('login.",
      't( "home',
      "t(`home",
      '{t("a")} <Foo label={t("',
      [[t("it\"s]],
      '`Hello ${t("home.',
      "<p>Don't {t(\"home.",
      '<p>See http://example.com {t("',
      't(/* key */ "home',
    }) do
      assert.is_true(available(line), line)
    end
    for _, line in ipairs({
      "t(",
      'alert("',
      'axios.get("',
      'map.set("',
      '"x".split("',
      'parseInt("',
      '// t("',
      '/* t(" */ foo("',
      't("done"); console.log("',
      't("foo") + "',
      't("login.title", { count: "',
      "const s = \"t('",
      "t(`${prefix}.",
      '`${t("a")} ${label("',
      'case "x":// t("',
    }) do
      assert.is_false(available(line), line)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("completes keys beyond the item limit from the typed text", function()
    local root = helpers.tmpdir()
    local keys = {}
    for i = 1, 120 do
      keys[string.format("k%03d", i)] = string.format("v%03d", i)
    end
    helpers.write_file(root .. "/locales/ja/common.json", vim.json.encode(keys))
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      local source = blink.new()
      ---@param line string
      ---@return table
      local function request(line)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
        local response = nil
        source:get_completions({ bufnr = buf, line = line, cursor = { 1, #line } }, function(result)
          response = result
        end)
        return response
      end

      local all = request('t("')
      assert.are.equal(100, #all.items)
      assert.is_true(all.is_incomplete_forward)
      -- The limit keeps the first 100 keys in sort order.
      for i, item in ipairs(all.items) do
        assert.are.equal(string.format("k%03d", i), item.label)
        if i > 1 then
          assert.is_true(all.items[i - 1].sortText <= item.sortText, "items are not sorted at index " .. i)
        end
      end

      local narrowed = request('t("k12')
      local labels = {}
      for _, item in ipairs(narrowed.items) do
        labels[#labels + 1] = item.label
      end
      assert.are.same({ "k120" }, labels)
      assert.is_false(narrowed.is_incomplete_forward)
      -- Deleting typed text can match keys the filter left out.
      assert.is_true(narrowed.is_incomplete_backward)
    end)
  end)

  it("does not complete explicit namespaces through a shadowed translation symbol", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"title":"タイトル"}')
    with_cwd(root, function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'const { t } = useTranslation("common")',
        "function f(t) {",
        '  t("common:',
        "}",
      })
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 12 })

      local result = nil
      blink.complete({ bufnr = buf, line = '  t("common:', cursor = { 3, 12 } }, function(items)
        result = items
      end)

      assert.are.same({}, result)
    end)
  end)
end)
