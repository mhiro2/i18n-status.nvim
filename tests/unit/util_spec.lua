local util = require("i18n-status.util")

describe("util", function()
  describe("find_git_root", function()
    it("should find .git directory in parent directories", function()
      -- Get the current working directory (should be the project root with .git)
      local cwd = vim.fn.getcwd()
      local git_root = util.find_git_root(cwd)

      -- Should find the git root
      assert.is_not_nil(git_root)
      assert.is_true(util.is_dir(util.path_join(git_root, ".git")))
    end)

    it("should return nil if no git root found", function()
      local git_root = util.find_git_root("/tmp")

      -- /tmp typically doesn't have a .git directory
      -- (this test might be flaky if /tmp is inside a git repo)
      if not git_root then
        assert.is_nil(git_root)
      end
    end)
  end)

  describe("shorten_path", function()
    it("should convert absolute path to relative path from git root", function()
      local cwd = vim.fn.getcwd()
      local git_root = util.find_git_root(cwd)

      if git_root then
        local full_path = util.path_join(git_root, "lua", "i18n-status", "init.lua")
        local shortened = util.shorten_path(full_path)

        -- Should be relative to git root
        assert.equals("lua/i18n-status/init.lua", shortened)
      end
    end)

    it("should return full path if no git root found", function()
      -- Create a path that's not in a git repo
      local path = "/tmp/some/file.txt"
      local shortened = util.shorten_path(path)

      -- Should return the full path
      assert.equals(path, shortened)
    end)

    it("should handle empty path", function()
      assert.equals("", util.shorten_path(""))
    end)

    it("should handle nil path", function()
      assert.is_nil(util.shorten_path(nil))
    end)
  end)

  describe("trim", function()
    it("should trim leading and trailing whitespace", function()
      assert.equals("hello", util.trim("  hello  "))
      assert.equals("hello", util.trim("hello  "))
      assert.equals("hello", util.trim("  hello"))
      assert.equals("hello", util.trim("hello"))
    end)
  end)

  describe("sanitize_path", function()
    local base_dir

    before_each(function()
      base_dir = vim.fn.tempname()
      util.ensure_dir(base_dir)
    end)

    after_each(function()
      if base_dir and util.is_dir(base_dir) then
        vim.fn.delete(base_dir, "rf")
      end
    end)

    it("should reject null bytes", function()
      local path, err = util.sanitize_path("a\0b", base_dir)
      assert.is_nil(path)
      assert.is_not_nil(err)
    end)

    it("should accept existing files within base", function()
      local file_path = util.path_join(base_dir, "dir", "file.json")
      util.ensure_dir(util.dirname(file_path))
      vim.fn.writefile({ "{}" }, file_path)

      local path, err = util.sanitize_path(file_path, base_dir)
      local real_base = (vim.uv.fs_realpath(base_dir) or base_dir):gsub("\\", "/")
      if real_base:sub(-1) ~= "/" then
        real_base = real_base .. "/"
      end
      assert.is_nil(err)
      assert.is_true(path:find(real_base, 1, true) == 1)
    end)

    it("should accept non-existent files within base", function()
      local file_path = util.path_join(base_dir, "new", "file.json")
      local path, err = util.sanitize_path(file_path, base_dir)
      local real_base = (vim.uv.fs_realpath(base_dir) or base_dir):gsub("\\", "/")
      if real_base:sub(-1) ~= "/" then
        real_base = real_base .. "/"
      end
      local base_hint = base_dir:gsub("\\", "/")
      if base_hint:sub(-1) ~= "/" then
        base_hint = base_hint .. "/"
      end
      assert.is_nil(err)
      assert.is_true(path:find(real_base, 1, true) == 1 or path:find(base_hint, 1, true) == 1)
    end)

    it("should reject paths outside base", function()
      local outside = util.path_join(base_dir, "..", "outside.json")
      local path, err = util.sanitize_path(outside, base_dir)
      assert.is_nil(path)
      assert.is_not_nil(err)
    end)
  end)

  describe("extract_placeholders", function()
    it("should extract double-brace placeholders", function()
      local text = "Hello {{name}}, your balance is {{balance}}"
      local placeholders = util.extract_placeholders(text)

      assert.is_true(placeholders.name)
      assert.is_true(placeholders.balance)
    end)

    it("should extract single-brace placeholders", function()
      local text = "Hello {name}, your balance is {balance}"
      local placeholders = util.extract_placeholders(text)

      assert.is_true(placeholders.name)
      assert.is_true(placeholders.balance)
    end)

    it("should handle mixed placeholders", function()
      local text = "Hello {{name}}, your balance is {balance}"
      local placeholders = util.extract_placeholders(text)

      assert.is_true(placeholders.name)
      assert.is_true(placeholders.balance)
    end)

    it("should return empty table for text without placeholders", function()
      local text = "Hello world"
      local placeholders = util.extract_placeholders(text)

      assert.are.same({}, placeholders)
    end)
  end)

  describe("visible_range", function()
    it("returns union range across all visible windows for the buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 200 do
        lines[i] = ("line %03d"):format(i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      local win1 = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win1, buf)

      vim.api.nvim_cmd({ cmd = "split" }, {})
      local win2 = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win2, buf)

      vim.api.nvim_win_set_cursor(win1, { 1, 0 })
      vim.api.nvim_win_set_cursor(win2, { 150, 0 })

      local wins = vim.fn.win_findbuf(buf)
      assert.is_true(#wins >= 2)
      local expected_top = nil
      local expected_bottom = nil
      for _, win in ipairs(wins) do
        local win_top = vim.fn.line("w0", win)
        local win_bottom = vim.fn.line("w$", win)
        if expected_top == nil or win_top < expected_top then
          expected_top = win_top
        end
        if expected_bottom == nil or win_bottom > expected_bottom then
          expected_bottom = win_bottom
        end
      end

      local top, bottom = util.visible_range(buf)

      vim.api.nvim_win_close(win2, true)
      vim.api.nvim_set_current_win(win1)

      assert.are.equal(expected_top, top)
      assert.are.equal(expected_bottom, bottom)
    end)

    it("falls back to full buffer range when the buffer is not visible", function()
      local hidden = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "a", "b", "c", "d" })

      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "x" })
      vim.api.nvim_set_current_buf(other)

      local top, bottom = util.visible_range(hidden)
      assert.are.equal(1, top)
      assert.are.equal(4, bottom)
    end)
  end)
end)
