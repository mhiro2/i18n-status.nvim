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
local WATCHER_FALLBACK_POLL_MS = 3000
local WATCHER_FALLBACK_RETRY_MS = 30000
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
---@field fallback_timer uv_timer_t|nil
---@field fallback_paths string[]
---@field fallback_signatures table<string, string>
---@field fallback_next_restart_at integer|nil

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

---@param key string
---@param reason string
local function notify_watcher_fallback(key, reason)
  local now = uv.now()
  local tag = "fallback:" .. key
  local last_logged = error_timestamps[tag] or 0
  if (now - last_logged) < WATCHER_ERROR_THROTTLE_MS then
    return
  end
  error_timestamps[tag] = now
  vim.schedule(function()
    vim.notify(string.format("i18n-status: watcher fallback enabled for %s: %s", key, reason), vim.log.levels.WARN)
  end)
end

---@param watch I18nStatusWatchState
---@param reason string
local function start_polling_fallback(watch, reason)
  if watch.fallback_timer then
    return
  end
  notify_watcher_fallback(watch.key, reason)

  local function path_signature(path)
    local stat = uv.fs_stat(path)
    if not stat then
      return "missing"
    end
    local mtime_sec = (stat.mtime and stat.mtime.sec) or 0
    local mtime_nsec = (stat.mtime and stat.mtime.nsec) or 0
    local size = stat.size or 0
    local typ = stat.type or "unknown"
    return string.format("%s:%d:%d:%d", typ, mtime_sec, mtime_nsec, size)
  end

  local function collect_changed_paths()
    local changed = {}
    for _, path in ipairs(watch.fallback_paths or {}) do
      local current_sig = path_signature(path)
      local previous_sig = watch.fallback_signatures[path]
      if previous_sig == nil then
        watch.fallback_signatures[path] = current_sig
      elseif previous_sig ~= current_sig then
        watch.fallback_signatures[path] = current_sig
        table.insert(changed, path)
      end
    end
    return changed
  end

  local function maybe_restart_watcher()
    if not watch.restart_fn then
      return
    end
    local now = uv.now()
    if watch.fallback_next_restart_at and now < watch.fallback_next_restart_at then
      return
    end
    watch.fallback_next_restart_at = now + WATCHER_FALLBACK_RETRY_MS
    watch.restart_fn()
  end

  local function notify_rebuild(_paths)
    local cb = watch.on_change
    if cb then
      cb({ paths = {}, needs_rebuild = true })
    end
  end

  collect_changed_paths()
  watch.fallback_timer = uv.new_timer()
  if watch.fallback_timer then
    pcall(function()
      watch.fallback_timer:unref()
    end)
    watch.fallback_timer:start(
      WATCHER_FALLBACK_POLL_MS,
      WATCHER_FALLBACK_POLL_MS,
      vim.schedule_wrap(function()
        local changed_paths = collect_changed_paths()
        if #changed_paths == 0 then
          return
        end
        notify_rebuild(changed_paths)
        maybe_restart_watcher()
      end)
    )
  end

  vim.schedule(function()
    notify_rebuild({})
    maybe_restart_watcher()
  end)
end

---@param watch I18nStatusWatchState|nil
local function stop_single_watch(watch)
  if not watch then
    return
  end
  safe_close_handle(watch.timer)
  watch.timer = nil
  safe_close_handle(watch.fallback_timer)
  watch.fallback_timer = nil
  for _, handle in ipairs(watch.handles or {}) do
    safe_close_handle(handle)
  end
  watch.handles = {}
  watch.signature = nil
  watch.needs_rescan = false
  watch.fallback_signatures = {}
  watch.fallback_next_restart_at = nil
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
    if existing.handles and #existing.handles > 0 then
      return
    end
    stop_internal(key, { keep_refcount = true })
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
    fallback_timer = nil,
    fallback_paths = paths,
    fallback_signatures = {},
    fallback_next_restart_at = nil,
  }
  M.watchers[key] = watch
  local had_start_failure = false
  local fallback_reason = nil

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
        local needs_rebuild = watch.pending_needs_rebuild
        local collected_paths = {}
        if not needs_rebuild then
          for p, _ in pairs(watch.pending_paths) do
            table.insert(collected_paths, p)
          end
        end
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
        local start_ok, start_result = pcall(function()
          return handle:start(path, {}, function(err, filename, _events)
            if err then
              local err_msg = tostring(err)
              log_watcher_error(path, err_msg)
              start_polling_fallback(watch, err_msg)
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

        local started = start_ok and start_result ~= nil and start_result ~= false
        if not started then
          safe_close_handle(handle)
          had_start_failure = true
          local err_msg = start_ok and tostring(start_result or "unknown error starting watcher")
            or tostring(start_result)
          fallback_reason = fallback_reason or err_msg
          log_watcher_error(path, err_msg)
        else
          pcall(function()
            handle:unref()
          end)
          table.insert(watch.handles, handle)
        end
      else
        had_start_failure = true
        fallback_reason = fallback_reason or "failed to allocate fs_event handle"
        log_watcher_error(path, "failed to allocate fs_event handle")
      end
    else
      had_start_failure = true
      fallback_reason = fallback_reason or "watch path does not exist"
    end
  end

  if had_start_failure then
    start_polling_fallback(watch, fallback_reason or "watcher start failed")
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
