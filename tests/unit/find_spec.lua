local find = require("i18n-status.find")
local helpers = require("tests.helpers")
local state = require("i18n-status.state")

-- Tests change the working directory, so register the parser by absolute path while it still resolves.
local parser_dir = vim.fs.abspath(os.getenv("TREESITTER_INSTALL_DIR") or "deps/treesitter")
pcall(vim.treesitter.language.add, "typescript", { path = parser_dir .. "/parser/typescript.so" })

---@param lines string[]
---@param filetype string
---@param name string
---@return integer
local function source_buffer(lines, filetype, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("find", function()
  local original_select
  local original_notify
  local notifications

  before_each(function()
    state.init("en", {})
    original_select = vim.ui.select
    original_notify = vim.notify
    notifications = {}
    vim.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.ui.select = original_select
    vim.notify = original_notify
  end)

  ---Run `:I18nFind` and pick the result whose key is `key`.
  ---@param bufnr integer
  ---@param query string
  ---@param key string
  ---@param action string|nil
  ---@return string[] offered keys
  local function pick(bufnr, query, key, action)
    local offered = {}
    vim.ui.select = function(items, opts, on_choice)
      local chosen = nil
      for _, item in ipairs(items) do
        offered[#offered + 1] = item.key
        assert.is_string(opts.format_item(item))
        if item.key == key then
          chosen = item
        end
      end
      on_choice(chosen)
    end
    find.run(bufnr, { query = query, action = action })
    return offered
  end

  describe("search", function()
    local cache = {
      languages = { "en", "ja" },
      index = {
        en = {
          ["auth:forgot"] = { value = "Forgot password?", file = "/en/auth.json" },
          ["auth:reset"] = { value = "Reset password", file = "/en/auth.json" },
          ["common:password"] = { value = "Password", file = "/en/common.json" },
          ["common:passwordHint"] = { value = "At least 8 characters", file = "/en/common.json" },
        },
        ja = {
          ["auth:forgot"] = { value = "パスワードを忘れた", file = "/ja/auth.json" },
          ["auth:reset"] = { value = "パスワードの再設定", file = "/ja/auth.json" },
          ["common:password"] = { value = "パスワード", file = "/ja/common.json" },
        },
      },
    }

    ---@param results I18nStatusFindResult[]
    ---@return string[]
    local function keys(results)
      return vim.tbl_map(function(result)
        return result.key
      end, results)
    end

    it("ranks exact value matches before partial value matches and key name matches", function()
      assert.are.same(
        { "common:password", "auth:forgot", "auth:reset", "common:passwordHint" },
        keys(find.search(cache, "  PASSWORD ", "en"))
      )
    end)

    it("matches values of non-primary languages and records the matched language", function()
      local results = find.search(cache, "忘れ", "en")
      assert.are.same({ "auth:forgot" }, keys(results))
      assert.are.equal("ja", results[1].match_lang)
      assert.are.equal("Forgot password?", results[1].values.en)
      assert.are.equal(
        "auth:forgot  │  en: Forgot password?  │  ja: パスワードを忘れた",
        find.format_result(results[1], "en")
      )
    end)

    it("prefers primary language matches within the same rank", function()
      local mixed = {
        languages = { "en", "ja" },
        index = {
          en = { ["z:one"] = { value = "hello world" } },
          ja = { ["a:two"] = { value = "hello there" } },
        },
      }
      assert.are.same({ "z:one", "a:two" }, keys(find.search(mixed, "hello", "en")))
      assert.are.same({ "a:two", "z:one" }, keys(find.search(mixed, "hello", "ja")))
    end)

    it("ignores the case of non-ASCII letters", function()
      local accented = {
        languages = { "fr" },
        index = { fr = { ["common:school"] = { value = "École" }, ["common:ÉTAT"] = { value = "x" } } },
      }
      assert.are.same({ "common:school" }, keys(find.search(accented, "école", "fr")))
      assert.are.same({ "common:ÉTAT" }, keys(find.search(accented, "état", "fr")))
    end)

    it("returns nothing for an empty query", function()
      assert.are.same({}, find.search(cache, "   ", "en"))
    end)
  end)

  describe("insert", function()
    local root

    before_each(function()
      root = helpers.tmpdir()
      helpers.write_file(root .. "/locales/en/auth.json", '{"login":{"title":"Sign in"}}')
      helpers.write_file(root .. "/locales/en/common.json", '{"actions":{"save":"Save"}}')
    end)

    it("replaces the string argument of a translation call with a namespace-relative key", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth")',
          't("sig")',
        }, "typescript", root .. "/src/relative.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 6 })

        pick(buf, "sign in", "auth:login.title")

        assert.are.same({ 't("login.title")' }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
        assert.are.same({ 2, 14 }, vim.api.nvim_win_get_cursor(0))
      end)
    end)

    it("qualifies keys from another i18next namespace", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth")',
          "t('')",
        }, "typescript", root .. "/src/qualified.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 3 })

        pick(buf, "save", "common:actions.save")

        assert.are.same({ "t('common:actions.save')" }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
      end)
    end)

    it("inserts a call to the translator in scope outside a string argument", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          "function Page() {",
          '  const { t: tt } = useTranslation("auth");',
          "",
          "}",
        }, "typescript", root .. "/src/call.ts")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })

        pick(buf, "sign", "auth:login.title")

        assert.are.same({ 'tt("login.title")' }, vim.api.nvim_buf_get_lines(buf, 2, 3, false))
      end)
    end)

    it("replaces the whole literal argument of aliased, multiline, and escaped calls", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t: tt } = useTranslation("auth")',
          'tt("")',
          "tt(",
          '  "old"',
          ")",
          [[tt("old\"tail")]],
        }, "typescript", root .. "/src/literals.ts")

        vim.api.nvim_win_set_cursor(0, { 2, 4 })
        pick(buf, "sign", "auth:login.title")
        vim.api.nvim_win_set_cursor(0, { 4, 4 })
        pick(buf, "sign", "auth:login.title")
        vim.api.nvim_win_set_cursor(0, { 6, 6 })
        pick(buf, "sign", "auth:login.title")

        assert.are.same({
          'tt("login.title")',
          "tt(",
          '  "login.title"',
          ")",
          'tt("login.title")',
        }, vim.api.nvim_buf_get_lines(buf, 1, -1, false))
      end)
    end)

    it("replaces the typed prefix of a call that does not parse yet", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth")',
          't("lo)',
        }, "typescript", root .. "/src/unclosed.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 5 })

        pick(buf, "sign", "auth:login.title")

        -- The translator binding is unknown while the source does not parse, so the key stays qualified.
        assert.are.same({ 't("auth:login.title)' }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
      end)
    end)

    it("inserts only the full key inside a string that is not a translation argument", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth")',
          "const key = 'x';",
        }, "typescript", root .. "/src/string.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 13 })

        pick(buf, "sign", "auth:login.title")

        assert.are.same({ "const key = 'auth:login.titlex';" }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
      end)
    end)

    it("treats template strings opened on earlier lines as strings", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth")',
          "const text = `first",
          "second ${value}`;",
        }, "typescript", root .. "/src/template.ts")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        pick(buf, "sign", "auth:login.title")
        vim.api.nvim_win_set_cursor(0, { 3, 25 })
        pick(buf, "sign", "auth:login.title")

        assert.are.same(
          { 'auth:login.titlesecond ${t("login.title")value}`;' },
          vim.api.nvim_buf_get_lines(buf, 2, 3, false)
        )
      end)
    end)

    it("refuses translators whose keyPrefix rewrites keys", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const { t } = useTranslation("auth", { keyPrefix: "login" })',
          't("")',
        }, "typescript", root .. "/src/prefix.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 3 })

        pick(buf, "sign", "auth:login.title")

        assert.are.same({ 't("")' }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
        assert.is_truthy(notifications[#notifications].msg:find("cannot be resolved statically", 1, true))
      end)
    end)

    it("does not move the buffer when insertion is aborted", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({ 't("")' }, "typescript", root .. "/src/aborted.ts")
        vim.api.nvim_win_set_cursor(0, { 1, 3 })

        pick(buf, "sign", "missing:key")

        assert.are.same({ 't("")' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
      end)
    end)
  end)

  describe("next-intl", function()
    local root

    before_each(function()
      root = helpers.tmpdir()
      helpers.write_file(
        root .. "/messages/en.json",
        '{"Home":{"title":"Welcome","Form":{"submit":"Send"}},"Auth":{"login":"Sign in"}}'
      )
    end)

    it("spells keys relative to a nested namespace", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const t = useTranslations("Home.Form")',
          't("")',
        }, "typescript", root .. "/src/nested.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 3 })

        pick(buf, "send", "Home:Form.submit")

        assert.are.same({ 't("submit")' }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
      end)
    end)

    it("refuses keys outside the bound namespace", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({
          'const t = useTranslations("Home")',
          't("")',
        }, "typescript", root .. "/src/outside.ts")
        vim.api.nvim_win_set_cursor(0, { 2, 3 })

        pick(buf, "sign in", "Auth:login")

        assert.are.same({ 't("")' }, vim.api.nvim_buf_get_lines(buf, 1, 2, false))
        assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
        assert.is_truthy(notifications[#notifications].msg:find("outside namespace 'Home'", 1, true))
      end)
    end)

    it("inserts the full message path without a translator in scope", function()
      helpers.with_cwd(root, function()
        local buf = source_buffer({ "const key = ;" }, "typescript", root .. "/src/plain.ts")
        vim.api.nvim_win_set_cursor(0, { 1, 12 })

        pick(buf, "welcome", "Home:title")

        assert.are.same({ "const key = Home.title;" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end)
    end)
  end)

  describe("open", function()
    it("opens the resource file of the matched language outside source buffers", function()
      local root = helpers.tmpdir()
      helpers.write_file(root .. "/locales/en/auth.json", '{"forgot":"Forgot password?"}')
      helpers.write_file(root .. "/locales/ja/auth.json", '{"forgot":"パスワードを忘れた"}')
      helpers.with_cwd(root, function()
        local buf = source_buffer({ "{}" }, "json", root .. "/notes.json")
        local opened = nil
        local original_cmd = vim.api.nvim_cmd
        vim.api.nvim_cmd = function(cmd, opts)
          if cmd.cmd == "edit" then
            opened = cmd.args[1]
            return
          end
          return original_cmd(cmd, opts)
        end

        local ok, err = pcall(pick, buf, "忘れた", "auth:forgot")
        vim.api.nvim_cmd = original_cmd

        assert.is_true(ok, err)
        assert.is_truthy(opened and opened:find("/locales/ja/auth.json", 1, true))
        assert.are.same({ "{}" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end)
    end)

    it("refuses insertion into a buffer that is not a JS/TS source", function()
      local buf = source_buffer({ "{}" }, "json", helpers.tmpdir() .. "/x.json")
      local selected = false
      vim.ui.select = function()
        selected = true
      end

      find.run(buf, { query = "x", action = "insert" })

      assert.is_false(selected)
      assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
    end)
  end)
end)
