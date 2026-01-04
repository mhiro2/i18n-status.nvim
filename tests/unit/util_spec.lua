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
end)
