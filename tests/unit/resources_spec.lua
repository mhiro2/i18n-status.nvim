local resources = require("i18n-status.resources")
local rpc = require("i18n-status.rpc")
local watcher = require("i18n-status.watcher")
local helpers = require("tests.helpers")
local key_write = require("i18n-status.key_write")

local function write(path, content)
  helpers.write_file(path, content)
end

local function make_fifo(path)
  vim.fn.system({ "mkfifo", path })
  assert.are.equal(0, vim.v.shell_error)
end

local function find_recovery_with_content(root, content)
  for _, path in ipairs(vim.fn.glob(root .. "/.i18n-status-*", false, true)) do
    if helpers.read_file(path) == content then
      return path
    end
  end
  return nil
end

local function with_umask(mask, callback)
  local ffi = require("ffi")
  local jit = require("jit")
  local declaration = jit.os == "OSX" and "unsigned short umask(unsigned short);" or "unsigned int umask(unsigned int);"
  pcall(ffi.cdef, declaration)
  local previous = tonumber(ffi.C.umask(mask))
  local ok, err = xpcall(callback, debug.traceback)
  ffi.C.umask(previous)
  if not ok then
    error(err)
  end
end

---@param start_dir string
---@return table
local function ensure_index_async(start_dir)
  local done = false
  local result = nil
  resources.ensure_index_async(start_dir, nil, function(cache)
    result = cache
    done = true
  end)
  local ok = vim.wait(5000, function()
    return done
  end)
  assert.is_true(ok, "resources.ensure_index_async timed out")
  return result
end

describe("resources", function()
  it("loads i18next resources", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local cache = resources.ensure_index(root)
    table.sort(cache.languages)
    assert.are.same({ "en", "ja" }, cache.languages)
    assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)
  end)

  it("loads i18next resources asynchronously", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')
    local cache = ensure_index_async(root)
    table.sort(cache.languages)
    assert.are.same({ "en", "ja" }, cache.languages)
    assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)
  end)

  it("loads next-intl with priority", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en/common.json", '{"title":"Common"}')
    write(root .. "/messages/en.json", '{"common":{"title":"Root"}}')
    local cache = resources.ensure_index(root)
    assert.are.equal("Root", cache.index.en["common:title"].value)
  end)

  it("merges multiple roots by entry priority", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/en/common.json", '{"title":"i18next"}')
    write(root .. "/messages/en.json", '{"common":{"title":"next-intl"}}')

    local cache = resources.ensure_index(root)
    assert.are.equal("i18next", cache.index.en["common:title"].value)
    assert.are.equal(30, cache.index.en["common:title"].priority)
  end)

  it("handles invalid json", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", "{")
    local cache = resources.ensure_index(root)
    assert.is_nil((cache.index.ja or {}).__error__)
    assert.are.equal(1, #(cache.errors or {}))
    assert.are.equal("ja", cache.errors[1].lang)
    assert.is_truthy(type(cache.errors[1].error) == "string" and cache.errors[1].error ~= "")
  end)

  it("reloads when file mtime changes", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"A"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"B"}}')
    local cache = resources.ensure_index(root)
    assert.are.equal("A", cache.index.ja["common:login.title"].value)

    -- Sleep to ensure mtime changes on filesystems with second-level precision
    vim.uv.sleep(1000)
    write(root .. "/locales/ja/common.json", '{"login":{"title":"C"}}')
    cache = resources.ensure_index(root)
    assert.are.equal("C", cache.index.ja["common:login.title"].value)
  end)

  it("reuses cache without rebuild when watcher is disabled and files are unchanged", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"A"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"B"}}')

    local build_count = 0
    local original_build_index = resources.build_index
    resources.build_index = function(roots)
      build_count = build_count + 1
      return original_build_index(roots)
    end

    local ok, err = pcall(function()
      local cache1 = resources.ensure_index(root)
      local cache2 = resources.ensure_index(root)
      assert.is_true(cache1 == cache2)
      assert.are.equal(1, build_count)
    end)

    resources.build_index = original_build_index
    if not ok then
      error(err)
    end
  end)

  it("preserves the last-good cache when a deadline-aware build times out", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"last good"}}')

    local cache = resources.ensure_index(root)
    assert.are.equal("last good", cache.index.ja["common:login.title"].value)
    cache.dirty = true

    local original_request_sync = rpc.request_sync
    local ok, err = pcall(function()
      rpc.request_sync = function(method)
        if method == "resource/resolveRoots" then
          return { roots = cache.roots }, nil
        end
        if method == "resource/buildIndex" then
          return nil, "timeout after 10ms"
        end
        return {}, nil
      end

      local preserved, build_err = resources.ensure_index(root, { timeout_ms = 50 })
      assert.is_true(preserved == cache)
      assert.are.equal("timeout after 10ms", build_err)
      assert.are.equal("last good", preserved.index.ja["common:login.title"].value)
      assert.is_true(preserved.dirty)
      assert.is_true(resources.caches[cache.key] == cache)
    end)
    rpc.request_sync = original_request_sync
    assert.is_true(ok, err)
  end)

  it("skips resolveRoots RPC when watcher is active for start_dir", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"login":{"title":"A"}}')
    write(root .. "/locales/en/common.json", '{"login":{"title":"B"}}')

    local cache = resources.ensure_index(root)
    local resolve_roots_calls = 0

    local original_is_watching = watcher.is_watching
    local original_request_sync = rpc.request_sync
    watcher.is_watching = function(key)
      return key == cache.key
    end
    rpc.request_sync = function(method, params, timeout_ms)
      if method == "resource/resolveRoots" then
        resolve_roots_calls = resolve_roots_calls + 1
      end
      return original_request_sync(method, params, timeout_ms)
    end

    local ok, err = pcall(function()
      local reused = resources.ensure_index(root)
      assert.is_true(reused == cache)
      assert.are.equal(0, resolve_roots_calls)
    end)

    watcher.is_watching = original_is_watching
    rpc.request_sync = original_request_sync
    if not ok then
      error(err)
    end
  end)

  it("bypasses a watched child cache when exact identity is requested", function()
    local root = helpers.tmpdir()
    local parent_root = root .. "/locales"
    local child_root = root .. "/packages/child/locales"
    write(parent_root .. "/en/common.json", '{"title":"parent"}')
    write(child_root .. "/en/common.json", '{"title":"child"}')

    local original_caches = resources.caches
    local original_last_cache_key = resources.last_cache_key
    local original_is_watching = watcher.is_watching
    local original_request_sync = rpc.request_sync
    local child_cache = {
      checked_at = vim.uv.now(),
      dirty = false,
      errors = {},
      files = {},
      index = {},
      key = "watched-child",
      languages = { "en" },
      namespaces = { "common" },
      roots = { { kind = "i18next", path = child_root } },
    }
    resources.caches = { [child_cache.key] = child_cache }
    watcher.is_watching = function(key)
      return key == child_cache.key
    end
    rpc.request_sync = function(method)
      if method == "resource/resolveRoots" then
        return { roots = { { kind = "i18next", path = parent_root } } }, nil
      end
      if method == "resource/buildIndex" then
        return {
          errors = {},
          files = {},
          index = {},
          languages = { "en" },
          namespaces = { "common" },
        },
          nil
      end
      error("unexpected RPC method: " .. method)
    end

    local ok, err = pcall(function()
      local cache = resources.ensure_index(root, { exact = true })
      local expected_parent_root = vim.uv.fs_realpath(parent_root) or parent_root

      assert.is_false(cache == child_cache)
      assert.are.same({ { kind = "i18next", path = expected_parent_root } }, cache.roots)
    end)

    resources.caches = original_caches
    resources.last_cache_key = original_last_cache_key
    watcher.is_watching = original_is_watching
    rpc.request_sync = original_request_sync
    if not ok then
      error(err)
    end
  end)

  it("prefers next-intl root files when available", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en.json", '{"common":{"title":"Root"}}')
    write(root .. "/messages/en/common.json", '{"title":"Namespaced"}')

    local path = resources.namespace_path(root, "en", "common")
    local expected = vim.uv.fs_realpath(root .. "/messages/en.json") or (root .. "/messages/en.json")
    assert.are.equal(expected, path)
  end)

  it("falls back to namespace files when root missing", function()
    local root = helpers.tmpdir()
    write(root .. "/messages/en/common.json", '{"title":"Namespaced"}')

    local path = resources.namespace_path(root, "en", "common")
    local expected = vim.uv.fs_realpath(root .. "/messages/en/common.json") or (root .. "/messages/en/common.json")
    assert.are.equal(expected, path)
  end)

  it("detects new files when watcher disabled", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key1":"value1"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.is_nil(cache.index.ja["new:key2"])

    write(root .. "/locales/ja/new.json", '{"key2":"value2"}')

    cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.are.equal("value2", cache.index.ja["new:key2"].value)
  end)

  it("detects deleted files when watcher disabled", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key1":"value1"}')
    write(root .. "/locales/ja/temp.json", '{"key2":"value2"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.are.equal("value2", cache.index.ja["temp:key2"].value)

    os.remove(root .. "/locales/ja/temp.json")

    cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key1"].value)
    assert.is_nil(cache.index.ja["temp:key2"])
  end)

  it("validates structure before checking file mtimes", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"key":"value1"}')

    local cache = resources.ensure_index(root)
    assert.are.equal("value1", cache.index.ja["common:key"].value)

    write(root .. "/locales/ja/new.json", '{"key2":"value2"}')

    cache = resources.ensure_index(root)
    assert.are.equal("value2", cache.index.ja["new:key2"].value)
  end)

  it("supports cooperative yields during large index rebuilds", function()
    local root = helpers.tmpdir()
    for i = 1, 60 do
      write(root .. "/locales/ja/ns" .. i .. ".json", '{"k":"ja"}')
      write(root .. "/locales/en/ns" .. i .. ".json", '{"k":"en"}')
    end

    local resume_count = 0
    local co = coroutine.create(function()
      resources.ensure_index(root, { cooperative = true })
    end)

    while coroutine.status(co) ~= "dead" do
      resume_count = resume_count + 1
      local ok, err = coroutine.resume(co)
      assert.is_true(ok, err)
    end

    assert.is_true(resume_count > 1)
  end)

  it("computes project root from common ancestor when no git root", function()
    local root = helpers.tmpdir()
    write(root .. "/public/locales/ja/translation.json", '{"title":"JA"}')
    write(root .. "/public/locales/en/translation.json", '{"title":"EN"}')
    vim.fn.mkdir(root .. "/src/app", "p")

    local project_root = resources.project_root(root .. "/src/app")
    local expected = vim.uv.fs_realpath(root) or root
    assert.are.equal(expected, project_root)
  end)

  describe("resource mutation safety", function()
    it("rejects invalid and non-object JSON roots", function()
      local root = helpers.tmpdir()
      local cases = {
        { name = "invalid", content = "{" },
        { name = "array", content = '["keep-a","keep-b"]' },
        { name = "empty-array", content = "[]" },
        { name = "string", content = '"value"' },
        { name = "number", content = "42" },
        { name = "boolean", content = "true" },
        { name = "false", content = "false" },
        { name = "null", content = "null" },
      }

      for _, case in ipairs(cases) do
        local path = root .. "/" .. case.name .. ".json"
        write(path, case.content)

        local data, style = resources.read_json_table(path)

        assert.is_nil(data, case.name)
        assert.is_truthy(style.error, case.name)
        assert.are.equal(case.content, helpers.read_file(path), case.name)
      end
    end)

    it("accepts an empty JSON object root", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, "{}")
      local data, style = resources.read_json_table(path)
      data.key = "value"

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_true(ok, err)
      assert.are.equal("value", vim.json.decode(helpers.read_file(path)).key)
    end)

    it("rejects an existing file that cannot be read", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"keep":"value"}')
      local original_fs_read = vim.uv.fs_read
      vim.uv.fs_read = function()
        return nil, "simulated read failure"
      end

      local data, style = resources.read_json_table(path)

      vim.uv.fs_read = original_fs_read
      assert.is_nil(data)
      assert.is_truthy(style.error and style.error:find("fs_read", 1, true))
      assert.are.equal('{"keep":"value"}', helpers.read_file(path))
    end)

    it("rejects a FIFO resource without blocking", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      make_fifo(path)
      local started = vim.uv.hrtime()

      local data, style = resources.read_json_table(path)

      assert.is_nil(data)
      assert.is_truthy(style.error and style.error:find("regular file", 1, true))
      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 1000)
      vim.uv.fs_unlink(path)
    end)

    it("rejects an external update after reading", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      write(path, '{"key":"external"}')

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("changed on disk", 1, true))
      assert.are.equal('{"key":"external"}', helpers.read_file(path))
    end)

    it("rejects non-object data at the writer boundary", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local _, style = resources.read_json_table(path)

      local ok, err = resources.write_json_table(path, { "replacement" }, style, { base_dir = root })

      assert.is_false(ok)
      assert.are.equal("JSON root must be an object", err)
      assert.are.equal('{"key":"original"}', helpers.read_file(path))
    end)

    it("rejects creation when another writer creates the file first", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      write(path, '{"key":"external"}')

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("changed on disk", 1, true))
      assert.are.equal('{"key":"external"}', helpers.read_file(path))
    end)

    it("leaves an unverified new-file install at the canonical target", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local stage_path = plan.atomic.stage
      local saved_path = root .. "/saved-plugin-stage.json"
      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if not injecting and not injected and stat and stat.type == "file" and stat.ino == plan.atomic.intended.ino then
          injecting = true
          injected = true
          local renamed, rename_err = uv.fs_rename(stage_path, saved_path)
          assert.is_truthy(renamed, rename_err)
          write(stage_path, '{"key":"untrusted-stage"}')
          injecting = false
        end
        return closed, close_err
      end

      local committed, commit_err = resources.commit_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(committed)
      assert.is_true(injected)
      assert.are.equal('{"key":"untrusted-stage"}', helpers.read_file(path))
      assert.is_truthy(commit_err and commit_err:find("canonical target was left in place", 1, true))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_true(discarded, discard_err)
      uv.fs_unlink(saved_path)
    end)

    it("rechecks the disk revision immediately before replacing the file", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local original_fsync = vim.uv.fs_fsync
      vim.uv.fs_fsync = function(fd)
        local ok, err = original_fsync(fd)
        write(path, '{"key":"external"}')
        return ok, err
      end

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      vim.uv.fs_fsync = original_fsync
      assert.is_false(ok)
      assert.is_truthy(err and err:find("changed on disk", 1, true))
      assert.are.equal('{"key":"external"}', helpers.read_file(path))
    end)

    it("rejects a write when the matching loaded buffer is modified", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.bo[bufnr].swapfile = false
      vim.api.nvim_buf_set_name(bufnr, path)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '{"key":"unsaved"}' })
      vim.bo[bufnr].modified = true

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("unsaved changes", 1, true))
      assert.are.equal('{"key":"original"}', helpers.read_file(path))
      assert.are.same({ '{"key":"unsaved"}' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("rejects a parent replaced by an outside symlink after reading", function()
      local root = helpers.tmpdir()
      local outside_dir = helpers.tmpdir()
      local parent = root .. "/pending"
      local path = parent .. "/resource.json"
      vim.fn.mkdir(parent, "p")
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      vim.fn.delete(parent, "d")
      local link_ok, link_err = vim.uv.fs_symlink(outside_dir, parent, { dir = true })
      assert.is_truthy(link_ok, link_err)

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_false(ok)
      assert.is_truthy(err and err:find("unsafe resource path", 1, true))
      assert.is_nil(vim.uv.fs_stat(outside_dir .. "/resource.json"))
      vim.fn.delete(outside_dir, "rf")
    end)

    it("updates the revision after a successful write", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "first"

      local first_ok, first_err = resources.write_json_table(path, data, style, { base_dir = root })
      data.key = "second"
      local second_ok, second_err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_true(first_ok, first_err)
      assert.is_true(second_ok, second_err)
      assert.are.equal("second", vim.json.decode(helpers.read_file(path)).key)
    end)

    it("restores absence when a newly created resource is rolled back", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      local data, style = resources.read_json_table(path)
      data.key = "created"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      assert.is_not_nil(vim.uv.fs_stat(path))

      local rolled_back, rollback_err = resources.rollback_json_write(plan)

      resources.discard_json_write(plan)
      assert.is_true(rolled_back, rollback_err)
      assert.is_nil(vim.uv.fs_lstat(path))
    end)

    it("preserves a concurrent replacement when rolling back a new resource", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      local data, style = resources.read_json_table(path)
      data.key = "created"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      write(path, '{"key":"external"}')

      local rolled_back, rollback_err = resources.rollback_json_write(plan)

      resources.discard_json_write(plan)
      assert.is_false(rolled_back)
      assert.is_truthy(rollback_err and rollback_err:find("changed after", 1, true))
      assert.are.equal('{"key":"external"}', helpers.read_file(path))
    end)

    it("preserves file permissions across atomic replacement", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local chmod_ok, chmod_err = vim.uv.fs_chmod(path, 384) -- 0600
      assert.is_truthy(chmod_ok, chmod_err)
      local data, style = resources.read_json_table(path)
      data.key = "updated"

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_true(ok, err)
      local stat = assert(vim.uv.fs_stat(path))
      assert.are.equal(384, require("bit").band(stat.mode, 511))
    end)

    it("applies umask to new files without changing existing permissions", function()
      local root = helpers.tmpdir()
      local new_path = root .. "/new.json"
      local existing_path = root .. "/existing.json"
      write(existing_path, '{"key":"original"}')
      local chmod_ok, chmod_err = vim.uv.fs_chmod(existing_path, 420) -- 0644
      assert.is_truthy(chmod_ok, chmod_err)

      with_umask(63, function() -- 0077
        local new_data, new_style = resources.read_json_table(new_path)
        new_data.key = "created"
        local new_ok, new_err = resources.write_json_table(new_path, new_data, new_style, { base_dir = root })
        assert.is_true(new_ok, new_err)

        local existing_data, existing_style = resources.read_json_table(existing_path)
        existing_data.key = "updated"
        local existing_ok, existing_err =
          resources.write_json_table(existing_path, existing_data, existing_style, { base_dir = root })
        assert.is_true(existing_ok, existing_err)
      end)

      local bit = require("bit")
      assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(new_path)).mode, 511)) -- 0600
      assert.are.equal(420, bit.band(assert(vim.uv.fs_stat(existing_path)).mode, 511)) -- 0644
    end)

    it("synchronizes an unmodified loaded resource buffer after commit", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}\n')
      local bufnr = vim.fn.bufadd(path)
      vim.bo[bufnr].swapfile = false
      vim.fn.bufload(bufnr)
      vim.bo[bufnr].modified = false
      local data, style = resources.read_json_table(path)
      data.key = "updated"

      local ok, err = resources.write_json_table(path, data, style, { base_dir = root })

      assert.is_true(ok, err)
      assert.are.same({ "{", '  "key": "updated"', "}" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_false(vim.bo[bufnr].modified)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("restores a single external update raced before commit exchange", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)

      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if not injecting and not injected and stat and stat.type == "file" and stat.ino == plan.atomic.intended.ino then
          injecting = true
          injected = true
          write(path, '{"key":"external-b"}')
          injecting = false
        end
        return closed, close_err
      end

      local committed, commit_err = resources.commit_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(committed)
      assert.is_true(injected)
      assert.is_truthy(commit_err and commit_err:find("changed", 1, true))
      assert.are.equal('{"key":"external-b"}', helpers.read_file(path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_true(discarded, discard_err)
    end)

    it("leaves a single external update raced after commit exchange in place", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)

      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      local expected_closes = 0
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if not injecting and stat and stat.type == "file" and stat.ino == plan.atomic.expected.ino then
          expected_closes = expected_closes + 1
          if not injected and expected_closes == 2 then
            injecting = true
            injected = true
            write(path, '{"key":"external-c"}')
            injecting = false
          end
        end
        return closed, close_err
      end

      local committed, commit_err = resources.commit_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(committed)
      assert.is_true(injected)
      assert.is_truthy(commit_err and commit_err:find("left unchanged", 1, true), commit_err)
      assert.are.equal('{"key":"external-c"}', helpers.read_file(path))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path, vim.inspect({ error = commit_err, artifacts = plan.atomic.artifacts }))
      assert.are.equal('{"key":"original"}', helpers.read_file(recovery_path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      uv.fs_unlink(recovery_path)
    end)

    it("restores a single external update raced before rollback exchange", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      write(path, '{"key":"external-b"}')

      local rolled_back, rollback_err = resources.rollback_json_write(plan)

      assert.is_false(rolled_back)
      assert.is_truthy(rollback_err and rollback_err:find("changed", 1, true))
      assert.are.equal('{"key":"external-b"}', helpers.read_file(path))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path)
      assert.are.equal('{"key":"original"}', helpers.read_file(recovery_path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      vim.uv.fs_unlink(recovery_path)
    end)

    it("preserves the original when the resource parent changes before rollback", function()
      local root = helpers.tmpdir()
      local parent = root .. "/locales"
      local moved_parent = root .. "/relocated-locales"
      local path = parent .. "/resource.json"
      vim.fn.mkdir(parent, "p")
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      local recovery_name = plan.atomic.stage_name
      assert.is_not_nil(recovery_name)
      local renamed, rename_err = vim.uv.fs_rename(parent, moved_parent)
      assert.is_truthy(renamed, rename_err)
      local created, create_err = vim.uv.fs_mkdir(parent, 448)
      assert.is_truthy(created, create_err)

      local rolled_back, rollback_err = resources.rollback_json_write(plan)

      assert.is_false(rolled_back)
      assert.is_truthy(rollback_err and rollback_err:find("resource parent changed", 1, true))
      assert.are.equal("protect", plan.atomic.artifacts[recovery_name])
      local recovery_path = moved_parent .. "/" .. recovery_name
      assert.are.equal('{"key":"original"}', helpers.read_file(recovery_path))
      assert.are.equal("plugin", vim.json.decode(helpers.read_file(moved_parent .. "/resource.json")).key)
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      assert.are.equal('{"key":"original"}', helpers.read_file(recovery_path))
      vim.uv.fs_unlink(recovery_path)
    end)

    it("leaves a single external update raced after rollback exchange in place", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)

      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if
          not injecting
          and not injected
          and stat
          and stat.type == "file"
          and stat.ino == plan.atomic.committed.ino
        then
          injecting = true
          injected = true
          write(path, '{"key":"external-c"}')
          injecting = false
        end
        return closed, close_err
      end

      local rolled_back, rollback_err = resources.rollback_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(rolled_back)
      assert.is_true(injected)
      assert.is_truthy(rollback_err and rollback_err:find("left unchanged", 1, true))
      assert.are.equal('{"key":"external-c"}', helpers.read_file(path))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path)
      assert.are.equal("plugin", vim.json.decode(helpers.read_file(recovery_path)).key)
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      uv.fs_unlink(recovery_path)
    end)

    it("preserves both external versions when writers race across commit exchange", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)

      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local phase = 0
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if not injecting and stat and stat.type == "file" then
          if phase == 0 and stat.ino == plan.atomic.intended.ino then
            phase = 1
            injecting = true
            write(path, '{"key":"external-b"}')
            injecting = false
          elseif phase == 1 and stat.ino == plan.atomic.expected.ino then
            phase = 2
            injecting = true
            write(path, '{"key":"external-c"}')
            injecting = false
          end
        end
        return closed, close_err
      end

      local committed, commit_err = resources.commit_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(committed)
      assert.are.equal(2, phase)
      assert.is_truthy(commit_err and commit_err:find("changed", 1, true))
      assert.are.equal('{"key":"external-c"}', helpers.read_file(path))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path)
      assert.are.equal('{"key":"external-b"}', helpers.read_file(recovery_path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      vim.uv.fs_unlink(recovery_path)
    end)

    it("preserves both external versions when writers race across rollback exchange", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      write(path, '{"key":"external-b"}')

      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if
          not injecting
          and not injected
          and stat
          and stat.type == "file"
          and stat.ino == plan.atomic.committed.ino
        then
          injected = true
          injecting = true
          write(path, '{"key":"external-c"}')
          injecting = false
        end
        return closed, close_err
      end

      local rolled_back, rollback_err = resources.rollback_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(rolled_back)
      assert.is_true(injected)
      assert.is_truthy(rollback_err and rollback_err:find("changed", 1, true))
      assert.are.equal('{"key":"external-c"}', helpers.read_file(path))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path)
      assert.are.equal('{"key":"external-b"}', helpers.read_file(recovery_path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      vim.uv.fs_unlink(recovery_path)
    end)

    it("refuses a replaced non-regular staging entry without touching the target", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local stage_path = plan.atomic.stage
      local saved_path = stage_path .. ".saved"
      local renamed, rename_err = vim.uv.fs_rename(stage_path, saved_path)
      assert.is_truthy(renamed, rename_err)
      local linked, link_err = vim.uv.fs_symlink(saved_path, stage_path)
      assert.is_truthy(linked, link_err)

      local committed, commit_err = resources.commit_json_write(plan)

      assert.is_false(committed)
      assert.is_truthy(commit_err and commit_err:find("recovery", 1, true))
      assert.are.equal('{"key":"original"}', helpers.read_file(path))
      assert.are.equal("link", assert(vim.uv.fs_lstat(stage_path)).type)
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      vim.uv.fs_unlink(stage_path)
      vim.uv.fs_unlink(saved_path)
    end)

    it("rejects a FIFO staging replacement without blocking", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local stage_path = plan.atomic.stage
      local saved_path = stage_path .. ".saved"
      local renamed, rename_err = vim.uv.fs_rename(stage_path, saved_path)
      assert.is_truthy(renamed, rename_err)
      make_fifo(stage_path)
      local started = vim.uv.hrtime()

      local committed, commit_err = resources.commit_json_write(plan)

      assert.is_false(committed)
      assert.is_truthy(commit_err and commit_err:find("regular file", 1, true))
      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 1000)
      assert.are.equal('{"key":"original"}', helpers.read_file(path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      vim.uv.fs_unlink(stage_path)
      vim.uv.fs_unlink(saved_path)
    end)

    it("leaves an unclassified exchanged target in place", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local stage_path = plan.atomic.stage
      local saved_path = stage_path .. ".saved"
      local uv = vim.uv
      local original_close = uv.fs_close
      local injecting = false
      local injected = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if not injecting and not injected and stat and stat.type == "file" and stat.ino == plan.atomic.intended.ino then
          injecting = true
          injected = true
          local renamed, rename_err = uv.fs_rename(stage_path, saved_path)
          assert.is_truthy(renamed, rename_err)
          write(stage_path, '{"key":"untrusted-stage"}')
          injecting = false
        end
        return closed, close_err
      end

      local committed, commit_err = resources.commit_json_write(plan)
      uv.fs_close = original_close

      assert.is_false(committed)
      assert.is_true(injected)
      assert.are.equal('{"key":"untrusted-stage"}', helpers.read_file(path))
      assert.is_truthy(commit_err and commit_err:find("left unchanged", 1, true))
      local recovery_path = plan.atomic.stage
      assert.is_not_nil(recovery_path)
      assert.are.equal('{"key":"original"}', helpers.read_file(recovery_path))
      local discarded, discard_err = resources.discard_json_write(plan)
      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("protected recovery", 1, true))
      uv.fs_unlink(recovery_path)
      uv.fs_unlink(saved_path)
    end)

    it("unlinks a verified artifact before closing its descriptor", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)

      local uv = vim.uv
      local original_close = uv.fs_close
      local checked = false
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_close(fd)
        if stat and stat.type == "file" and stat.ino == plan.atomic.expected.ino then
          checked = true
          assert.is_nil(find_recovery_with_content(root, '{"key":"original"}'))
        end
        return closed, close_err
      end

      local call_ok, discarded, discard_err = pcall(resources.discard_json_write, plan)
      uv.fs_close = original_close

      assert.is_true(call_ok, discarded)
      assert.is_true(discarded, discard_err)
      assert.is_true(checked)
      assert.are.equal("plugin", vim.json.decode(helpers.read_file(path)).key)
    end)

    it("does not unlink a replacement at the public artifact path", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      local stage_path = plan.atomic.stage

      local uv = vim.uv
      local original_fstat = uv.fs_fstat
      local injecting = false
      local injected = false
      uv.fs_fstat = function(fd)
        local stat, stat_err = original_fstat(fd)
        if not injecting and not injected and stat and stat.type == "file" and stat.ino == plan.atomic.expected.ino then
          injecting = true
          injected = true
          write(stage_path, '{"key":"external"}')
          injecting = false
        end
        return stat, stat_err
      end

      local call_ok, discarded, discard_err = pcall(resources.discard_json_write, plan)
      uv.fs_fstat = original_fstat

      assert.is_true(call_ok, discarded)
      assert.is_true(discarded, discard_err)
      assert.is_true(injected)
      assert.are.equal('{"key":"external"}', helpers.read_file(stage_path))
      assert.are.same({}, vim.fn.glob(root .. "/.i18n-status-cleanup-*", false, true))
      uv.fs_unlink(stage_path)
    end)

    it("protects a recovery artifact changed after a successful commit", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      write(plan.atomic.stage, '{"key":"external-late"}')

      local discarded, discard_err = resources.discard_json_write(plan)

      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("artifact changed", 1, true))
      assert.are.equal("plugin", vim.json.decode(helpers.read_file(path)).key)
      local recovery_path = discard_err:match("protected recovery files: ([^;,]+)")
      assert.is_not_nil(recovery_path)
      assert.are.equal('{"key":"external-late"}', helpers.read_file(recovery_path))
      vim.uv.fs_unlink(recovery_path)
    end)

    it("reports a directory fsync failure during cleanup", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"original"}')
      local data, style = resources.read_json_table(path)
      data.key = "plugin"
      local plan, prepare_err = resources.prepare_json_write(path, data, style, { base_dir = root })
      assert.is_not_nil(plan, prepare_err)
      local committed, commit_err = resources.commit_json_write(plan)
      assert.is_true(committed, commit_err)
      local original_fsync = vim.uv.fs_fsync
      vim.uv.fs_fsync = function()
        return nil, "simulated directory sync failure"
      end

      local discarded, discard_err = resources.discard_json_write(plan)
      vim.uv.fs_fsync = original_fsync

      assert.is_false(discarded)
      assert.is_truthy(discard_err and discard_err:find("sync resource directory", 1, true))
      assert.are.equal("plugin", vim.json.decode(helpers.read_file(path)).key)
    end)

    it("reads a resource completely when the filesystem returns short chunks", function()
      local root = helpers.tmpdir()
      local path = root .. "/resource.json"
      write(path, '{"key":"complete-value"}')
      local original_read = vim.uv.fs_read
      vim.uv.fs_read = function(fd, size, offset)
        return original_read(fd, math.max(1, math.floor(size / 2)), offset)
      end

      local data, style = resources.read_json_table(path)
      vim.uv.fs_read = original_read

      assert.is_nil(style.error)
      assert.are.equal("complete-value", data.key)
    end)

    it("restores exact bytes when a later language commit fails", function()
      local root = helpers.tmpdir()
      local ja_path = root .. "/locales/ja/common.json"
      local en_path = root .. "/locales/en/common.json"
      local original_ja = '{\n\t"existing": "JA"\n}\n'
      local original_en = '{"existing":"EN"}'
      write(ja_path, original_ja)
      write(en_path, original_en)
      resources.ensure_index(root)

      local original_commit = resources.commit_json_write
      local commit_count = 0
      resources.commit_json_write = function(plan)
        commit_count = commit_count + 1
        if commit_count == 2 then
          return false, "simulated second commit failure"
        end
        return original_commit(plan)
      end

      local success_count, failed_langs = key_write.write_translations(
        "common",
        "new.key",
        { ja = "追加", en = "added" },
        root,
        { "ja", "en" }
      )
      resources.commit_json_write = original_commit

      assert.are.equal(0, success_count)
      assert.are.same({ "ja", "en" }, failed_langs)
      assert.are.equal(original_ja, helpers.read_file(ja_path))
      assert.are.equal(original_en, helpers.read_file(en_path))
    end)
  end)

  describe("write_json_table", function()
    local uv
    local original_notify
    local original_fs_write
    local original_fs_fsync
    local original_fs_close
    local base_dir
    local target_path
    local target_style

    before_each(function()
      uv = vim.uv
      original_notify = vim.notify
      original_fs_write = uv.fs_write
      original_fs_fsync = uv.fs_fsync
      original_fs_close = uv.fs_close
      base_dir = helpers.tmpdir()
      target_path = base_dir .. "/out.json"
      target_style = select(2, resources.read_json_table(target_path))
    end)

    after_each(function()
      vim.notify = original_notify
      uv.fs_write = original_fs_write
      uv.fs_fsync = original_fs_fsync
      uv.fs_close = original_fs_close
      vim.fn.delete(base_dir, "rf")
    end)

    it("rolls back when fs_write fails", function()
      local notifications = {}
      local close_called = false

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.fs_write = function()
        return nil, "disk full"
      end
      uv.fs_close = function(fd)
        close_called = true
        return original_fs_close(fd)
      end

      resources.write_json_table(target_path, { a = "b" }, target_style, { base_dir = base_dir })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_true(close_called)
      assert.is_nil(vim.uv.fs_lstat(target_path))
      assert.is_truthy(notifications[1] and notifications[1]:match("fs_write"))
    end)

    it("unlinks failed staging data before closing its validation descriptor", function()
      local notifications = {}
      local stage_ino = nil
      local stage_closes = 0
      local checked = false
      uv.fs_write = function(fd)
        stage_ino = assert(uv.fs_fstat(fd)).ino
        return nil, "disk full"
      end
      uv.fs_close = function(fd)
        local stat = uv.fs_fstat(fd)
        local closed, close_err = original_fs_close(fd)
        if stat and stat.type == "file" and stat.ino == stage_ino then
          stage_closes = stage_closes + 1
          if stage_closes == 2 then
            checked = true
            assert.is_nil(find_recovery_with_content(base_dir, ""))
          end
        end
        return closed, close_err
      end
      vim.notify = function(message)
        notifications[#notifications + 1] = message
      end

      local call_ok, write_ok = pcall(
        resources.write_json_table,
        target_path,
        { a = "b" },
        target_style,
        { base_dir = base_dir }
      )
      uv.fs_close = original_fs_close
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_true(call_ok, write_ok)
      assert.is_false(write_ok)
      assert.are.equal(2, stage_closes)
      assert.is_true(checked)
      assert.is_nil(vim.uv.fs_lstat(target_path))
    end)

    it("does not unlink a staging-path replacement during failed-write cleanup", function()
      local notifications = {}
      local stage_path = nil
      local injected = false
      uv.fs_write = function()
        stage_path = vim.fn.glob(base_dir .. "/.i18n-status-stage-*", false, true)[1]
        return nil, "disk full"
      end
      uv.fs_fsync = function(fd)
        if stage_path and not injected and not vim.uv.fs_lstat(stage_path) then
          injected = true
          uv.fs_write = original_fs_write
          write(stage_path, '{"key":"external"}')
        end
        return original_fs_fsync(fd)
      end
      vim.notify = function(message)
        notifications[#notifications + 1] = message
      end

      local write_ok = resources.write_json_table(target_path, { a = "b" }, target_style, { base_dir = base_dir })
      uv.fs_write = original_fs_write
      uv.fs_fsync = original_fs_fsync
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_false(write_ok)
      assert.is_true(injected)
      assert.are.equal('{"key":"external"}', helpers.read_file(stage_path))
      assert.are.same({}, vim.fn.glob(base_dir .. "/.i18n-status-cleanup-*", false, true))
      uv.fs_unlink(stage_path)
    end)

    it("rolls back when fs_fsync fails", function()
      local notifications = {}
      local close_called = false

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.fs_fsync = function()
        return nil, "fsync failed"
      end
      uv.fs_close = function(fd)
        close_called = true
        return original_fs_close(fd)
      end

      resources.write_json_table(target_path, { a = "b" }, target_style, { base_dir = base_dir })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_true(close_called)
      assert.is_nil(vim.uv.fs_lstat(target_path))
      assert.is_truthy(notifications[1] and notifications[1]:match("fs_fsync"), vim.inspect(notifications))
    end)

    it("rolls back when fs_close fails", function()
      local notifications = {}
      local stage_fd = nil

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.fs_write = function(fd, content, offset)
        stage_fd = fd
        return original_fs_write(fd, content, offset)
      end
      uv.fs_close = function(fd)
        local closed, close_err = original_fs_close(fd)
        if fd == stage_fd then
          stage_fd = nil
          return nil, "close failed"
        end
        return closed, close_err
      end

      resources.write_json_table(target_path, { a = "b" }, target_style, { base_dir = base_dir })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_nil(vim.uv.fs_lstat(target_path))
      assert.is_truthy(notifications[1] and notifications[1]:match("fs_close"))
    end)
  end)

  it("reuses cached watch paths for repeated watcher setup", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"hello":"ja"}')
    write(root .. "/locales/en/common.json", '{"hello":"en"}')

    local uv = vim.uv
    local original_scandir = uv.fs_scandir
    local scandir_calls = 0
    uv.fs_scandir = function(...)
      scandir_calls = scandir_calls + 1
      return original_scandir(...)
    end

    resources.start_watch(root, function() end, { debounce_ms = 10 })
    local first_calls = scandir_calls
    resources.start_watch(root, function() end, { debounce_ms = 10 })
    local second_calls = scandir_calls - first_calls

    resources.stop_watch()
    uv.fs_scandir = original_scandir

    assert.is_true(first_calls > 0)
    assert.are.equal(0, second_calls)
  end)

  it("does not resolve roots again when start_watch gets precomputed target", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"hello":"ja"}')
    write(root .. "/locales/en/common.json", '{"hello":"en"}')

    local resolve_roots_calls = 0
    local original_request_sync = rpc.request_sync
    rpc.request_sync = function(method, params, timeout_ms)
      if method == "resource/resolveRoots" then
        resolve_roots_calls = resolve_roots_calls + 1
      end
      return original_request_sync(method, params, timeout_ms)
    end

    local ok, err = pcall(function()
      local watcher_key, roots = resources.resolve_watch_target(root)
      local calls_after_resolve = resolve_roots_calls
      resources.start_watch(root, function() end, {
        debounce_ms = 10,
        cache_key = watcher_key,
        roots = roots,
      })
      resources.stop_watch(watcher_key)
      assert.is_true(calls_after_resolve > 0)
      assert.are.equal(calls_after_resolve, resolve_roots_calls)
    end)

    rpc.request_sync = original_request_sync
    if not ok then
      error(err)
    end
  end)

  it("marks only caches under the exact root boundary", function()
    local root = helpers.tmpdir()
    local original_caches = resources.caches

    resources.caches = {
      one = {
        dirty = false,
        checked_at = 1,
        roots = { { path = root .. "/locale", kind = "i18next" } },
      },
      two = {
        dirty = false,
        checked_at = 1,
        roots = { { path = root .. "/locales", kind = "i18next" } },
      },
    }

    resources.mark_dirty(root .. "/locales/ja/common.json")

    assert.is_false(resources.caches.one.dirty)
    assert.is_true(resources.caches.two.dirty)
    assert.are.equal(0, resources.caches.two.checked_at)

    resources.caches = original_caches
  end)

  describe("incremental scan", function()
    local uv = vim.uv

    it("builds cache with entries_by_key and file_entries", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)

      -- Check that new data structures are populated
      assert.is_not_nil(cache.entries_by_key)
      assert.is_not_nil(cache.file_entries)
      assert.is_not_nil(cache.file_meta)

      -- Check entries_by_key has the expected structure
      assert.is_not_nil(cache.entries_by_key.ja)
      assert.is_not_nil(cache.entries_by_key.ja["common:login.title"])
      assert.are.equal(1, #cache.entries_by_key.ja["common:login.title"])

      -- Check file_entries has entries for the json file (use normalized path for lookup)
      local ja_file = uv.fs_realpath(root .. "/locales/ja/common.json")
      assert.is_not_nil(cache.file_entries[ja_file])
      assert.is_true(#cache.file_entries[ja_file] > 0)
    end)

    it("apply_changes updates single file correctly", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)

      -- Update the file
      vim.uv.sleep(10)
      write(root .. "/locales/ja/common.json", '{"login":{"title":"サインイン"}}')

      -- Apply incremental change
      local ja_file = root .. "/locales/ja/common.json"
      local success, needs_rebuild = resources.apply_changes(cache_key, { ja_file })

      assert.is_true(success)
      assert.is_falsy(needs_rebuild)
      assert.are.equal("サインイン", cache.index.ja["common:login.title"].value)
    end)

    it("apply_changes handles file deletion", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/ja/extra.json", '{"extra":"追加"}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      assert.are.equal("追加", cache.index.ja["extra:extra"].value)

      -- Normalize path before deletion (realpath won't work after file is gone on some systems)
      local extra_file = uv.fs_realpath(root .. "/locales/ja/extra.json")
      os.remove(extra_file)

      -- Apply incremental change
      local success, _ = resources.apply_changes(cache_key, { extra_file })

      assert.is_true(success)
      assert.is_nil(cache.index.ja["extra:extra"])
    end)

    it("apply_changes handles new file addition", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      assert.is_nil(cache.index.ja["new:key"])

      -- Add new file
      local new_file = root .. "/locales/ja/new.json"
      write(new_file, '{"key":"新しいキー"}')

      -- Apply incremental change
      local success, _ = resources.apply_changes(cache_key, { new_file })

      assert.is_true(success)
      assert.are.equal("新しいキー", cache.index.ja["new:key"].value)
    end)

    it("apply_changes preserves old entries on parse error", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)

      -- Normalize path before modifying
      local ja_file = uv.fs_realpath(root .. "/locales/ja/common.json")

      -- Write invalid JSON
      write(ja_file, "{invalid json")

      -- Apply incremental change
      local success, _ = resources.apply_changes(cache_key, { ja_file })

      -- Should succeed (old entries preserved) but record error
      assert.is_true(success)
      assert.are.equal("ログイン", cache.index.ja["common:login.title"].value)

      -- Should record error
      assert.is_not_nil(cache.file_errors)
      assert.is_not_nil(cache.file_errors[ja_file])
    end)

    it("apply_changes clears error on recovery", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      -- Normalize path while file exists
      local ja_file = uv.fs_realpath(root .. "/locales/ja/common.json")

      -- Write invalid JSON to create error state
      write(ja_file, "{invalid json")
      resources.apply_changes(cache_key, { ja_file })
      assert.is_not_nil(cache.file_errors[ja_file])

      -- Fix the JSON
      write(ja_file, '{"login":{"title":"修正済み"}}')
      local success, _ = resources.apply_changes(cache_key, { ja_file })

      assert.is_true(success)
      assert.is_nil(cache.file_errors[ja_file])
      assert.are.equal("修正済み", cache.index.ja["common:login.title"].value)
    end)

    it("apply_changes maintains priority invariants with next-intl", function()
      local root = helpers.tmpdir()
      write(root .. "/messages/en/common.json", '{"title":"Namespace"}')
      write(root .. "/messages/en.json", '{"common":{"title":"Root"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Root file (priority 40) should beat namespace file (priority 50)
      assert.are.equal("Root", cache.index.en["common:title"].value)

      -- Normalize paths while files exist
      local ns_file = uv.fs_realpath(root .. "/messages/en/common.json")
      local root_file = uv.fs_realpath(root .. "/messages/en.json")

      -- Update namespace file
      write(ns_file, '{"title":"Updated Namespace"}')
      resources.apply_changes(cache_key, { ns_file })

      -- Root should still win
      assert.are.equal("Root", cache.index.en["common:title"].value)

      -- Delete root file
      os.remove(root_file)
      resources.apply_changes(cache_key, { root_file })

      -- Now namespace should be used
      assert.are.equal("Updated Namespace", cache.index.en["common:title"].value)
    end)

    it("apply_changes sets needs_rebuild for directory events", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Apply change to directory path
      local _, needs_rebuild = resources.apply_changes(cache_key, { root .. "/locales" })

      -- Should indicate rebuild needed for directory
      assert.is_true(needs_rebuild)
    end)

    it("apply_changes does not set dirty on successful incremental update", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key
      cache.dirty = false -- Ensure clean state

      -- Normalize path
      local ja_file = uv.fs_realpath(root .. "/locales/ja/common.json")

      -- Update file
      vim.uv.sleep(10)
      write(ja_file, '{"login":{"title":"サインイン"}}')

      -- Apply incremental change
      local success, needs_rebuild = resources.apply_changes(cache_key, { ja_file })

      -- Dirty should NOT be set after successful incremental update
      assert.is_true(success)
      assert.is_falsy(needs_rebuild)
      assert.is_false(cache.dirty)
    end)

    it("apply_changes removes language when last file of that language is deleted", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Verify both languages exist
      assert.is_true(vim.tbl_contains(cache.languages, "ja"))
      assert.is_true(vim.tbl_contains(cache.languages, "en"))

      -- Normalize path before deletion
      local ja_file = uv.fs_realpath(root .. "/locales/ja/common.json")

      -- Delete the only Japanese file
      os.remove(ja_file)

      -- Apply incremental change
      resources.apply_changes(cache_key, { ja_file })

      -- Japanese should be removed from languages
      assert.is_false(vim.tbl_contains(cache.languages, "ja"))
      assert.is_true(vim.tbl_contains(cache.languages, "en"))
    end)

    it("apply_changes sets needs_rebuild for paths outside roots", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Create a file outside the root
      local outside_file = root .. "/outside.json"
      write(outside_file, '{"key":"value"}')

      -- Apply change to path outside roots
      local success, needs_rebuild = resources.apply_changes(cache_key, { outside_file })

      -- Should indicate rebuild needed for path outside roots
      assert.is_false(success)
      assert.is_true(needs_rebuild)
    end)

    it("apply_changes handles new broken JSON file gracefully", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      -- Add new file with broken JSON
      local new_file = root .. "/locales/ja/broken.json"
      write(new_file, "{broken json")
      local new_file_normalized = uv.fs_realpath(new_file)

      -- Apply incremental change
      local success, _ = resources.apply_changes(cache_key, { new_file_normalized })

      -- Should succeed (no old entries to preserve, just records error)
      assert.is_true(success)

      -- Should record error
      assert.is_not_nil(cache.file_errors)
      assert.is_not_nil(cache.file_errors[new_file_normalized])

      -- Should also be in cache.errors for doctor display
      local found_error = false
      for _, err in ipairs(cache.errors or {}) do
        if err.file == new_file_normalized then
          found_error = true
          break
        end
      end
      assert.is_true(found_error)
    end)

    it("apply_changes keeps cache valid while watching after new file", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      resources.start_watch(root, function() end, { debounce_ms = 10 })

      -- Add new file and apply incremental update
      local new_file = root .. "/locales/ja/extra.json"
      write(new_file, '{"extra":"追加"}')
      local success, needs_rebuild = resources.apply_changes(cache_key, { new_file })

      assert.is_true(success)
      assert.is_falsy(needs_rebuild)

      -- Wait beyond CACHE_VALIDATE_INTERVAL_MS to trigger structural validation
      vim.wait(1100, function()
        return false
      end, 10)

      local cache2 = resources.ensure_index(root)
      assert.is_true(cache == cache2)

      resources.stop_watch()
    end)

    it("apply_changes treats non-json changes under root as rebuild-needed", function()
      local root = helpers.tmpdir()
      write(root .. "/locales/ja/common.json", '{"login":{"title":"ログイン"}}')
      write(root .. "/locales/en/common.json", '{"login":{"title":"Login"}}')

      local cache = resources.ensure_index(root)
      local cache_key = cache.key

      local non_json = root .. "/locales/ja/README.txt"
      write(non_json, "note")

      local success, needs_rebuild = resources.apply_changes(cache_key, { non_json })

      assert.is_false(success)
      assert.is_true(needs_rebuild)
    end)
  end)
end)
