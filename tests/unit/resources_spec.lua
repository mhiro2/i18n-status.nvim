local resources = require("i18n-status.resources")
local rpc = require("i18n-status.rpc")
local watcher = require("i18n-status.watcher")
local helpers = require("tests.helpers")

local function write(path, content)
  helpers.write_file(path, content)
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
    vim.loop.sleep(1000)
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

  describe("write_json_table", function()
    local uv
    local original_notify
    local original_getpid
    local original_fs_open
    local original_fs_write
    local original_fs_fsync
    local original_fs_close
    local original_fs_rename
    local original_fs_unlink

    before_each(function()
      uv = vim.uv
      original_notify = vim.notify
      original_getpid = uv.getpid
      original_fs_open = uv.fs_open
      original_fs_write = uv.fs_write
      original_fs_fsync = uv.fs_fsync
      original_fs_close = uv.fs_close
      original_fs_rename = uv.fs_rename
      original_fs_unlink = uv.fs_unlink
    end)

    after_each(function()
      vim.notify = original_notify
      uv.getpid = original_getpid
      uv.fs_open = original_fs_open
      uv.fs_write = original_fs_write
      uv.fs_fsync = original_fs_fsync
      uv.fs_close = original_fs_close
      uv.fs_rename = original_fs_rename
      uv.fs_unlink = original_fs_unlink
    end)

    it("rolls back when fs_write fails", function()
      local notifications = {}
      local tmp_path = nil
      local rename_called = false
      local close_called = false
      local unlink_path = nil

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.getpid = function()
        return 42
      end
      uv.fs_open = function(path)
        tmp_path = path
        return 10
      end
      uv.fs_write = function()
        return nil, "disk full"
      end
      uv.fs_fsync = function()
        return true
      end
      uv.fs_close = function()
        close_called = true
        return true
      end
      uv.fs_rename = function()
        rename_called = true
        return true
      end
      uv.fs_unlink = function(path)
        unlink_path = path
        return true
      end

      resources.write_json_table("/tmp/out.json", { a = "b" }, { indent = "  " })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_true(close_called)
      assert.is_false(rename_called)
      assert.are.equal(tmp_path, unlink_path)
      assert.is_truthy(notifications[1] and notifications[1]:match("fs_write"))
    end)

    it("rolls back when fs_fsync fails", function()
      local notifications = {}
      local tmp_path = nil
      local rename_called = false
      local close_called = false
      local unlink_path = nil

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.getpid = function()
        return 43
      end
      uv.fs_open = function(path)
        tmp_path = path
        return 10
      end
      uv.fs_write = function(_fd, content)
        return #content
      end
      uv.fs_fsync = function()
        return nil, "fsync failed"
      end
      uv.fs_close = function()
        close_called = true
        return true
      end
      uv.fs_rename = function()
        rename_called = true
        return true
      end
      uv.fs_unlink = function(path)
        unlink_path = path
        return true
      end

      resources.write_json_table("/tmp/out.json", { a = "b" }, { indent = "  " })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_true(close_called)
      assert.is_false(rename_called)
      assert.are.equal(tmp_path, unlink_path)
      assert.is_truthy(notifications[1] and notifications[1]:match("fs_fsync"))
    end)

    it("rolls back when fs_close fails", function()
      local notifications = {}
      local tmp_path = nil
      local rename_called = false
      local unlink_path = nil

      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      uv.getpid = function()
        return 44
      end
      uv.fs_open = function(path)
        tmp_path = path
        return 10
      end
      uv.fs_write = function(_fd, content)
        return #content
      end
      uv.fs_fsync = function()
        return true
      end
      uv.fs_close = function()
        return nil, "close failed"
      end
      uv.fs_rename = function()
        rename_called = true
        return true
      end
      uv.fs_unlink = function(path)
        unlink_path = path
        return true
      end

      resources.write_json_table("/tmp/out.json", { a = "b" }, { indent = "  " })
      vim.wait(50, function()
        return #notifications > 0
      end)

      assert.is_false(rename_called)
      assert.are.equal(tmp_path, unlink_path)
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
    local uv = vim.uv or vim.loop

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
      vim.loop.sleep(10)
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
      vim.loop.sleep(10)
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
