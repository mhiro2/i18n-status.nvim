---@class I18nStatusDoctor
local M = {}

local scan = require("i18n-status.scan")
local resources = require("i18n-status.resources")
local discovery = require("i18n-status.resource_discovery")
local resolve = require("i18n-status.resolve")
local state = require("i18n-status.state")
local util = require("i18n-status.util")
local uv = vim.uv
local INVALID_PATTERN_WARNED = {}

local ASYNC_BATCH_SIZE = 20
local DEFAULT_EXCLUDE_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  [".next"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["coverage"] = true,
  ["out"] = true,
  [".turbo"] = true,
}

local EXT_TO_LANG = {
  ts = "typescript",
  js = "javascript",
  tsx = "tsx",
  jsx = "javascript",
  mts = "typescript",
  cts = "typescript",
  mjs = "javascript",
  cjs = "javascript",
}

local FILETYPE_TO_LANG = {
  javascript = "javascript",
  javascriptreact = "jsx",
  typescript = "typescript",
  typescriptreact = "tsx",
}

---@param path string
---@return string|nil
local function detect_lang_for_file(path)
  local ext = path:match("%.([%w_]+)$")
  if ext then
    local lang = EXT_TO_LANG[ext:lower()]
    if lang then
      return lang
    end
  end

  local ft = vim.filetype.match({ filename = path })
  if ft then
    return FILETYPE_TO_LANG[ft]
  end

  return nil
end

---@param path string
---@return boolean
local function is_excluded_path(path)
  local normalized = path:gsub("\\", "/")
  for dir, _ in pairs(DEFAULT_EXCLUDE_DIRS) do
    if
      normalized:find("/" .. dir .. "/")
      or normalized:find("/" .. dir .. "$")
      or normalized:find("^" .. dir .. "/")
      or normalized == dir
    then
      return true
    end
  end
  return false
end

---@param path string
---@return boolean
local function is_target_file(path)
  return detect_lang_for_file(path) ~= nil
end

---@param root string
---@param output string|nil
---@return string[]
local function parse_git_ls_output(root, output)
  local files = {}
  if not output or output == "" then
    return files
  end
  local parts = nil
  if output:find("\0", 1, true) then
    parts = vim.split(output, "\0", { plain = true, trimempty = true })
  else
    parts = vim.split(output, "\n", { plain = true, trimempty = true })
  end
  for _, path in ipairs(parts) do
    path = vim.trim(path)
    if path ~= "" and is_target_file(path) then
      table.insert(files, util.path_join(root, path))
    end
  end
  return files
end

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
---@field items_by_buf table<integer, I18nStatusScanItem[]>
---@field used_keys I18nStatusDoctorKeySet
---@field open_buf_paths table<string, boolean>
---@field project_root string
---@field project_keys I18nStatusDoctorKeySet|nil
---@field cancelled boolean|nil
---@field git_job uv_process_t|nil
---@field file_total integer|nil
---@field file_processed integer|nil
---@param bufnr integer
---@return boolean
local function is_target_buf(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" and buftype ~= "nofile" then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  return ft == "javascript" or ft == "typescript" or ft == "javascriptreact" or ft == "typescriptreact"
end

---@return integer[]
local function target_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_target_buf(buf) then
      table.insert(buffers, buf)
    end
  end
  return buffers
end

---@param ctx I18nStatusDoctorContext
---@return integer[]
local function select_buffers_for_ctx(ctx)
  if ctx.bufnr and is_target_buf(ctx.bufnr) then
    return { ctx.bufnr }
  end
  return target_buffers()
end

---@param ctx I18nStatusDoctorContext
local function rebuild_open_buf_paths(ctx)
  local open_buf_paths = {}
  for _, buf in ipairs(ctx.buffers or {}) do
    local buf_path = vim.api.nvim_buf_get_name(buf)
    if buf_path and buf_path ~= "" then
      open_buf_paths[buf_path] = true
    end
  end
  ctx.open_buf_paths = open_buf_paths
end

---@param roots table
---@param start_dir string
---@return string
local function determine_project_root(roots, start_dir)
  return discovery.project_root(start_dir, roots)
end

---@param file_path string
---@param fallback_ns string
---@param open_buf_paths table<string, boolean>
---@return I18nStatusDoctorKeySet
local function extract_keys_from_file(file_path, fallback_ns, open_buf_paths)
  local used_keys = {}
  -- Skip if file is already open as a buffer (will be scanned separately)
  if open_buf_paths[file_path] then
    return used_keys
  end
  local content = util.read_file(file_path)
  if not content then
    return used_keys
  end
  -- For very large files, use simple regex extraction to avoid performance issues
  local MAX_SIZE_FOR_TREESITTER = 500000 -- 500KB
  if #content > MAX_SIZE_FOR_TREESITTER then
    -- Simple regex fallback
    for key in content:gmatch("t%s*%(%s*[\"']([^\"']+)[\"']") do
      local ns = key:match("^(.-):")
      if not ns then
        key = fallback_ns .. ":" .. key
      end
      used_keys[key] = true
    end
    return used_keys
  end
  local lang = detect_lang_for_file(file_path)
  -- scan.extract_text internally uses vim.treesitter.get_string_parser when lang is provided,
  -- which lets us parse files without allocating scratch buffers.
  local items = scan.extract_text(content, lang, { fallback_namespace = fallback_ns })
  for _, item in ipairs(items) do
    used_keys[item.key] = true
  end
  return used_keys
end

---@param patterns string[]|nil
---@return string[]
local function sanitize_ignore_patterns(patterns)
  local valid_patterns = {}
  for _, pattern in ipairs(patterns or {}) do
    local ok, err = pcall(string.match, "", pattern)
    if ok then
      table.insert(valid_patterns, pattern)
    elseif not INVALID_PATTERN_WARNED[pattern] then
      INVALID_PATTERN_WARNED[pattern] = true
      vim.schedule(function()
        vim.notify(
          string.format("i18n-status doctor: invalid ignore pattern '%s' (%s)", pattern, err or "pattern error"),
          vim.log.levels.WARN
        )
      end)
    end
  end
  return valid_patterns
end

---@param message string
local function echo_progress(message)
  vim.api.nvim_echo({ { message, "Normal" } }, false, {})
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
      local ok, matched = pcall(string.match, key, pattern)
      if ok and matched then
        return true
      end
    end
    return false
  end
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

  local buffers = {}
  if is_target_buf(bufnr) then
    buffers = { bufnr }
  else
    buffers = target_buffers()
  end

  local items_by_buf = {}
  local used_keys = {}
  local open_buf_paths = {}
  for _, buf in ipairs(buffers) do
    local buf_path = vim.api.nvim_buf_get_name(buf)
    if buf_path and buf_path ~= "" then
      open_buf_paths[buf_path] = true
    end
    local items = scan.extract(buf, { fallback_namespace = fallback_ns })
    items_by_buf[buf] = items
    for _, item in ipairs(items) do
      if not is_ignored(item.key) then
        used_keys[item.key] = true
      end
    end
  end

  local project_root = determine_project_root(cache.roots, start_dir) or start_dir

  return {
    bufnr = bufnr,
    config = config,
    cache = cache,
    start_dir = start_dir,
    fallback_ns = fallback_ns,
    ignore_patterns = ignore_patterns,
    is_ignored = is_ignored,
    buffers = buffers,
    items_by_buf = items_by_buf,
    used_keys = used_keys,
    open_buf_paths = open_buf_paths,
    project_root = project_root,
  }
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

---@param ctx I18nStatusDoctorContext
---@return I18nStatusDoctorIssue[]
local function finalize_issues(ctx)
  local cache = ctx.cache
  local config = ctx.config or {}
  local used_keys = ctx.used_keys
  if ctx.project_keys then
    for key in pairs(ctx.project_keys) do
      if not ctx.is_ignored(key) then
        used_keys[key] = true
      end
    end
  end

  local project = cache.key and state.project_for_key(cache.key)
  local primary = (project and project.primary_lang) or config.primary_lang or (cache.languages[1] or "")
  local resolve_state = {
    primary_lang = primary,
    languages = cache.languages or {},
  }

  local issues = {}
  for buf, items in pairs(ctx.items_by_buf) do
    local resolved = resolve.compute(items, resolve_state, cache.index)
    for i, res in ipairs(resolved) do
      local item = items[i]
      if res.status == "×" then
        table.insert(issues, {
          kind = "missing",
          message = "missing: " .. res.key,
          severity = vim.log.levels.ERROR,
          bufnr = buf,
          lnum = item.lnum + 1,
          col = item.col + 1,
          key = res.key,
        })
      elseif res.status == "!" then
        local mismatches = res.hover and res.hover.mismatch_langs or {}
        local suffix = ""
        if #mismatches > 0 then
          suffix = " (" .. table.concat(mismatches, ", ") .. ")"
        end
        table.insert(issues, {
          kind = "mismatch",
          message = "placeholder mismatch: " .. res.key .. suffix,
          severity = vim.log.levels.WARN,
          bufnr = buf,
          lnum = item.lnum + 1,
          col = item.col + 1,
          key = res.key,
        })
      end
    end
  end

  if cache.errors and #cache.errors > 0 then
    for _, err in ipairs(cache.errors) do
      table.insert(issues, {
        kind = "resource_error",
        message = "resource error: " .. err.file .. " (" .. err.error .. ")",
        severity = vim.log.levels.WARN,
        file = err.file,
      })
    end
  end

  if not cache.roots or #cache.roots == 0 then
    table.insert(issues, {
      kind = "resource_root_missing",
      message = "resource root not found (locales/, public/locales/ or messages/)",
      severity = vim.log.levels.WARN,
    })
  end

  if next(used_keys) ~= nil then
    local unused = {}
    for _, entries in pairs(cache.index or {}) do
      for key, entry in pairs(entries) do
        if key ~= "__error__" and not used_keys[key] and not ctx.is_ignored(key) then
          unused[key] = entry
        end
      end
    end
    for key, entry in pairs(unused) do
      table.insert(issues, {
        kind = "unused",
        message = "unused: " .. key,
        severity = vim.log.levels.INFO,
        file = entry.file,
        key = key,
      })
    end
  end

  if primary and primary ~= "" and cache.index and cache.languages then
    local function collect_keys(lang)
      local keys = {}
      for key, entry in pairs(cache.index[lang] or {}) do
        if key ~= "__error__" and not ctx.is_ignored(key) then
          keys[key] = entry
        end
      end
      return keys
    end

    local primary_keys = collect_keys(primary)
    for _, lang in ipairs(cache.languages or {}) do
      if lang ~= primary then
        local current = collect_keys(lang)
        for key, entry in pairs(primary_keys) do
          if not current[key] then
            table.insert(issues, {
              kind = "drift_missing",
              message = "drift missing: " .. key .. " (" .. lang .. ")",
              severity = vim.log.levels.WARN,
              file = entry.file,
              key = key,
            })
          end
        end
        for key, entry in pairs(current) do
          if not primary_keys[key] then
            table.insert(issues, {
              kind = "drift_extra",
              message = "drift extra: " .. key .. " (" .. lang .. ")",
              severity = vim.log.levels.WARN,
              file = entry.file,
              key = key,
            })
          end
        end
      end
    end
  end

  return issues
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

---@param issues I18nStatusDoctorIssue[]
---@param ctx I18nStatusDoctorContext
---@param config I18nStatusConfig
local function report_issues(issues, ctx, config)
  local level = highest_severity(issues)
  local summary = summarize(issues)

  -- Show final results as notification
  vim.notify("i18n-status doctor: " .. summary, level)

  -- Open Review UI instead of Quickfix
  local review = require("i18n-status.review")
  review.open_doctor_results(issues, ctx, config)
end

---@param ctx I18nStatusDoctorContext
---@param cb fun(files: string[])
local function fs_walk_async(ctx, cb)
  if not ctx.project_root or ctx.project_root == "" then
    cb({})
    return
  end
  local queue = { ctx.project_root }
  local files = {}
  local function step()
    if ctx.cancelled then
      return
    end
    local processed = 0
    while processed < ASYNC_BATCH_SIZE and #queue > 0 do
      local dir = table.remove(queue)
      local ok, handle = pcall(uv.fs_scandir, dir)
      if ok and handle then
        while true do
          local name, typ = uv.fs_scandir_next(handle)
          if not name then
            break
          end
          local full_path = util.path_join(dir, name)
          if typ == "directory" then
            if not is_excluded_path(full_path) then
              table.insert(queue, full_path)
            end
          elseif typ == "file" then
            if is_target_file(name) then
              table.insert(files, full_path)
            end
          end
        end
      end
      processed = processed + 1
    end
    if #queue == 0 then
      cb(files)
    else
      echo_progress(
        string.format("i18n-status doctor: collecting files (%d found)... (:I18nDoctorCancel to cancel)", #files)
      )
      vim.defer_fn(step, 0)
    end
  end
  step()
end

---@param ctx I18nStatusDoctorContext
---@param cb fun(files: string[])
local function collect_project_files_async(ctx, cb)
  if not ctx.project_root or ctx.project_root == "" then
    cb({})
    return
  end
  ctx.git_job = vim.system(
    { "git", "-C", ctx.project_root, "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
    { text = true },
    function(obj)
      vim.schedule(function()
        if ctx.cancelled then
          return
        end

        ctx.git_job = nil

        if obj.code ~= 0 then
          fs_walk_async(ctx, cb)
          return
        end
        local files = parse_git_ls_output(ctx.project_root, obj.stdout or "")
        if #files == 0 then
          fs_walk_async(ctx, cb)
        else
          cb(files)
        end
      end)
    end
  )
end

---@param ctx I18nStatusDoctorContext
---@param files string[]
---@param cb fun(keys: I18nStatusDoctorKeySet)
local function process_files_async(ctx, files, cb)
  if not files or #files == 0 then
    cb({})
    return
  end
  local progress = { idx = 1, used = {} }
  local total = #files
  local function step()
    if ctx.cancelled then
      return
    end
    local processed = 0
    while processed < ASYNC_BATCH_SIZE and progress.idx <= total do
      local path = files[progress.idx]
      progress.idx = progress.idx + 1
      processed = processed + 1
      local keys = extract_keys_from_file(path, ctx.fallback_ns, ctx.open_buf_paths)
      for key in pairs(keys) do
        if not ctx.is_ignored(key) then
          progress.used[key] = true
        end
      end
    end
    ctx.file_processed = math.min(progress.idx - 1, total)
    if progress.idx > total then
      cb(progress.used)
    else
      echo_progress(
        string.format(
          "i18n-status doctor: analyzing %d/%d files... (:I18nDoctorCancel to cancel)",
          progress.idx - 1,
          total
        )
      )
      vim.defer_fn(step, 0)
    end
  end
  step()
end

---@param ctx I18nStatusDoctorContext
---@param cb fun(keys: I18nStatusDoctorKeySet)
local function collect_project_keys_async(ctx, cb)
  if ctx.cancelled then
    cb({})
    return
  end

  echo_progress("i18n-status doctor: collecting files... (:I18nDoctorCancel to cancel)")

  collect_project_files_async(ctx, function(files)
    if ctx.cancelled then
      cb({})
      return
    end
    if not files or #files == 0 then
      echo_progress("i18n-status doctor: no files found")
      cb({})
      return
    end
    ctx.file_total = #files
    ctx.file_processed = 0
    echo_progress(string.format("i18n-status doctor: analyzing 0/%d files... (:I18nDoctorCancel to cancel)", #files))

    process_files_async(ctx, files, function(keys)
      if ctx.cancelled then
        cb({})
        return
      end
      cb(keys)
    end)
  end)
end

local CANCEL_TIMEOUT_MS = 2000

---@class I18nStatusAsyncJob
---@field ctx I18nStatusDoctorContext
---@field state "running"|"cancelling"|"done"

---@type I18nStatusAsyncJob|nil
local active_job = nil

local function cancel_active_job()
  if not active_job then
    return false
  end
  local job = active_job
  if job.state ~= "running" then
    active_job = nil
    return false
  end

  job.state = "cancelling"
  job.ctx.cancelled = true

  -- Kill git process if running
  local git_job = job.ctx.git_job
  if git_job and git_job.kill then
    pcall(function()
      git_job:kill(15)
    end)
  end

  -- Force cleanup after timeout
  vim.defer_fn(function()
    if job.state == "cancelling" then
      job.state = "done"
    end
    if active_job == job then
      active_job = nil
    end
  end, CANCEL_TIMEOUT_MS)

  -- Clear immediately if no git job pending
  if not git_job then
    active_job = nil
  end
  return true
end

---@param job I18nStatusAsyncJob
local function complete_job(job)
  job.state = "done"
  if active_job == job then
    active_job = nil
  end
end

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
---@param cb fun(issues: I18nStatusDoctorIssue[])
function M.diagnose(bufnr, config, cb)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ctx = prepare_context(bufnr, config)
  ctx.cancelled = false

  collect_project_keys_async(ctx, function(project_keys)
    if ctx.cancelled then
      return
    end
    ctx.project_keys = project_keys
    cb(finalize_issues(ctx))
  end)
end

---Refresh doctor context.
---Lightweight by default; set opts.full = true to re-collect project_keys.
---@param ctx I18nStatusDoctorContext
---@param opts? { full?: boolean }
---@param cb fun(issues: I18nStatusDoctorIssue[])
function M.refresh(ctx, opts, cb)
  opts = opts or {}
  local full = opts.full == true

  if full then
    local bufnr = ctx.bufnr or ctx.source_buf or vim.api.nvim_get_current_buf()
    local base = prepare_context(bufnr, ctx.config)
    ctx.bufnr = base.bufnr
    ctx.config = base.config
    ctx.cache = base.cache
    ctx.start_dir = base.start_dir
    ctx.fallback_ns = base.fallback_ns
    ctx.ignore_patterns = base.ignore_patterns
    ctx.is_ignored = base.is_ignored
    ctx.buffers = base.buffers
    ctx.items_by_buf = base.items_by_buf
    ctx.used_keys = base.used_keys
    ctx.open_buf_paths = base.open_buf_paths
    ctx.project_root = base.project_root

    ctx.cancelled = false
    collect_project_keys_async(ctx, function(project_keys)
      if ctx.cancelled then
        return
      end
      ctx.project_keys = project_keys
      cb(finalize_issues(ctx))
    end)
    return
  end

  if not ctx.fallback_ns or ctx.fallback_ns == "" then
    ctx.fallback_ns = resources.fallback_namespace(ctx.start_dir)
  end
  if not ctx.is_ignored then
    ctx.ignore_patterns = ctx.ignore_patterns or {}
    ctx.is_ignored = make_ignore_fn(ctx.ignore_patterns)
  end

  -- Re-fetch index from disk (picks up JSON file changes)
  ctx.cache = resources.ensure_index(ctx.start_dir)

  if not ctx.buffers then
    ctx.buffers = select_buffers_for_ctx(ctx)
  end
  rebuild_open_buf_paths(ctx)

  -- Re-scan all open buffers to pick up in-memory edits
  ctx.items_by_buf = {}
  ctx.used_keys = {}
  for _, buf in ipairs(ctx.buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local items = scan.extract(buf, { fallback_namespace = ctx.fallback_ns })
      ctx.items_by_buf[buf] = items
      for _, item in ipairs(items) do
        if not ctx.is_ignored(item.key) then
          ctx.used_keys[item.key] = true
        end
      end
    end
  end

  -- Re-finalize issues (reuses ctx.project_keys)
  cb(finalize_issues(ctx))
end

---@param bufnr integer|nil
---@param config I18nStatusConfig|nil
function M.run(bufnr, config)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  cancel_active_job()

  vim.notify("i18n-status doctor: running... (:I18nDoctorCancel to cancel)", vim.log.levels.INFO)

  -- Defer heavy work to next tick so the notification appears first
  vim.defer_fn(function()
    local ctx = prepare_context(bufnr, config)
    ctx.cancelled = false

    local job = { ctx = ctx, state = "running" }
    active_job = job

    collect_project_keys_async(ctx, function(project_keys)
      if ctx.cancelled or job.state ~= "running" then
        complete_job(job)
        return
      end

      ctx.project_keys = project_keys
      local issues = finalize_issues(ctx)
      complete_job(job)
      report_issues(issues, ctx, config)
    end)
  end, 0)
end

---@return boolean
function M.cancel()
  local job = active_job
  local cancelled = cancel_active_job()
  if cancelled then
    local msg = "i18n-status doctor: cancelled"
    if job and job.ctx and job.ctx.file_total then
      msg = string.format(
        "i18n-status doctor: cancelled (%d/%d files analyzed)",
        job.ctx.file_processed or 0,
        job.ctx.file_total
      )
    end
    vim.notify(msg, vim.log.levels.INFO)
  else
    vim.notify("i18n-status doctor: no running job", vim.log.levels.INFO)
  end
  return cancelled
end

return M
