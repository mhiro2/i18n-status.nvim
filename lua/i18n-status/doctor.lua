---@class I18nStatusDoctor
local M = {}

local filetypes = require("i18n-status.filetypes")
local fs = require("i18n-status.fs")
local rpc = require("i18n-status.rpc")
local resources = require("i18n-status.resources")
local uv = vim.uv

---@class I18nStatusDoctorIssue
---@field kind string
---@field message string
---@field severity integer
---@field bufnr integer|nil
---@field lnum integer|nil
---@field col integer|nil
---@field file string|nil
---@field key string|nil

---@alias I18nStatusDoctorKeySet table<string, boolean>
---@alias I18nStatusDoctorIgnoreFn fun(key: string): boolean

---@class I18nStatusDoctorContext
---@field bufnr integer
---@field config I18nStatusConfig
---@field cache table
---@field start_dir string
---@field fallback_ns string
---@field ignore_patterns string[]
---@field is_ignored I18nStatusDoctorIgnoreFn
---@field buffers integer[]
---@field items_by_buf table<integer, table[]>
---@field used_keys I18nStatusDoctorKeySet
---@field project_root string
---@field project_keys I18nStatusDoctorKeySet|nil
---@field cancelled boolean|nil
---@field file_total integer|nil
---@field file_processed integer|nil
---@field cancel_token_path string|nil
---@field cache_snapshot { key: string, cache: I18nStatusCache|nil, revision: integer }|nil

---@param patterns string[]|nil
---@return string[]
local function sanitize_ignore_patterns(patterns)
  local valid_patterns = {}
  for _, pattern in ipairs(patterns or {}) do
    if type(pattern) == "string" and pattern ~= "" then
      table.insert(valid_patterns, pattern)
    end
  end
  return valid_patterns
end

---@param key string
---@param pattern string
---@return boolean
local function ignore_pattern_matches(key, pattern)
  if pattern == "" then
    return false
  end
  local anchored_start = pattern:sub(1, 1) == "^"
  local anchored_end = pattern:sub(-1) == "$"
  local start_idx = anchored_start and 2 or 1
  local end_idx = anchored_end and (#pattern - 1) or #pattern
  local needle = pattern:sub(start_idx, end_idx)

  if anchored_start and anchored_end then
    return key == needle
  end
  if anchored_start then
    return key:sub(1, #needle) == needle
  end
  if anchored_end then
    if needle == "" then
      return true
    end
    return key:sub(-#needle) == needle
  end
  return key:find(needle, 1, true) ~= nil
end

---@param patterns string[]|nil
---@return I18nStatusDoctorIgnoreFn
local function make_ignore_fn(patterns)
  if not patterns or #patterns == 0 then
    return function()
      return false
    end
  end
  return function(key)
    for _, pattern in ipairs(patterns) do
      if ignore_pattern_matches(key, pattern) then
        return true
      end
    end
    return false
  end
end

---@param issues I18nStatusDoctorIssue[]
---@return string
local function summarize(issues)
  if #issues == 0 then
    return "ok"
  end
  local counts = {
    missing = 0,
    mismatch = 0,
    unused = 0,
    drift = 0,
    resource = 0,
    root = 0,
  }
  for _, issue in ipairs(issues) do
    if issue.kind == "missing" then
      counts.missing = counts.missing + 1
    elseif issue.kind == "mismatch" then
      counts.mismatch = counts.mismatch + 1
    elseif issue.kind == "unused" then
      counts.unused = counts.unused + 1
    elseif issue.kind == "drift_missing" or issue.kind == "drift_extra" then
      counts.drift = counts.drift + 1
    elseif issue.kind == "resource_error" then
      counts.resource = counts.resource + 1
    elseif issue.kind == "resource_root_missing" then
      counts.root = counts.root + 1
    end
  end
  local parts = {}
  local labels = {
    missing = "missing",
    mismatch = "mismatch",
    unused = "unused",
    drift = "drift",
    resource = "resource errors",
    root = "roots missing",
  }
  for _, key in ipairs({ "missing", "mismatch", "unused", "drift", "resource", "root" }) do
    local count = counts[key]
    if count and count > 0 then
      table.insert(parts, string.format("%s %d", labels[key], count))
    end
  end
  if #parts == 0 then
    return "ok"
  end
  return table.concat(parts, ", ")
end

---@param issues I18nStatusDoctorIssue[]
---@return integer
local function highest_severity(issues)
  local level = vim.log.levels.INFO
  for _, issue in ipairs(issues) do
    if issue.severity > level then
      level = issue.severity
    end
  end
  return level
end

--- Convert Rust severity (u32: 1=WARN, 2=ERROR, 3=INFO) to vim severity
---@param severity number
---@return integer
local function convert_severity(severity)
  if severity == 1 then
    return vim.log.levels.WARN
  elseif severity == 2 then
    return vim.log.levels.ERROR
  elseif severity == 3 then
    return vim.log.levels.INFO
  end
  return vim.log.levels.INFO
end

--- Convert Rust doctor result to Lua issue format
---@param rust_issues table[]
---@return I18nStatusDoctorIssue[]
local function convert_issues(rust_issues)
  local issues = {}
  for _, issue in ipairs(rust_issues or {}) do
    table.insert(issues, {
      kind = issue.kind,
      message = issue.message,
      severity = convert_severity(issue.severity),
      file = issue.file,
      key = issue.key,
      lnum = issue.lnum,
      col = issue.col,
    })
  end
  return issues
end

---@param ft string
---@return string|nil
local function doctor_lang_for_filetype(ft)
  local lang = filetypes.lang_for_filetype(ft)
  if lang ~= "" then
    return lang
  end
  return nil
end

local OPEN_BUFFER_MAX_BYTES = 512 * 1024
local DEFAULT_DEADLINE_MS = 60 * 1000
local MAX_DEADLINE_MS = 120 * 1000
local RPC_DEADLINE_GRACE_MS = 5 * 1000

---@class I18nStatusDoctorDeadline
---@field duration_ms integer
---@field expires_at_ns number
---@field notified boolean

---@param deadline_ms integer|nil
---@return I18nStatusDoctorDeadline
local function new_deadline(deadline_ms)
  local duration_ms = math.min(MAX_DEADLINE_MS, math.max(1, deadline_ms or DEFAULT_DEADLINE_MS))
  return {
    duration_ms = duration_ms,
    expires_at_ns = uv.hrtime() + (duration_ms * 1000000),
    notified = false,
  }
end

---@param deadline I18nStatusDoctorDeadline
---@return integer
local function remaining_deadline_ms(deadline)
  local remaining_ms = (deadline.expires_at_ns - uv.hrtime()) / 1000000
  if remaining_ms <= 0 then
    return 0
  end
  return math.max(1, math.ceil(remaining_ms))
end

---@param deadline I18nStatusDoctorDeadline
---@return boolean
local function deadline_expired(deadline)
  return remaining_deadline_ms(deadline) == 0
end

---@param deadline I18nStatusDoctorDeadline
---@return string
local function deadline_message(deadline)
  return string.format("deadline exceeded after %dms", deadline.duration_ms)
end

---@param deadline I18nStatusDoctorDeadline
local function notify_deadline_once(deadline)
  if deadline.notified then
    return
  end
  deadline.notified = true
  vim.notify("i18n-status doctor: " .. deadline_message(deadline), vim.log.levels.ERROR)
end

---@type table<string, { changedtick: integer }>
local open_buffer_snapshots = {}

---@param open_buf_paths string[]
---@param seen table<string, boolean>
---@param path string|nil
local function add_open_buffer_path(open_buf_paths, seen, path)
  if not path or path == "" or seen[path] then
    return
  end
  seen[path] = true
  table.insert(open_buf_paths, path)
end

---@param bufnr integer
---@return integer|nil
local function buffer_size_bytes(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local ok, size = pcall(vim.api.nvim_buf_get_offset, bufnr, line_count)
  if ok and type(size) == "number" and size >= 0 then
    return size
  end
  return nil
end

---@param ctx I18nStatusDoctorContext
---@param deadline I18nStatusDoctorDeadline
---@return { open_buffers: table[], open_buf_paths: string[] }|nil
---@return string|nil
local function collect_open_buffer_payload(ctx, deadline)
  local open_buffers = {}
  local open_buf_paths = {}
  local open_buf_path_seen = {}
  local next_snapshots = {}
  local skipped_large_count = 0

  for _, open_buf in ipairs(ctx.buffers) do
    if deadline_expired(deadline) then
      return nil, "deadline"
    end
    if vim.api.nvim_buf_is_valid(open_buf) and vim.api.nvim_buf_is_loaded(open_buf) then
      local ft = vim.bo[open_buf].filetype
      local lang = doctor_lang_for_filetype(ft)
      if lang then
        local path = vim.api.nvim_buf_get_name(open_buf)
        local has_path = path ~= nil and path ~= ""
        local changedtick = vim.api.nvim_buf_get_changedtick(open_buf)

        local should_send = true
        if has_path then
          local snapshot = open_buffer_snapshots[path]
          should_send = vim.bo[open_buf].modified or not snapshot or snapshot.changedtick ~= changedtick
          if not should_send then
            next_snapshots[path] = snapshot
          end
        end

        if should_send then
          local size_bytes = buffer_size_bytes(open_buf)
          if size_bytes and size_bytes > OPEN_BUFFER_MAX_BYTES then
            skipped_large_count = skipped_large_count + 1
          else
            local lines = vim.api.nvim_buf_get_lines(open_buf, 0, -1, false)
            if deadline_expired(deadline) then
              return nil, "deadline"
            end
            local entry = {
              lang = lang,
              source = table.concat(lines, "\n"),
            }
            if has_path then
              entry.path = path
              add_open_buffer_path(open_buf_paths, open_buf_path_seen, path)
              local real = vim.uv.fs_realpath(path)
              if real and real ~= "" then
                add_open_buffer_path(open_buf_paths, open_buf_path_seen, real)
              end
              next_snapshots[path] = { changedtick = changedtick }
            end
            table.insert(open_buffers, entry)
          end
        end
      end
    end
  end

  if deadline_expired(deadline) then
    return nil, "deadline"
  end
  open_buffer_snapshots = next_snapshots

  if skipped_large_count > 0 then
    vim.notify(
      string.format(
        "i18n-status doctor: skipped %d open buffer(s) over %d bytes",
        skipped_large_count,
        OPEN_BUFFER_MAX_BYTES
      ),
      vim.log.levels.WARN
    )
  end

  return {
    open_buffers = open_buffers,
    open_buf_paths = open_buf_paths,
  }, nil
end

---@param cache I18nStatusCache
---@return string
local function fallback_namespace_from_cache(cache)
  local namespaces = cache.namespaces or {}
  if #namespaces == 1 then
    return namespaces[1]
  end
  for _, namespace in ipairs(namespaces) do
    if namespace == "translation" then
      return namespace
    end
  end
  return namespaces[1] or "common"
end

---@param bufnr integer
---@param config I18nStatusConfig
---@param deadline I18nStatusDoctorDeadline
---@return I18nStatusDoctorContext|nil
---@return string|nil
local function prepare_context(bufnr, config, deadline)
  config = config or {}
  if deadline_expired(deadline) then
    return nil, "deadline"
  end
  local start_dir = resources.start_dir(bufnr)
  local root_list, roots_err = resources.resolve_roots_sync(start_dir, remaining_deadline_ms(deadline))
  if roots_err then
    if deadline_expired(deadline) or tostring(roots_err):find("timeout", 1, true) then
      return nil, "deadline"
    end
    return nil, "resource preflight failed: " .. tostring(roots_err)
  end
  if deadline_expired(deadline) then
    return nil, "deadline"
  end
  local cache_key = resources.cache_key(root_list, start_dir)
  local cached = resources.caches[cache_key]
  local cache = cached
    or {
      key = cache_key,
      index = {},
      files = {},
      languages = {},
      roots = root_list,
      errors = {},
      namespaces = {},
      dirty = true,
      checked_at = 0,
    }
  local fallback_ns = fallback_namespace_from_cache(cache)
  local ignore_patterns = sanitize_ignore_patterns((config.doctor and config.doctor.ignore_keys) or {})
  local is_ignored = make_ignore_fn(ignore_patterns)

  local project_root = resources.project_root(start_dir, root_list, { resolve_empty = false }) or start_dir
  if deadline_expired(deadline) then
    return nil, "deadline"
  end

  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if deadline_expired(deadline) then
      return nil, "deadline"
    end
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if filetypes.is_source_filetype(ft) then
        table.insert(buffers, buf)
      end
    end
  end

  return {
    bufnr = bufnr,
    config = config,
    cache = cache,
    start_dir = start_dir,
    fallback_ns = fallback_ns,
    ignore_patterns = ignore_patterns,
    is_ignored = is_ignored,
    buffers = buffers,
    items_by_buf = {},
    used_keys = {},
    project_root = project_root,
    cache_snapshot = {
      key = cache_key,
      cache = cached,
      revision = (cached and cached.revision) or 0,
    },
  },
    nil
end

---@param issues I18nStatusDoctorIssue[]
---@param ctx I18nStatusDoctorContext
---@param config I18nStatusConfig
local function report_issues(issues, ctx, config)
  local level = highest_severity(issues)
  local summary = summarize(issues)

  vim.notify("i18n-status doctor: " .. summary, level)

  local review = require("i18n-status.review")
  review.open_doctor_results(issues, ctx, config)
end

local CANCEL_TOKEN_DIR = vim.fs.joinpath(uv.os_tmpdir(), "i18n-status", "doctor-cancel")
local cancel_token_seq = 0
local doctor_deadline_ms = DEFAULT_DEADLINE_MS

---@param path string|nil
local function clear_cancel_token(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  if uv.fs_stat(path) then
    pcall(uv.fs_unlink, path)
  end
end

---@param path string|nil
local function signal_cancel(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  local dir = vim.fs.dirname(path)
  if type(dir) == "string" and dir ~= "" then
    fs.ensure_dir(dir)
  end
  local fd = uv.fs_open(path, "w", 384)
  if not fd then
    return
  end
  uv.fs_write(fd, "1", 0)
  uv.fs_close(fd)
end

---@return string
local function next_cancel_token_path()
  cancel_token_seq = cancel_token_seq + 1
  fs.ensure_dir(CANCEL_TOKEN_DIR)
  local token = string.format("%d-%d-%d", vim.fn.getpid(), uv.hrtime(), cancel_token_seq)
  return vim.fs.joinpath(CANCEL_TOKEN_DIR, token .. ".cancel")
end

---@param timer uv_timer_t|nil
local function stop_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

---@param timer uv_timer_t
---@param deadline I18nStatusDoctorDeadline
---@param on_expire fun()
local function arm_deadline_timer(timer, deadline, on_expire)
  local arm
  arm = function()
    if timer:is_closing() then
      return
    end
    local remaining_ms = remaining_deadline_ms(deadline)
    if remaining_ms == 0 then
      on_expire()
      return
    end
    timer:start(remaining_ms, 0, function()
      vim.schedule(function()
        if timer:is_closing() then
          return
        end
        if deadline_expired(deadline) then
          on_expire()
        else
          arm()
        end
      end)
    end)
  end
  arm()
end

---@class I18nStatusDoctorResultStatus
---@field cancelled boolean|nil
---@field deadline boolean|nil
---@field error string|nil

---@class I18nStatusDoctorJob
---@field generation integer
---@field bufnr integer
---@field config I18nStatusConfig|nil
---@field ctx I18nStatusDoctorContext|nil
---@field cancelled boolean
---@field cancel_token_path string
---@field request_id integer|nil
---@field progress_handler fun(params: table|nil)|nil
---@field started boolean
---@field deadline I18nStatusDoctorDeadline
---@field deadline_timer uv_timer_t|nil

---@type I18nStatusDoctorJob|nil
local active_job = nil
local run_generation = 0

local progress_handler_key = "doctor/progress"

---@param job I18nStatusDoctorJob
local function stop_job_deadline_timer(job)
  stop_timer(job.deadline_timer)
  job.deadline_timer = nil
end

---@param job I18nStatusDoctorJob
local function unregister_job_progress(job)
  if not job.progress_handler then
    return
  end
  rpc.off_notification(progress_handler_key, job.progress_handler)
  job.progress_handler = nil
end

---@param job I18nStatusDoctorJob
local function expire_active_job(job)
  if active_job ~= job or run_generation ~= job.generation or job.cancelled then
    return
  end
  job.cancelled = true
  active_job = nil
  signal_cancel(job.cancel_token_path)
  unregister_job_progress(job)
  stop_job_deadline_timer(job)
  if not job.started then
    clear_cancel_token(job.cancel_token_path)
  end
  notify_deadline_once(job.deadline)
end

---@param job I18nStatusDoctorJob
local function start_job_deadline_timer(job)
  local timer = uv.new_timer()
  if not timer then
    return
  end
  job.deadline_timer = timer
  pcall(function()
    timer:unref()
  end)
  arm_deadline_timer(timer, job.deadline, function()
    expire_active_job(job)
  end)
end

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
---@param cb fun(issues: I18nStatusDoctorIssue[], status?: I18nStatusDoctorResultStatus, ctx?: I18nStatusDoctorContext)
---@param opts? { cancel_token_path?: string, deadline_ms?: integer, deadline?: I18nStatusDoctorDeadline, external_deadline_timer?: boolean, context?: I18nStatusDoctorContext }
---@return integer|nil request_id
function M.diagnose(bufnr, config, cb, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local deadline = opts.deadline or new_deadline(opts.deadline_ms or doctor_deadline_ms)
  local cancel_token_path = opts.cancel_token_path or next_cancel_token_path()
  local finished = false
  local deadline_reached = false
  local rpc_finished = false
  local request_started = false
  local deadline_timer = nil
  local ctx = opts.context

  ---@param issues I18nStatusDoctorIssue[]
  ---@param status I18nStatusDoctorResultStatus|nil
  local function finish(issues, status)
    if finished then
      return
    end
    finished = true
    stop_timer(deadline_timer)
    vim.schedule(function()
      if rpc_finished or not request_started then
        clear_cancel_token(cancel_token_path)
      end
      cb(issues, status, ctx)
    end)
  end

  local function finish_deadline()
    if finished then
      return
    end
    deadline_reached = true
    signal_cancel(cancel_token_path)
    if not request_started or rpc_finished then
      clear_cancel_token(cancel_token_path)
    end
    notify_deadline_once(deadline)
    finish({}, { cancelled = true, deadline = true, error = deadline_message(deadline) })
  end

  ---@param err? string
  local function finish_cancelled(err)
    if not request_started then
      clear_cancel_token(cancel_token_path)
    end
    finish({}, { cancelled = true, error = err })
  end

  if not opts.external_deadline_timer then
    deadline_timer = uv.new_timer()
    if deadline_timer then
      pcall(function()
        deadline_timer:unref()
      end)
      arm_deadline_timer(deadline_timer, deadline, function()
        finish_deadline()
      end)
    end
  end

  if deadline_expired(deadline) then
    finish_deadline()
    return nil
  end
  if uv.fs_stat(cancel_token_path) then
    finish_cancelled()
    return nil
  end

  if not ctx then
    local prepared, prepared_ctx, prepare_err = xpcall(function()
      return prepare_context(bufnr, config, deadline)
    end, debug.traceback)
    if not prepared then
      clear_cancel_token(cancel_token_path)
      local message = tostring(prepared_ctx)
      vim.notify("i18n-status doctor: " .. message, vim.log.levels.ERROR)
      finish({}, { error = message })
      return nil
    end
    if not prepared_ctx then
      if prepare_err == "deadline" or deadline_expired(deadline) then
        finish_deadline()
      else
        clear_cancel_token(cancel_token_path)
        local message = tostring(prepare_err or "failed to prepare Doctor context")
        vim.notify("i18n-status doctor: " .. message, vim.log.levels.ERROR)
        finish({}, { error = message })
      end
      return nil
    end
    ctx = prepared_ctx
  end

  if deadline_expired(deadline) then
    finish_deadline()
    return nil
  end
  if uv.fs_stat(cancel_token_path) then
    finish_cancelled()
    return nil
  end

  local open_payload, payload_err = collect_open_buffer_payload(ctx, deadline)
  if not open_payload then
    if payload_err == "deadline" or deadline_expired(deadline) then
      finish_deadline()
    else
      clear_cancel_token(cancel_token_path)
      local message = tostring(payload_err or "failed to collect open buffers")
      vim.notify("i18n-status doctor: " .. message, vim.log.levels.ERROR)
      finish({}, { error = message })
    end
    return nil
  end

  if deadline_expired(deadline) then
    finish_deadline()
    return nil
  end
  if uv.fs_stat(cancel_token_path) then
    finish_cancelled()
    return nil
  end

  local remaining_ms = remaining_deadline_ms(deadline)
  request_started = true
  local request_id = rpc.request("doctor/diagnose", {
    project_root = ctx.project_root,
    roots = ctx.cache.roots or {},
    primary_lang = config and config.primary_lang or (ctx.cache.languages[1] or ""),
    languages = ctx.cache.languages or {},
    fallback_namespace = ctx.fallback_ns,
    ignore_patterns = ctx.ignore_patterns,
    open_buf_paths = open_payload.open_buf_paths,
    open_buffers = open_payload.open_buffers,
    cancel_token_path = cancel_token_path,
    deadline_ms = remaining_ms,
  }, function(err, result)
    rpc_finished = true
    local was_cancelled = uv.fs_stat(cancel_token_path) ~= nil
    clear_cancel_token(cancel_token_path)
    if finished then
      return
    end
    vim.schedule(function()
      if finished then
        return
      end
      if deadline_reached or deadline_expired(deadline) then
        finish_deadline()
        return
      end
      if err then
        local message = tostring(err)
        if message:find("deadline", 1, true) then
          deadline_reached = true
          notify_deadline_once(deadline)
          finish({}, { cancelled = true, deadline = true, error = message })
          return
        end
        if
          was_cancelled
          or message == "doctor request cancelled"
          or message:find("superseded by a newer request", 1, true)
        then
          finish({}, { cancelled = true, error = message })
          return
        end
        vim.notify("i18n-status doctor: " .. message, vim.log.levels.ERROR)
        finish({}, { error = message })
        return
      end
      if result and result.cancelled then
        finish({}, { cancelled = true })
        return
      end
      if result and type(result.resource_index) == "table" then
        local stored, stored_cache, _published = pcall(
          resources.store_index_if_current,
          ctx.start_dir,
          ctx.cache.roots,
          result.resource_index,
          ctx.cache_snapshot
        )
        if not stored then
          local message = "failed to store Doctor resource index: " .. tostring(stored_cache)
          vim.notify("i18n-status doctor: " .. message, vim.log.levels.ERROR)
          finish({}, { error = message })
          return
        end
        if stored_cache then
          ctx.cache = stored_cache
          ctx.fallback_ns = fallback_namespace_from_cache(stored_cache)
        end
      end
      local issues = convert_issues(result and result.issues or {})
      local filtered = {}
      for _, issue in ipairs(issues) do
        if not issue.key or not ctx.is_ignored(issue.key) then
          table.insert(filtered, issue)
        end
      end
      local used_keys = result and result.used_keys or {}
      ctx.used_keys = used_keys
      finish(filtered)
    end)
  end, { timeout_ms = remaining_ms + RPC_DEADLINE_GRACE_MS })

  return request_id
end

---Refresh doctor context.
---@param ctx I18nStatusDoctorContext
---@param opts? { full?: boolean }
---@param cb fun(issues: I18nStatusDoctorIssue[])
function M.refresh(ctx, _opts, cb)
  local function finish_refresh(issues, status, refreshed_ctx)
    if status and (status.cancelled or status.error) then
      return
    end
    for key, value in pairs(refreshed_ctx or {}) do
      ctx[key] = value
    end
    cb(issues)
  end

  -- Rust performs the full project diagnosis for both refresh modes.
  M.diagnose(ctx.bufnr or vim.api.nvim_get_current_buf(), ctx.config, finish_refresh)
end

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
function M.run(bufnr, config)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local deadline = new_deadline(doctor_deadline_ms)
  run_generation = run_generation + 1

  if active_job then
    active_job.cancelled = true
    signal_cancel(active_job.cancel_token_path)
    unregister_job_progress(active_job)
    stop_job_deadline_timer(active_job)
    if not active_job.started then
      clear_cancel_token(active_job.cancel_token_path)
    end
    active_job = nil
  end

  vim.notify("i18n-status doctor: running... (:I18nDoctorCancel to cancel)", vim.log.levels.INFO)

  local job = {
    generation = run_generation,
    bufnr = bufnr,
    config = config,
    ctx = nil,
    cancelled = false,
    cancel_token_path = next_cancel_token_path(),
    request_id = nil,
    progress_handler = nil,
    started = false,
    deadline = deadline,
    deadline_timer = nil,
  }
  active_job = job

  job.progress_handler = function(params)
    vim.schedule(function()
      if
        active_job ~= job
        or run_generation ~= job.generation
        or job.cancelled
        or job.request_id == nil
        or not params
        or params.request_id ~= job.request_id
      then
        return
      end
      local message = params.message or ""
      vim.api.nvim_echo(
        { { "i18n-status doctor: " .. message .. " (:I18nDoctorCancel to cancel)", "Normal" } },
        false,
        {}
      )
    end)
  end
  rpc.on_notification(progress_handler_key, job.progress_handler)
  start_job_deadline_timer(job)

  vim.defer_fn(function()
    if active_job ~= job or run_generation ~= job.generation or job.cancelled then
      clear_cancel_token(job.cancel_token_path)
      return
    end
    if deadline_expired(job.deadline) then
      expire_active_job(job)
      return
    end

    job.started = true
    job.request_id = M.diagnose(bufnr, config, function(issues, status, ctx)
      if active_job ~= job or run_generation ~= job.generation or job.cancelled then
        return
      end
      active_job = nil
      unregister_job_progress(job)
      stop_job_deadline_timer(job)
      if status and (status.cancelled or status.error) then
        return
      end
      if not ctx then
        return
      end
      job.ctx = ctx
      ctx.cancel_token_path = job.cancel_token_path
      report_issues(issues, ctx, config)
    end, {
      cancel_token_path = job.cancel_token_path,
      deadline = job.deadline,
      external_deadline_timer = job.deadline_timer ~= nil,
    })
  end, 0)
end

---@return boolean
function M.cancel()
  if not active_job then
    vim.notify("i18n-status doctor: no running job", vim.log.levels.INFO)
    return false
  end
  local job = active_job
  job.cancelled = true
  active_job = nil
  signal_cancel(job.cancel_token_path)
  unregister_job_progress(job)
  stop_job_deadline_timer(job)
  if not job.started then
    clear_cancel_token(job.cancel_token_path)
  end
  vim.notify("i18n-status doctor: cancelled", vim.log.levels.INFO)
  return true
end

---Reset module-local snapshot state used by open buffer delta sending.
---Intended for tests.
function M._reset_open_buffer_snapshots_for_test()
  open_buffer_snapshots = {}
  run_generation = run_generation + 1
  if active_job then
    active_job.cancelled = true
    signal_cancel(active_job.cancel_token_path)
    unregister_job_progress(active_job)
    stop_job_deadline_timer(active_job)
    clear_cancel_token(active_job.cancel_token_path)
    active_job = nil
  end
  doctor_deadline_ms = DEFAULT_DEADLINE_MS
end

---@param deadline_ms integer
function M._set_deadline_ms_for_test(deadline_ms)
  doctor_deadline_ms = deadline_ms
end

return M
