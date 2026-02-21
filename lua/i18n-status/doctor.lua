---@class I18nStatusDoctor
local M = {}

local rpc = require("i18n-status.rpc")
local resources = require("i18n-status.resources")
local util = require("i18n-status.util")
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
  local lang = util.lang_for_filetype(ft)
  if lang ~= "" then
    return lang
  end
  return nil
end

local OPEN_BUFFER_MAX_BYTES = 512 * 1024

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
---@return { open_buffers: table[], open_buf_paths: string[] }
local function collect_open_buffer_payload(ctx)
  local open_buffers = {}
  local open_buf_paths = {}
  local open_buf_path_seen = {}
  local active_named_paths = {}
  local skipped_large_count = 0

  for _, open_buf in ipairs(ctx.buffers) do
    if vim.api.nvim_buf_is_valid(open_buf) and vim.api.nvim_buf_is_loaded(open_buf) then
      local ft = vim.bo[open_buf].filetype
      local lang = doctor_lang_for_filetype(ft)
      if lang then
        local path = vim.api.nvim_buf_get_name(open_buf)
        local has_path = path ~= nil and path ~= ""
        local changedtick = vim.api.nvim_buf_get_changedtick(open_buf)

        local should_send = true
        if has_path then
          active_named_paths[path] = true
          local snapshot = open_buffer_snapshots[path]
          should_send = vim.bo[open_buf].modified or not snapshot or snapshot.changedtick ~= changedtick
        end

        if should_send then
          local size_bytes = buffer_size_bytes(open_buf)
          if size_bytes and size_bytes > OPEN_BUFFER_MAX_BYTES then
            skipped_large_count = skipped_large_count + 1
            if has_path then
              open_buffer_snapshots[path] = nil
            end
          else
            local lines = vim.api.nvim_buf_get_lines(open_buf, 0, -1, false)
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
              open_buffer_snapshots[path] = { changedtick = changedtick }
            end
            table.insert(open_buffers, entry)
          end
        end
      end
    end
  end

  for path in pairs(open_buffer_snapshots) do
    if not active_named_paths[path] then
      open_buffer_snapshots[path] = nil
    end
  end

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
  }
end

---@param bufnr integer
---@param config I18nStatusConfig
---@return I18nStatusDoctorContext
local function prepare_context(bufnr, config)
  config = config or {}
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local fallback_ns = resources.fallback_namespace(start_dir)
  local ignore_patterns = sanitize_ignore_patterns((config.doctor and config.doctor.ignore_keys) or {})
  local is_ignored = make_ignore_fn(ignore_patterns)

  local project_root = resources.project_root(start_dir, cache.roots) or start_dir

  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if util.is_source_filetype(ft) then
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
  }
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
    util.ensure_dir(dir)
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
  util.ensure_dir(CANCEL_TOKEN_DIR)
  local token = string.format("%d-%d-%d", vim.fn.getpid(), uv.hrtime(), cancel_token_seq)
  return vim.fs.joinpath(CANCEL_TOKEN_DIR, token .. ".cancel")
end

---@type { ctx: I18nStatusDoctorContext, cancelled: boolean, cancel_token_path: string|nil }|nil
local active_job = nil

local progress_handler_key = "doctor/progress"
local progress_handler = nil

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
---@param cb fun(issues: I18nStatusDoctorIssue[])
---@param opts? { cancel_token_path?: string }
---@return integer|nil request_id
function M.diagnose(bufnr, config, cb, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local ctx = prepare_context(bufnr, config)
  local open_payload = collect_open_buffer_payload(ctx)

  return rpc.request("doctor/diagnose", {
    project_root = ctx.project_root,
    roots = ctx.cache.roots or {},
    primary_lang = config and config.primary_lang or (ctx.cache.languages[1] or ""),
    languages = ctx.cache.languages or {},
    fallback_namespace = ctx.fallback_ns,
    ignore_patterns = ctx.ignore_patterns,
    open_buf_paths = open_payload.open_buf_paths,
    open_buffers = open_payload.open_buffers,
    cancel_token_path = opts.cancel_token_path,
  }, function(err, result)
    vim.schedule(function()
      if err then
        if opts.cancel_token_path and uv.fs_stat(opts.cancel_token_path) then
          cb({})
          return
        end
        vim.notify("i18n-status doctor: " .. tostring(err), vim.log.levels.ERROR)
        cb({})
        return
      end
      if result and result.cancelled then
        cb({})
        return
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
      cb(filtered)
    end)
  end, { timeout_ms = 120000 })
end

---Refresh doctor context.
---@param ctx I18nStatusDoctorContext
---@param opts? { full?: boolean }
---@param cb fun(issues: I18nStatusDoctorIssue[])
function M.refresh(ctx, opts, cb)
  opts = opts or {}

  if opts.full then
    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
    M.diagnose(bufnr, ctx.config, cb)
    return
  end

  -- Lightweight refresh: rebuild from cached data
  ctx.cache = resources.ensure_index(ctx.start_dir)
  if not ctx.fallback_ns or ctx.fallback_ns == "" then
    ctx.fallback_ns = resources.fallback_namespace(ctx.start_dir)
  end

  -- For lightweight refresh, re-run diagnose since Rust handles everything
  M.diagnose(ctx.bufnr or vim.api.nvim_get_current_buf(), ctx.config, cb)
end

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
function M.run(bufnr, config)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if active_job then
    active_job.cancelled = true
    signal_cancel(active_job.cancel_token_path)
    active_job = nil
  end

  vim.notify("i18n-status doctor: running... (:I18nDoctorCancel to cancel)", vim.log.levels.INFO)

  -- Register progress handler
  if progress_handler then
    rpc.off_notification(progress_handler_key, progress_handler)
  end
  progress_handler = function(params)
    vim.schedule(function()
      if active_job and active_job.cancelled then
        return
      end
      local message = params and params.message or ""
      vim.api.nvim_echo(
        { { "i18n-status doctor: " .. message .. " (:I18nDoctorCancel to cancel)", "Normal" } },
        false,
        {}
      )
    end)
  end
  rpc.on_notification(progress_handler_key, progress_handler)

  vim.defer_fn(function()
    local ctx = prepare_context(bufnr, config)
    local cancel_token_path = next_cancel_token_path()
    ctx.cancel_token_path = cancel_token_path
    local job = { ctx = ctx, cancelled = false, cancel_token_path = cancel_token_path }
    active_job = job

    M.diagnose(bufnr, config, function(issues)
      clear_cancel_token(cancel_token_path)
      if job.cancelled then
        return
      end
      active_job = nil
      -- Remove progress handler
      if progress_handler then
        rpc.off_notification(progress_handler_key, progress_handler)
        progress_handler = nil
      end
      report_issues(issues, ctx, config)
    end, { cancel_token_path = cancel_token_path })
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
  if progress_handler then
    rpc.off_notification(progress_handler_key, progress_handler)
    progress_handler = nil
  end
  vim.notify("i18n-status doctor: cancelled", vim.log.levels.INFO)
  return true
end

---Reset module-local snapshot state used by open buffer delta sending.
---Intended for tests.
function M._reset_open_buffer_snapshots_for_test()
  open_buffer_snapshots = {}
end

return M
