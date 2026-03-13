local fs = require("i18n-status.fs")

describe("fs", function()
  describe("path helpers", function()
    local base_dir

    before_each(function()
      base_dir = vim.fn.tempname()
      fs.ensure_dir(base_dir)
    end)

    after_each(function()
      if base_dir and fs.is_dir(base_dir) then
        vim.fn.delete(base_dir, "rf")
      end
    end)

    it("joins paths and resolves dirname", function()
      local file_path = fs.path_join(base_dir, "nested", "file.json")

      assert.are.equal(fs.path_join(base_dir, "nested"), fs.dirname(file_path))
    end)

    it("creates directories and reports file metadata", function()
      local file_path = fs.path_join(base_dir, "nested", "file.json")
      assert.is_true(fs.ensure_dir(fs.dirname(file_path)))

      vim.fn.writefile({ '{"ok":true}' }, file_path)

      assert.is_true(fs.file_exists(file_path))
      assert.is_true(fs.is_dir(fs.dirname(file_path)))
      assert.is_truthy(fs.read_file(file_path):find('{"ok":true}', 1, true))
      assert.is_truthy(fs.file_mtime(file_path))
    end)

    it("normalizes existing path with realpath", function()
      local file_path = fs.path_join(base_dir, "a.json")
      vim.fn.writefile({ "{}" }, file_path)

      local expected = (vim.uv.fs_realpath(file_path) or file_path):gsub("\\", "/")

      assert.are.equal(expected, fs.normalize_path(file_path))
    end)

    it("normalizes unresolved relative path with base_dir", function()
      local normalized = fs.normalize_path("nested/new.json", base_dir)
      local real_base = (vim.uv.fs_realpath(base_dir) or base_dir):gsub("\\", "/")
      if real_base:sub(-1) ~= "/" then
        real_base = real_base .. "/"
      end
      local base_hint = base_dir:gsub("\\", "/")
      if base_hint:sub(-1) ~= "/" then
        base_hint = base_hint .. "/"
      end

      assert.is_true(
        type(normalized) == "string"
          and (normalized:find(real_base, 1, true) == 1 or normalized:find(base_hint, 1, true) == 1)
      )
    end)

    it("checks whether a path is under a root", function()
      local child = fs.path_join(base_dir, "locales", "ja", "common.json")
      local outside = fs.path_join(base_dir, "..", "outside.json")

      assert.is_true(fs.path_under(child, base_dir))
      assert.is_false(fs.path_under(outside, base_dir))
    end)
  end)

  describe("git-aware paths", function()
    it("finds the current git root", function()
      local cwd = vim.fn.getcwd()
      local git_root = fs.find_git_root(cwd)

      assert.is_not_nil(git_root)
      assert.is_true(fs.is_dir(fs.path_join(git_root, ".git")))
    end)

    it("returns nil when no git root exists", function()
      local base_dir = vim.fn.tempname()
      fs.ensure_dir(fs.path_join(base_dir, "nested"))

      local git_root = fs.find_git_root(fs.path_join(base_dir, "nested"))

      vim.fn.delete(base_dir, "rf")
      assert.is_nil(git_root)
    end)

    it("shortens a path relative to the repository root", function()
      local cwd = vim.fn.getcwd()
      local git_root = fs.find_git_root(cwd)
      if not git_root then
        return
      end

      local full_path = fs.path_join(git_root, "lua", "i18n-status", "init.lua")

      assert.are.equal("lua/i18n-status/init.lua", fs.shorten_path(full_path))
    end)

    it("returns the full path when no git root exists", function()
      local path = "/tmp/some/file.txt"

      assert.are.equal(path, fs.shorten_path(path))
      assert.are.equal("", fs.shorten_path(""))
      assert.is_nil(fs.shorten_path(nil))
    end)
  end)

  describe("sanitize_path", function()
    local base_dir

    before_each(function()
      base_dir = vim.fn.tempname()
      fs.ensure_dir(base_dir)
    end)

    after_each(function()
      if base_dir and fs.is_dir(base_dir) then
        vim.fn.delete(base_dir, "rf")
      end
    end)

    it("rejects null bytes", function()
      local path, err = fs.sanitize_path("a\0b", base_dir)

      assert.is_nil(path)
      assert.is_not_nil(err)
    end)

    it("accepts existing files within base", function()
      local file_path = fs.path_join(base_dir, "dir", "file.json")
      fs.ensure_dir(fs.dirname(file_path))
      vim.fn.writefile({ "{}" }, file_path)

      local path, err = fs.sanitize_path(file_path, base_dir)
      local real_base = (vim.uv.fs_realpath(base_dir) or base_dir):gsub("\\", "/")
      if real_base:sub(-1) ~= "/" then
        real_base = real_base .. "/"
      end

      assert.is_nil(err)
      assert.is_true(path:find(real_base, 1, true) == 1)
    end)

    it("accepts non-existent files within base", function()
      local file_path = fs.path_join(base_dir, "new", "file.json")
      local path, err = fs.sanitize_path(file_path, base_dir)
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

    it("rejects paths outside base", function()
      local outside = fs.path_join(base_dir, "..", "outside.json")
      local path, err = fs.sanitize_path(outside, base_dir)

      assert.is_nil(path)
      assert.is_not_nil(err)
    end)
  end)
end)
