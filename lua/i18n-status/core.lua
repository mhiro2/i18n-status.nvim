---@class I18nStatusCore
local M = {}

local filetypes = require("i18n-status.filetypes")
local resources = require("i18n-status.resources")
local render = require("i18n-status.render")
local resolve = require("i18n-status.resolve")
local scan = require("i18n-status.scan")
local state = require("i18n-status.state")
local window = require("i18n-status.window")
local uv = vim.uv
local refresh_seq_by_buf = {}
-- Bumped whenever translation resources may have changed, so rendered results computed from an
-- older index are no longer considered current.
local resource_generation = 0

---@param bufnr integer
---@return boolean
local function buf_ready(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

---@param timer uv_timer_t|nil
local function close_timer(timer)
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

---@param bufnr integer
---@return boolean
function M.should_refresh(bufnr)
  if not buf_ready(bufnr) then
    return false
  end
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" and buftype ~= "nofile" then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if filetypes.is_source_filetype(ft) then
    return true
  end
  if filetypes.is_resource_filetype(ft) then
    return resources.resource_info_for_buf(bufnr) ~= nil
  end
  return false
end

---@class I18nStatusRefreshView
---@field range { start_line: integer, end_line: integer }|nil Scan range when only visible lines render
---@field top integer|nil
---@field bottom integer|nil

---@param bufnr integer
---@param config I18nStatusConfig
---@return I18nStatusRefreshView
local function current_view(bufnr, config)
  if not config.inline.visible_only then
    return {}
  end
  local top, bottom = window.visible_range(bufnr)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  top = math.max(1, math.min(top, line_count))
  bottom = math.max(top, math.min(bottom, line_count))
  return {
    range = { start_line = top - 1, end_line = bottom - 1 },
    top = top,
    bottom = bottom,
  }
end

---@param project I18nStatusProjectState
---@return string
local function language_generation(project)
  return string.format("%s\0%s", project.current_lang or "", project.primary_lang or "")
end

---Start a refresh request: newer requests and buffer edits make older results stale.
---@param bufnr integer
---@param config I18nStatusConfig
---@return { seq: integer, tick: integer, resources: integer, view: I18nStatusRefreshView }
local function begin_request(bufnr, config)
  local seq = (refresh_seq_by_buf[bufnr] or 0) + 1
  refresh_seq_by_buf[bufnr] = seq
  return {
    seq = seq,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    resources = resource_generation,
    view = current_view(bufnr, config),
  }
end

---@param bufnr integer
---@param request { seq: integer, tick: integer }
---@return boolean
local function request_stale(bufnr, request)
  return refresh_seq_by_buf[bufnr] ~= request.seq
    or not buf_ready(bufnr)
    or vim.api.nvim_buf_get_changedtick(bufnr) ~= request.tick
end

---Render a result and record the buffer state it reflects.
---@param bufnr integer
---@param request { tick: integer, resources: integer, view: I18nStatusRefreshView }
---@param project I18nStatusProjectState
---@param items table[]
---@param resolved table[]
---@param config I18nStatusConfig
local function apply_result(bufnr, request, project, items, resolved, config)
  render.apply(bufnr, items, resolved, config)
  state.rendered_by_buf[bufnr] = {
    tick = request.tick,
    resources = request.resources,
    language = language_generation(project),
    top = request.view.top,
    bottom = request.view.bottom,
  }
end

---@param bufnr integer
---@param config I18nStatusConfig
---@return boolean
local function rendered_is_current(bufnr, config)
  local rendered = state.rendered_by_buf[bufnr]
  if not rendered or not state.inline_by_buf[bufnr] then
    return false
  end
  if rendered.tick ~= vim.api.nvim_buf_get_changedtick(bufnr) or rendered.resources ~= resource_generation then
    return false
  end
  local project = state.project_for_key(state.buf_project[bufnr])
  if rendered.language ~= language_generation(project) then
    return false
  end
  local view = current_view(bufnr, config)
  return rendered.top == view.top and rendered.bottom == view.bottom
end

---@param bufnr integer
---@param config I18nStatusConfig
local function refresh_now_async(bufnr, config)
  if not buf_ready(bufnr) then
    return
  end

  local request = begin_request(bufnr, config)
  local start_dir = resources.start_dir(bufnr)
  local fallback_ns = resources.fallback_namespace(start_dir)

  resources.ensure_index_async(start_dir, function(cache, index_err)
    -- Keep the last rendered state when indexing fails; a later refresh retries.
    if index_err or request_stale(bufnr, request) then
      return
    end
    local project = state.set_languages(cache.key, cache.languages)
    state.set_buf_project(bufnr, cache.key)
    local language = language_generation(project)

    local info = resources.resource_info(start_dir, vim.api.nvim_buf_get_name(bufnr))

    local function on_items(items)
      if request_stale(bufnr, request) then
        return
      end
      resolve.compute_async(items, project, cache.index, function(resolved)
        if request_stale(bufnr, request) or language_generation(project) ~= language then
          return
        end
        apply_result(bufnr, request, project, items, resolved, config)
      end)
    end

    if info then
      scan.extract_resource_async(bufnr, info, { range = request.view.range }, on_items)
      return
    end

    local ft = vim.bo[bufnr].filetype
    if not filetypes.is_source_filetype(ft) then
      return
    end
    scan.extract_async(bufnr, {
      fallback_namespace = fallback_ns,
      range = request.view.range,
    }, on_items)
  end)
end

---@param bufnr integer
---@param config I18nStatusConfig
function M.refresh_now(bufnr, config)
  if not buf_ready(bufnr) then
    return
  end
  -- Supersede pending and in-flight asynchronous refreshes of this buffer.
  close_timer(state.timers[bufnr])
  state.timers[bufnr] = nil
  local request = begin_request(bufnr, config)

  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local project = state.set_languages(cache.key, cache.languages)
  state.set_buf_project(bufnr, cache.key)
  local fallback_ns = resources.fallback_namespace(start_dir)

  local info = resources.resource_info(start_dir, vim.api.nvim_buf_get_name(bufnr))

  local items = {}
  if info then
    items = scan.extract_resource(bufnr, info, { range = request.view.range })
  else
    local ft = vim.bo[bufnr].filetype
    if not filetypes.is_source_filetype(ft) then
      return
    end
    items = scan.extract(bufnr, {
      fallback_namespace = fallback_ns,
      range = request.view.range,
    })
  end

  local resolved = resolve.compute(items, project, cache.index)
  apply_result(bufnr, request, project, items, resolved, config)
end

---Re-render every refreshable buffer after translation resources changed.
---@param config I18nStatusConfig
function M.refresh_all(config)
  resource_generation = resource_generation + 1
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if M.should_refresh(buf) then
      refresh_now_async(buf, config)
    end
  end
end

---Re-render every buffer that belongs to a project, e.g. after its display language changed.
---@param project_key string|nil
---@param config I18nStatusConfig
---@param opts? { except?: integer }
function M.refresh_project(project_key, config, opts)
  if not project_key then
    return
  end
  local except = opts and opts.except
  for buf, key in pairs(state.buf_project) do
    if key == project_key and buf ~= except and M.should_refresh(buf) then
      refresh_now_async(buf, config)
    end
  end
end

---@param bufnr integer
---@param config I18nStatusConfig
---@param debounce_ms integer|nil
---@param opts table|nil { force: boolean }
function M.refresh(bufnr, config, debounce_ms, opts)
  if not buf_ready(bufnr) then
    return
  end
  local force = opts and opts.force == true
  if not force and rendered_is_current(bufnr, config) then
    -- The display already matches; drop pending or in-flight requests for another state (e.g. a
    -- range scrolled past) so they cannot replace it.
    close_timer(state.timers[bufnr])
    state.timers[bufnr] = nil
    refresh_seq_by_buf[bufnr] = (refresh_seq_by_buf[bufnr] or 0) + 1
    return
  end
  local delay = debounce_ms
  if delay == nil then
    delay = config.inline.debounce_ms
  end
  if delay == nil then
    delay = 80
  end
  if delay <= 0 then
    return M.refresh_now(bufnr, config)
  end
  close_timer(state.timers[bufnr])
  state.timers[bufnr] = nil
  local timer = uv.new_timer()
  state.timers[bufnr] = timer
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if not buf_ready(bufnr) then
        return
      end
      refresh_now_async(bufnr, config)
    end)
  )
end

---Refresh a buffer whose visible range may have changed. Only buffers that have started a refresh
---are considered, so scrolling unrelated buffers stays free of resource lookups.
---@param bufnr integer
---@param config I18nStatusConfig
function M.refresh_view(bufnr, config)
  if not refresh_seq_by_buf[bufnr] or not buf_ready(bufnr) then
    return
  end
  M.refresh(bufnr, config)
end

---@param bufnr integer
function M.cleanup_buf(bufnr)
  refresh_seq_by_buf[bufnr] = nil
  close_timer(state.timers[bufnr])
  state.timers[bufnr] = nil

  -- Decrement watcher reference count
  local watcher_key = state.buf_watcher_keys[bufnr]
  if watcher_key then
    resources.stop_watch_for_buffer(watcher_key)
    state.buf_watcher_keys[bufnr] = nil
  end

  state.clear_buf(bufnr)
end

return M
