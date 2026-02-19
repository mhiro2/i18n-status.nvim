---@class I18nStatusWatcher
---@field watchers table<string, I18nStatusWatchState> Active watcher instances keyed by cache key
---@field refcounts table<string, integer> Reference counts per watcher key
local M = {
  watchers = {},
  refcounts = {},
}

local util = require("i18n-status.util")

local uv = vim.uv

local WATCHER_ERROR_THROTTLE_MS = 60000
---@type table<string, integer>
local error_timestamps = {}

---@class I18nStatusWatchState
---@field key string
---@field signature string|nil
---@field handles userdata[]
---@field timer uv_timer_t|nil
---@field on_change fun(event: table)
---@field debounce_ms integer
---@field needs_rescan boolean
---@field rescan_paths table<string, boolean>
---@field pending_paths table<string, boolean>
---@field pending_needs_rebuild boolean
---@field restart_fn fun()|nil

---@class I18nStatusWatcherStartOpts
---@field paths string[] Paths to watch
---@field rescan_paths table<string, boolean> Paths that trigger a rescan when changed
---@field on_change fun(event: table) Callback on change
---@field debounce_ms integer Debounce interval in milliseconds
---@field restart_fn fun() Function to call when watcher needs restart (re-resolve paths)
---@field skip_refcount boolean|nil Skip reference counting (used for restarts)

---@param handle userdata|nil
local function safe_close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end)
end

---@param path string
---@param err string
local function log_watcher_error(path, err)
  local now = uv.now()
  local last_logged = error_timestamps[path] or 0
  if (now - last_logged) < WATCHER_ERROR_THROTTLE_MS then
    return
  end
  error_timestamps[path] = now
  vim.schedule(function()
    vim.notify(string.format("i18n-status: file watcher error for %s: %s", path, err), vim.log.levels.WARN)
  end)
end

---@param watch I18nStatusWatchState|nil
local function stop_single_watch(watch)
  if not watch then
    return
  end
  safe_close_handle(watch.timer)
  watch.timer = nil
  for _, handle in ipairs(watch.handles or {}) do
    safe_close_handle(handle)
  end
  watch.handles = {}
  watch.signature = nil
  watch.needs_rescan = false
end

---@param key string
local function inc_refcount(key)
  M.refcounts[key] = (M.refcounts[key] or 0) + 1
end

---@param key string|nil
---@param opts { keep_refcount: boolean }|nil
local function stop_internal(key, opts)
  local keep_refcount = opts and opts.keep_refcount
  if key then
    local watch = M.watchers[key]
    if watch then
      stop_single_watch(watch)
      M.watchers[key] = nil
    end
    if not keep_refcount then
      M.refcounts[key] = nil
    end
    return
  end
  for k, watch in pairs(M.watchers) do
    stop_single_watch(watch)
    M.watchers[k] = nil
    if not keep_refcount then
      M.refcounts[k] = nil
    end
  end
  if not keep_refcount then
    M.refcounts = {}
  end
end

---Start watching paths with debounced change notifications.
---@param key string Unique identifier for this watcher
---@param opts I18nStatusWatcherStartOpts
function M.start(key, opts)
  local paths = opts.paths
  local on_change = opts.on_change
  local debounce = opts.debounce_ms or 200

  if not opts.skip_refcount then
    inc_refcount(key)
  end

  if #paths == 0 then
    return
  end

  local signature = table.concat(paths, "|")

  -- Reuse existing watcher if paths haven't changed
  if M.watchers[key] and M.watchers[key].signature == signature then
    local existing = M.watchers[key]
    existing.on_change = on_change
    existing.debounce_ms = debounce
    existing.restart_fn = opts.restart_fn
    return
  end

  stop_internal(key, { keep_refcount = true })

  ---@type I18nStatusWatchState
  local watch = {
    key = key,
    signature = signature,
    handles = {},
    timer = nil,
    on_change = on_change,
    debounce_ms = debounce,
    needs_rescan = false,
    rescan_paths = opts.rescan_paths or {},
    pending_paths = {},
    pending_needs_rebuild = false,
    restart_fn = opts.restart_fn,
  }
  M.watchers[key] = watch

  local function schedule_change(rescan, changed_path)
    if rescan then
      watch.needs_rescan = true
      watch.pending_needs_rebuild = true
    end
    -- Collect changed path
    if changed_path then
      watch.pending_paths[changed_path] = true
    end
    safe_close_handle(watch.timer)
    watch.timer = uv.new_timer()
    pcall(function()
      watch.timer:unref()
    end)
    watch.timer:start(
      watch.debounce_ms,
      0,
      vim.schedule_wrap(function()
        watch.timer = nil
        -- Collect pending paths into a list
        local collected_paths = {}
        for p, _ in pairs(watch.pending_paths) do
          table.insert(collected_paths, p)
        end
        local needs_rebuild = watch.pending_needs_rebuild
        -- Clear pending state
        watch.pending_paths = {}
        watch.pending_needs_rebuild = false

        local cb = watch.on_change
        if cb then
          cb({ paths = collected_paths, needs_rebuild = needs_rebuild })
        end
        if watch.needs_rescan and watch.restart_fn then
          watch.needs_rescan = false
          watch.restart_fn()
        end
      end)
    )
  end

  for _, path in ipairs(paths) do
    if util.file_exists(path) then
      local handle = uv.new_fs_event()
      if handle then
        local start_ok, start_err = pcall(function()
          handle:start(path, {}, function(err, filename, _events)
            if err then
              log_watcher_error(path, err)
              -- Schedule recovery: stop current watcher and restart after delay
              vim.defer_fn(function()
                if watch and watch.restart_fn then
                  watch.restart_fn()
                end
              end, 5000)
              return
            end
            -- Determine the actual changed file path
            local changed_path_resolved = path
            if filename and filename ~= "" then
              local stat = uv.fs_stat(path)
              if stat and stat.type == "directory" then
                changed_path_resolved = util.path_join(path, filename)
              end
            end
            schedule_change(watch.rescan_paths[path] == true, changed_path_resolved)
          end)
        end)

        if not start_ok then
          safe_close_handle(handle)
          log_watcher_error(path, start_err or "unknown error starting watcher")
        else
          pcall(function()
            handle:unref()
          end)
          table.insert(watch.handles, handle)
        end
      end
    end
  end
end

---Stop watcher unconditionally.
---@param key string|nil If nil, stops all watchers
function M.stop(key)
  stop_internal(key, nil)
end

---Stop watcher with reference counting for buffer cleanup.
---@param key string|nil Watcher key
---@return boolean stopped True if watcher was actually stopped
function M.stop_for_buffer(key)
  if not key then
    return false
  end

  local refcount = M.refcounts[key] or 0
  if refcount <= 0 then
    return false
  end

  M.refcounts[key] = refcount - 1

  -- Stop watcher when reference count reaches 0
  if M.refcounts[key] == 0 then
    local watch = M.watchers[key]
    if watch then
      stop_single_watch(watch)
      M.watchers[key] = nil
    end
    M.refcounts[key] = nil
    return true
  end

  return false
end

---Check if key is actively being watched.
---@param key string
---@return boolean
function M.is_watching(key)
  local watch = M.watchers[key]
  return watch ~= nil and watch.signature ~= nil and watch.handles ~= nil and #watch.handles > 0
end

---Get the structural signature for a watcher.
---@param key string
---@return string|nil
function M.signature(key)
  local watch = M.watchers[key]
  if watch then
    return watch.signature
  end
  return nil
end

---Update the structural signature for a watcher.
---@param key string
---@param sig string
function M.set_signature(key, sig)
  local watch = M.watchers[key]
  if watch then
    watch.signature = sig
  end
end

---Increment reference count manually (for cases where start is skipped).
---@param key string
function M.inc_refcount(key)
  inc_refcount(key)
end

return M
