---@class I18nStatusCore
local M = {}

local scan = require("i18n-status.scan")
local resources = require("i18n-status.resources")
local resolve = require("i18n-status.resolve")
local render = require("i18n-status.render")
local state = require("i18n-status.state")
local util = require("i18n-status.util")
local uv = vim.uv or vim.loop

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
  if ft == "javascript" or ft == "typescript" or ft == "javascriptreact" or ft == "typescriptreact" then
    return true
  end
  if ft == "json" or ft == "jsonc" then
    return resources.resource_info_for_buf(bufnr) ~= nil
  end
  return false
end

---@param bufnr integer
---@param config I18nStatusConfig
function M.refresh_now(bufnr, config)
  if not buf_ready(bufnr) then
    return
  end
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local project = state.set_languages(cache.key, cache.languages)
  state.set_buf_project(bufnr, cache.key)
  local fallback_ns = resources.fallback_namespace(start_dir)
  local scan_opts = { fallback_namespace = fallback_ns }
  if config.inline.visible_only then
    local top, bottom = util.visible_range(bufnr)
    local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    top = math.max(1, math.min(top, line_count))
    bottom = math.max(top, math.min(bottom, line_count))
    scan_opts.range = {
      start_line = top - 1,
      end_line = bottom - 1,
    }
  end
  local info = resources.resource_info(start_dir, vim.api.nvim_buf_get_name(bufnr))
  local items
  if info then
    items = scan.extract_resource(bufnr, info, scan_opts)
  else
    items = scan.extract(bufnr, scan_opts)
  end
  local resolved = resolve.compute(items, project, cache.index)
  render.apply(bufnr, items, resolved, config)
  state.last_changedtick[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
end

---@param config I18nStatusConfig
function M.refresh_all(config)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if M.should_refresh(buf) then
      M.refresh_now(buf, config)
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
  if not force and state.inline_by_buf[bufnr] then
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    if state.last_changedtick[bufnr] == tick then
      return
    end
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
      M.refresh_now(bufnr, config)
    end)
  )
end

---@param bufnr integer
function M.cleanup_buf(bufnr)
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
