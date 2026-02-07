---@class I18nStatus
local M = {}

local config_mod = require("i18n-status.config")
local core = require("i18n-status.core")
local state = require("i18n-status.state")
local actions = require("i18n-status.actions")
local resources = require("i18n-status.resources")
local doctor = require("i18n-status.doctor")
local util = require("i18n-status.util")

local config = nil
local setup_done = false
local group = nil
local auto_hover_autocmd = nil
---@param cfg I18nStatusConfig
---@param bufnr integer|nil
---@param should_refresh boolean|nil
local function setup_watch(cfg, bufnr, should_refresh)
  if cfg.resource_watch and cfg.resource_watch.enabled ~= false then
    if should_refresh == false then
      return
    end
    if should_refresh == nil and (not bufnr or not core.should_refresh(bufnr)) then
      return
    end

    local start_dir = resources.start_dir(bufnr)
    local debounce_ms = cfg.resource_watch.debounce_ms
    local prev_key = state.buf_watcher_keys[bufnr]
    local next_key = resources.get_watcher_key(start_dir)

    -- Keep one reference per buffer. Only re-register when watcher key changes.
    if prev_key and prev_key ~= next_key then
      resources.stop_watch_for_buffer(prev_key)
      state.buf_watcher_keys[bufnr] = nil
    elseif prev_key and prev_key == next_key then
      return
    end

    -- Start watcher and record key for this buffer
    -- resources.start_watch handles reference counting internally
    local watcher_key = resources.start_watch(start_dir, function(event)
      -- Try incremental update if we have specific paths
      if event and event.paths and #event.paths > 0 and not event.needs_rebuild then
        local cache_key = resources.get_watcher_key(start_dir)
        if cache_key then
          local success, needs_rebuild = resources.apply_changes(cache_key, event.paths)
          if not success and needs_rebuild then
            -- Fall back to mark dirty for full rebuild
            resources.mark_dirty()
          end
        else
          resources.mark_dirty()
        end
      else
        resources.mark_dirty()
      end
      core.refresh_all(cfg)
    end, { debounce_ms = debounce_ms })

    if watcher_key then
      state.buf_watcher_keys[bufnr] = watcher_key
    end
  else
    resources.stop_watch()
  end
end

local function configure_auto_hover()
  if auto_hover_autocmd then
    pcall(vim.api.nvim_del_autocmd, auto_hover_autocmd)
    auto_hover_autocmd = nil
  end
  if not group or not config then
    return
  end
  if config.auto_hover and config.auto_hover.enabled then
    auto_hover_autocmd = vim.api.nvim_create_autocmd("CursorHold", {
      group = group,
      pattern = { "*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs", "*.mts", "*.cts" },
      callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        if not core.should_refresh(bufnr) then
          return
        end
        local item = actions.item_at_cursor(bufnr)
        if item then
          M.hover()
        end
      end,
    })
  end
end

---@return boolean true if Doctor is open (caller should return early)
local function guard_doctor_open()
  local review = require("i18n-status.review")
  if review.is_doctor_open() then
    vim.notify("i18n-status: language switch is disabled while I18nDoctor is open.", vim.log.levels.WARN)
    return true
  end
  return false
end

---@param bufnr integer
local function goto_definition(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if core.should_refresh(bufnr) and not state.inline_by_buf[bufnr] then
    core.refresh_now(bufnr, config)
  end

  local item = actions.item_at_cursor(bufnr)
  if item and actions.jump_to_definition(item) then
    return true
  end

  return false
end

---@param opts I18nStatusConfig|nil
function M.setup(opts)
  local need_refresh_all = false
  if not config then
    config = config_mod.setup(opts)
    state.init(config.primary_lang, {})
    need_refresh_all = true
  elseif opts ~= nil then
    local prev_primary = config.primary_lang
    local merged_opts = util.tbl_deep_merge(config, opts)
    config = config_mod.setup(merged_opts)
    if config.primary_lang ~= prev_primary then
      state.update_primary(config.primary_lang, prev_primary)
    end
    need_refresh_all = true
  end

  if not setup_done then
    group = vim.api.nvim_create_augroup("i18n-status", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(args)
        if args.event == "BufEnter" then
          if vim.bo[args.buf].filetype == "i18n-status-review" then
            return
          end
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(args.buf) then
              return
            end
            if vim.bo[args.buf].filetype == "i18n-status-review" then
              return
            end
            local should_refresh = core.should_refresh(args.buf)
            setup_watch(config, args.buf, should_refresh)
            if should_refresh then
              core.refresh(args.buf, config)
            end
          end)
          return
        end
        if core.should_refresh(args.buf) then
          -- Skip TextChanged/TextChangedI for JSON resource files;
          -- the file watcher handles those on save.
          if args.event == "TextChanged" or args.event == "TextChangedI" then
            local ft = vim.bo[args.buf].filetype
            if ft == "json" or ft == "jsonc" then
              return
            end
          end
          core.refresh(args.buf, config)
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      callback = function(args)
        core.cleanup_buf(args.buf)
      end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        resources.stop_watch()
      end,
    })

    setup_done = true
  end

  configure_auto_hover()

  local current_buf = vim.api.nvim_get_current_buf()
  setup_watch(config, current_buf, core.should_refresh(current_buf))

  if need_refresh_all then
    core.refresh_all(config)
  end
end

---@param bufnr integer
function M.attach(bufnr)
  if not setup_done then
    M.setup({})
  end
  if not core.should_refresh(bufnr) then
    return
  end
  core.refresh(bufnr, config, 0)
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

---@return I18nStatusConfig|nil
function M.get_config()
  return config
end

function M.lang_next()
  M.ensure_setup()
  if guard_doctor_open() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local _, key = state.project_for_buf(bufnr)
  state.cycle_next(key)
  core.refresh(bufnr, config, 0, { force = true })
end

function M.lang_prev()
  M.ensure_setup()
  if guard_doctor_open() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local _, key = state.project_for_buf(bufnr)
  state.cycle_prev(key)
  core.refresh(bufnr, config, 0, { force = true })
end

---@param lang string
function M.lang_set(lang)
  M.ensure_setup()
  if guard_doctor_open() then
    return
  end
  if not lang or lang == "" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local project, key = state.project_for_buf(bufnr)
  if not state.has_language(key, lang) then
    local available = project and project.languages or {}
    local msg = string.format("i18n-status: unknown language '%s'", lang)
    if available and #available > 0 then
      msg = msg .. string.format(" (available: %s)", table.concat(available, ", "))
    end
    vim.notify_once(msg, vim.log.levels.WARN)
    return
  end
  state.set_current(key, lang)
  core.refresh(bufnr, config, 0, { force = true })
end

---@param arg_lead string
---@param _cmdline string
---@param _cursor_pos integer
---@return string[]
function M.lang_complete(arg_lead, _cmdline, _cursor_pos)
  M.ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  local project = select(1, state.project_for_buf(bufnr))
  local languages = project.languages or {}
  if not arg_lead or arg_lead == "" then
    return languages
  end
  local matches = {}
  for _, lang in ipairs(languages) do
    if lang:sub(1, #arg_lead) == arg_lead then
      table.insert(matches, lang)
    end
  end
  return matches
end

---@param bufnr integer|nil
function M.goto_definition(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return goto_definition(bufnr)
end

function M.hover()
  M.ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  if core.should_refresh(bufnr) and not state.inline_by_buf[bufnr] then
    core.refresh_now(bufnr, config)
  end
  actions.hover(bufnr)
end

function M.doctor()
  M.ensure_setup()
  local review = require("i18n-status.review")
  if review.is_doctor_open() then
    vim.notify("i18n-status: I18nDoctor is already open.", vim.log.levels.WARN)
    return
  end
  doctor.run(vim.api.nvim_get_current_buf(), config)
end

function M.doctor_cancel()
  M.ensure_setup()
  doctor.cancel()
end

function M.refresh()
  M.ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  if core.should_refresh(bufnr) then
    core.refresh(bufnr, config, 0, { force = true })
    vim.notify("i18n-status: refreshed", vim.log.levels.INFO)
  else
    vim.notify("i18n-status: not a supported filetype", vim.log.levels.WARN)
  end
end

function M.add_key()
  M.ensure_setup()
  local review = require("i18n-status.review")
  review.add_key_command(config)
end

return M
