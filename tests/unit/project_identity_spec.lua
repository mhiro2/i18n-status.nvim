local helpers = require("tests.helpers")
local project_identity = require("i18n-status.project_identity")
local resources = require("i18n-status.resources")

local function with_overrides(overrides, callback)
  local originals = {}
  for _, override in ipairs(overrides) do
    originals[#originals + 1] = {
      key = override.key,
      target = override.target,
      value = override.target[override.key],
    }
    override.target[override.key] = override.value
  end
  local result = { xpcall(callback, debug.traceback) }
  for index = #originals, 1, -1 do
    local original = originals[index]
    original.target[original.key] = original.value
  end
  if not result[1] then
    error(result[2])
  end
  return unpack(result, 2)
end

local function make_source_buffer(path)
  helpers.write_file(path, "export const value = 1\n")
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, path)
  vim.bo[bufnr].filetype = "typescript"
  return bufnr
end

describe("project identity", function()
  it("requests an exact cache instead of accepting an unrelated watched cache", function()
    local root = helpers.tmpdir()
    local source_path = root .. "/src/app.ts"
    local bufnr = make_source_buffer(source_path)
    local ensure_start_dir
    local ensure_opts
    local parent_cache = {
      key = "parent-cache",
      roots = { { kind = "i18next", path = root .. "/locales" } },
    }
    local watched_child_cache = {
      key = "watched-child-cache",
      roots = { { kind = "i18next", path = root .. "/packages/child/locales" } },
    }

    with_overrides({
      {
        target = resources,
        key = "ensure_index",
        value = function(start_dir, opts)
          ensure_start_dir = start_dir
          ensure_opts = vim.deepcopy(opts)
          return opts and opts.exact and parent_cache or watched_child_cache
        end,
      },
      {
        target = resources,
        key = "project_root",
        value = function(_, roots)
          assert.is_true(roots == parent_cache.roots)
          return root
        end,
      },
    }, function()
      local identity, err = project_identity.resolve(bufnr)

      assert.is_nil(err)
      assert.are.equal(vim.uv.fs_realpath(root .. "/src"), ensure_start_dir)
      assert.are.same({ exact = true }, ensure_opts)
      assert.are.equal("parent-cache", identity.cache_key)
      assert.is_true(identity.cache == parent_cache)
    end)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("rejects a buffer name change while resolving its resource cache", function()
    local root = helpers.tmpdir()
    local source_path = root .. "/src/app.ts"
    local moved_path = root .. "/src/moved.ts"
    local bufnr = make_source_buffer(source_path)
    helpers.write_file(moved_path, "export const value = 1\n")

    with_overrides({
      {
        target = resources,
        key = "ensure_index",
        value = function()
          vim.api.nvim_buf_set_name(bufnr, moved_path)
          return { key = "project", roots = {} }
        end,
      },
      {
        target = resources,
        key = "project_root",
        value = function()
          return root
        end,
      },
    }, function()
      local identity, err = project_identity.resolve(bufnr)

      assert.is_nil(identity)
      assert.are.equal("source buffer name changed during project resolution", err)
    end)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("rejects a buffer filetype change while resolving its resource cache", function()
    local root = helpers.tmpdir()
    local bufnr = make_source_buffer(root .. "/src/app.ts")

    with_overrides({
      {
        target = resources,
        key = "ensure_index",
        value = function()
          vim.bo[bufnr].filetype = "javascript"
          return { key = "project", roots = {} }
        end,
      },
      {
        target = resources,
        key = "project_root",
        value = function()
          return root
        end,
      },
    }, function()
      local identity, err = project_identity.resolve(bufnr)

      assert.is_nil(identity)
      assert.are.equal("source buffer filetype changed during project resolution", err)
    end)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("requires both the canonical root and cache key to match", function()
    local expected = { cache_key = "project-a", root = "/project" }

    assert.is_true(project_identity.same_project({ cache_key = "project-a", root = "/project" }, expected))
    assert.is_false(project_identity.same_project({ cache_key = "project-b", root = "/project" }, expected))
    assert.is_false(project_identity.same_project({ cache_key = "project-a", root = "/other" }, expected))
  end)
end)
