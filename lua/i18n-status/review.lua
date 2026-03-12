---@class I18nStatusReview
local M = {}

local resolve = require("i18n-status.resolve")
local state = require("i18n-status.state")
local review_buffers = require("i18n-status.review_buffers")
local review_filters = require("i18n-status.review_filters")
local review_sections = require("i18n-status.review_sections")
local review_ui = require("i18n-status.review_ui")
local review_actions_mod = require("i18n-status.review_actions")
local review_shared_ui = require("i18n-status.review_shared_ui")

local MODE_PROBLEMS = review_ui.MODE_PROBLEMS
local MODE_OVERVIEW = review_ui.MODE_OVERVIEW
local STATUS_SECTION_ORDER = review_ui.STATUS_SECTION_ORDER
local STATUS_SECTION_LABELS = review_ui.STATUS_SECTION_LABELS
local STATUS_SUMMARY_LABELS = review_ui.STATUS_SUMMARY_LABELS
local PROBLEMS_SECTION_ORDER = review_ui.PROBLEMS_SECTION_ORDER
local PROBLEMS_SECTION_LABELS = review_ui.PROBLEMS_SECTION_LABELS
local PROBLEMS_SUMMARY_LABELS = review_ui.PROBLEMS_SUMMARY_LABELS

---@class I18nStatusReviewSectionState
---@field expanded boolean
---@field count integer|nil

---@class I18nStatusReviewView
---@field all_items I18nStatusResolved[]|nil
---@field items I18nStatusResolved[]|nil
---@field section_items table<string, I18nStatusResolved[]>|nil
---@field section_state table<string, I18nStatusReviewSectionState>|nil
---@field section_order string[]|nil
---@field section_labels table<string, string>|nil
---@field summary_labels table<string, string>|nil
---@field dirty boolean|nil

---@class I18nStatusReviewCtx
---@field source_buf integer|nil Source buffer number
---@field source_win integer|nil Source window ID
---@field list_buf integer|nil List buffer number
---@field list_win integer|nil List window ID
---@field detail_buf integer|nil Detail buffer number
---@field detail_win integer|nil Detail window ID
---@field items I18nStatusResolved[]|nil All items
---@field view_items I18nStatusResolved[]|nil Items currently displayed
---@field detail_item I18nStatusResolved|nil Item shown in detail view
---@field selected_index integer|nil Currently selected index
---@field filter_query string|nil Current slash filter query
---@field sort_state string|nil Sort state
---@field config I18nStatusConfig|nil Plugin configuration snapshot
---@field cache I18nStatusCache|nil Resource cache
---@field primary_lang string|nil Primary language
---@field secondary_langs string[]|nil Secondary languages
---@field display_lang string|nil Display language for Doctor UI
---@field mode "problems"|"overview"|nil Doctor UI mode
---@field views table<string, I18nStatusReviewView>|nil Doctor UI views
---@field augroup integer|nil Autocmd group ID
---@field update_timer uv_timer_t|nil Update timer
---@field debounce_update function|nil Debounced update function
---@field pending_edit boolean|nil Edit in progress flag
---@field closing boolean|nil Closing in progress flag
---@field is_doctor_review boolean|nil Whether Doctor review UI is active
---@field issues I18nStatusDoctorIssue[]|nil Doctor issues
---@field project_key string|nil Project key
---@field list_width integer|nil List pane width
---@field section_items table<string, I18nStatusResolved[]>|nil
---@field section_state table<string, I18nStatusReviewSectionState>|nil
---@field section_order string[]|nil
---@field section_labels table<string, string>|nil
---@field summary_labels table<string, string>|nil
---@field line_to_item table<integer, I18nStatusResolved>|nil
---@field line_to_section table<integer, string>|nil
---@field fallback_ns string|nil
---@field ignore_patterns string[]|nil
---@field is_ignored fun(key: string): boolean|nil
---@field items_by_buf table<integer, I18nStatusScanItem[]>|nil
---@field project_keys table<string, boolean>|nil
---@field start_dir string|nil
---@field buffers integer[]|nil
---@field help_win integer|nil
---@field help_buf integer|nil
---@field toggle_help fun(self: I18nStatusReviewCtx)|nil

---@type table<integer, I18nStatusReviewCtx>
local review_state = {}
local REVIEW_NS = vim.api.nvim_create_namespace("i18n-status-review")

---Check if Doctor is currently open
---@return boolean
local function is_doctor_open()
  for buf, ctx in pairs(review_state) do
    if vim.api.nvim_buf_is_valid(buf) and ctx.is_doctor_review then
      return true
    end
  end
  return false
end

local KEYMAP_HELP = {
  { keys = "q, <Esc>", desc = "Close review UI" },
  { keys = "/", desc = "Filter keys" },
  { keys = "Space / Enter", desc = "Toggle section" },
  { keys = "e", desc = "Edit display locale" },
  { keys = "E", desc = "Edit selected locale" },
  { keys = "r", desc = "Rename key" },
  { keys = "a", desc = "Add missing key" },
  { keys = "gd", desc = "Jump to definition file" },
  { keys = "Tab", desc = "Toggle Problems/Overview" },
  { keys = "?", desc = "Toggle keymap help" },
}

local close_keymap_help

---@param ctx table
local function close_review(ctx)
  if not ctx or ctx.closing then
    return
  end
  ctx.closing = true

  local save_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, err = pcall(function()
    -- Disable all autocmds during cleanup to prevent performance overhead
    close_keymap_help(ctx)

    local list_buf = ctx.list_buf
    local detail_buf = ctx.detail_buf

    -- Clean up review state first
    for _, b in ipairs({ list_buf, detail_buf }) do
      if b then
        review_state[b] = nil
      end
    end

    -- Delete augroup before hiding windows to prevent autocmds from firing
    if ctx.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, ctx.augroup)
      ctx.augroup = nil
    end

    -- Explicitly detach LSP clients to avoid slow cleanup
    for _, b in ipairs({ list_buf, detail_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        local clients = vim.lsp.get_clients({ bufnr = b })
        for _, client in ipairs(clients) do
          pcall(vim.lsp.buf_detach_client, b, client.id)
        end
      end
    end

    -- Decide whether we need to restore focus after closing
    local current_win = vim.api.nvim_get_current_win()
    local should_restore_focus = current_win == ctx.list_win or current_win == ctx.detail_win

    -- CRITICAL: Close windows BEFORE returning focus to source window
    -- This prevents race conditions where focus change interrupts window closing
    -- Close detail first to reduce the chance of it lingering
    for _, w in ipairs({ ctx.detail_win, ctx.list_win }) do
      if w and vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end

    -- Only after windows are closed, return focus to source window if needed
    if should_restore_focus and ctx.source_win and vim.api.nvim_win_is_valid(ctx.source_win) then
      pcall(vim.api.nvim_set_current_win, ctx.source_win)
    end

    -- Delete buffers synchronously (not deferred) for faster cleanup
    for _, b in ipairs({ list_buf, detail_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
      end
    end
  end)

  -- Always restore synchronously to avoid leaking "all" on failure paths.
  vim.o.eventignore = save_eventignore
  if not ok then
    ctx.closing = false
    vim.schedule(function()
      vim.notify("i18n-status review: close failed: " .. tostring(err), vim.log.levels.WARN)
    end)
  end
end

---@param ctx I18nStatusReviewCtx
close_keymap_help = function(ctx)
  review_shared_ui.close_help_window(ctx)
end

---@param ctx I18nStatusReviewCtx
local function toggle_keymap_help(ctx)
  review_shared_ui.toggle_help_window(ctx, {
    title = "I18nDoctor keymaps",
    keymaps = KEYMAP_HELP,
    filetype = "i18n-status-review-help",
  })
end

---@param ctx table
local function update_detail(ctx)
  local item = nil
  if ctx.list_win and vim.api.nvim_win_is_valid(ctx.list_win) then
    local row = vim.api.nvim_win_get_cursor(ctx.list_win)[1]

    -- Try to get item from line mapping
    item = ctx.line_to_item and ctx.line_to_item[row]

    -- If on section header, get first item from that section
    if not item and ctx.line_to_section and ctx.section_items then
      local status = ctx.line_to_section[row]
      if status then
        local section_items = ctx.section_items[status] or {}
        item = section_items[1]
      end
    end
  end

  if not item then
    item = ctx.view_items and ctx.view_items[1]
  end

  ctx.detail_item = item
  review_buffers.render_doctor_detail(ctx, REVIEW_NS)
end

-- Forward declarations
local refresh_doctor_items

---@param ctx table
---@param opts? { full?: boolean }
local function refresh_doctor_async(ctx, opts)
  local doctor = require("i18n-status.doctor")
  doctor.refresh(ctx, opts, function(issues)
    ctx.issues = issues
    refresh_doctor_items(ctx)
  end)
end

---@param keys string[]
---@param cache table
---@param primary_lang string
---@param display_lang string
---@return I18nStatusResolved[]
local function build_resolved_items(keys, cache, primary_lang, display_lang)
  if not keys or #keys == 0 then
    return {}
  end

  local project = {
    primary_lang = primary_lang,
    current_lang = display_lang,
    languages = cache.languages or {},
  }

  local items = {}
  for _, key in ipairs(keys) do
    table.insert(items, {
      key = key,
      raw = key:match("^[^:]+:(.+)$") or key,
      namespace = key:match("^(.-):") or "",
      fallback = false,
    })
  end

  return resolve.compute(items, project, cache.index)
end

---@param issues I18nStatusDoctorIssue[]
---@param cache table
---@param primary_lang string
---@return I18nStatusResolved[]
local function aggregate_issues_by_key(issues, cache, primary_lang, display_lang)
  local keys_map = {}
  local unused_keys = {}

  -- Collect all keys from issues
  for _, issue in ipairs(issues) do
    if issue.key then
      keys_map[issue.key] = true
      if issue.kind == "unused" then
        unused_keys[issue.key] = true
      end
    end
  end

  -- Convert to array and sort
  local keys = {}
  for key, _ in pairs(keys_map) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local items = build_resolved_items(keys, cache, primary_lang, display_lang)
  for _, item in ipairs(items) do
    if unused_keys[item.key] then
      item.unused = true
    end
  end
  return items
end

---@param ctx table
---@return string[]
local function collect_all_keys(ctx)
  local keys_map = {}
  if ctx.project_keys then
    for key in pairs(ctx.project_keys) do
      if not ctx.is_ignored or not ctx.is_ignored(key) then
        keys_map[key] = true
      end
    end
  end
  if ctx.cache and ctx.cache.index then
    for _, entries in pairs(ctx.cache.index) do
      for key, _ in pairs(entries) do
        if key ~= "__error__" then
          if not ctx.is_ignored or not ctx.is_ignored(key) then
            keys_map[key] = true
          end
        end
      end
    end
  end

  local keys = {}
  for key in pairs(keys_map) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

local action_handlers

---@return {edit_focus: fun(ctx: I18nStatusReviewCtx), edit_locale_select: fun(ctx: I18nStatusReviewCtx), rename_item: fun(ctx: I18nStatusReviewCtx), add_key: fun(ctx: I18nStatusReviewCtx), jump_to_definition: fun(ctx: I18nStatusReviewCtx)}
local function get_action_handlers()
  if action_handlers then
    return action_handlers
  end
  action_handlers = review_actions_mod.new({
    refresh_doctor_async = refresh_doctor_async,
    close_review = close_review,
    create_float_win = review_ui.create_float_win,
    mode_overview = MODE_OVERVIEW,
  })
  return action_handlers
end

---Add a new key from command (I18nAddKey)
---@param cfg I18nStatusConfig Config
function M.add_key_command(cfg)
  review_actions_mod.add_key_command(cfg)
end

---@param view I18nStatusReviewView|nil
---@param mode "problems"|"overview"
---@param filter_query string|nil
local function rebuild_view_sections(view, mode, filter_query)
  review_sections.rebuild_view(view, mode, filter_query, {
    mode_overview = MODE_OVERVIEW,
    filter = review_filters.filter_items_by_key,
    group_overview = function(items)
      return review_sections.group_items_by_status(items, STATUS_SECTION_ORDER, "=")
    end,
    group_problems = function(items)
      return review_sections.group_problem_items(items, PROBLEMS_SECTION_ORDER, STATUS_SECTION_ORDER, "=")
    end,
  })
end

---@param ctx table
local function refresh_problems(ctx)
  local view = ctx.views and ctx.views[MODE_PROBLEMS]
  if not view then
    return
  end
  view.all_items = aggregate_issues_by_key(ctx.issues or {}, ctx.cache, ctx.primary_lang, ctx.display_lang)
  view.section_order = PROBLEMS_SECTION_ORDER
  view.section_labels = PROBLEMS_SECTION_LABELS
  view.summary_labels = PROBLEMS_SUMMARY_LABELS
  view.dirty = false
  rebuild_view_sections(view, MODE_PROBLEMS, ctx.filter_query)
end

---@param ctx table
local function refresh_overview(ctx)
  local view = ctx.views and ctx.views[MODE_OVERVIEW]
  if not view then
    return
  end
  if not view.dirty and view.all_items then
    return
  end
  local keys = collect_all_keys(ctx)
  view.all_items = build_resolved_items(keys, ctx.cache, ctx.primary_lang, ctx.display_lang)
  view.section_order = STATUS_SECTION_ORDER
  view.section_labels = STATUS_SECTION_LABELS
  view.summary_labels = STATUS_SUMMARY_LABELS
  view.dirty = false
  rebuild_view_sections(view, MODE_OVERVIEW, ctx.filter_query)
end

---@param ctx table
---@return table|nil
local function current_view(ctx)
  if not ctx.views then
    return nil
  end
  return ctx.views[ctx.mode or MODE_PROBLEMS] or ctx.views[MODE_PROBLEMS]
end

---@param ctx table
refresh_doctor_items = function(ctx)
  if not ctx.cache or not ctx.primary_lang or not ctx.views then
    return
  end

  refresh_problems(ctx)

  local overview = ctx.views[MODE_OVERVIEW]
  if overview then
    overview.dirty = true
  end

  if ctx.mode == MODE_OVERVIEW then
    refresh_overview(ctx)
  end

  local view = current_view(ctx)
  review_sections.apply_view(ctx, view)
  review_buffers.render_doctor_list(ctx, REVIEW_NS)
  update_detail(ctx)
end

---@param ctx table
local function toggle_mode(ctx)
  if not ctx.is_doctor_review or not ctx.views then
    return
  end
  if ctx.mode == MODE_PROBLEMS then
    ctx.mode = MODE_OVERVIEW
  else
    ctx.mode = MODE_PROBLEMS
  end
  if ctx.mode == MODE_OVERVIEW then
    refresh_overview(ctx)
  end
  local view = current_view(ctx)
  review_sections.apply_view(ctx, view)
  review_buffers.render_doctor_list(ctx, REVIEW_NS)
  update_detail(ctx)
end

---@param ctx I18nStatusReviewCtx
local function prompt_filter(ctx)
  review_shared_ui.prompt_filter(ctx, {
    prompt = "Filter keys (/): ",
    default = ctx.filter_query or "",
    skip = function(current)
      return current.closing == true
    end,
    on_confirm = function(current, normalized)
      current.filter_query = normalized

      local problems = current.views and current.views[MODE_PROBLEMS]
      if problems and problems.all_items then
        rebuild_view_sections(problems, MODE_PROBLEMS, current.filter_query)
      end

      local overview = current.views and current.views[MODE_OVERVIEW]
      if overview and overview.all_items then
        rebuild_view_sections(overview, MODE_OVERVIEW, current.filter_query)
      end

      local view = current_view(current)
      review_sections.apply_view(current, view)
      review_buffers.render_doctor_list(current, REVIEW_NS)
      update_detail(current)
    end,
  })
end

---Toggles section expansion/collapse
---@param ctx table
local function toggle_section(ctx)
  if not ctx.list_win or not vim.api.nvim_win_is_valid(ctx.list_win) then
    return
  end

  local row = vim.api.nvim_win_get_cursor(ctx.list_win)[1]
  local status = ctx.line_to_section and ctx.line_to_section[row]

  if not status then
    -- Not on a section header, do nothing
    return
  end

  local section_state = ctx.section_state and ctx.section_state[status]
  if section_state then
    section_state.expanded = not section_state.expanded
    review_buffers.render_doctor_list(ctx, REVIEW_NS)

    -- Keep cursor on same section header
    if vim.api.nvim_win_is_valid(ctx.list_win) and ctx.line_to_section then
      for line, sect in pairs(ctx.line_to_section) do
        if sect == status then
          pcall(vim.api.nvim_win_set_cursor, ctx.list_win, { line, 0 })
          break
        end
      end
    end

    -- Update detail pane
    update_detail(ctx)
  end
end

---@param buf integer
local function set_list_keymaps(buf)
  local actions = get_action_handlers()

  review_shared_ui.bind_context_keymaps({
    bufnr = buf,
    state = review_state,
    before = function(ctx, binding)
      -- Close help before actions except for explicit opt-out actions.
      if binding.close_help ~= false then
        close_keymap_help(ctx)
      end
      if binding.update ~= false then
        update_detail(ctx)
      end
    end,
    bindings = {
      { lhs = "q", handler = close_review, update = false, close_help = false },
      { lhs = "<Esc>", handler = close_review, update = false, close_help = false },
      { lhs = "e", handler = actions.edit_focus },
      { lhs = "E", handler = actions.edit_locale_select },
      { lhs = "r", handler = actions.rename_item },
      { lhs = "a", handler = actions.add_key },
      { lhs = "gd", handler = actions.jump_to_definition },
      { lhs = "<Tab>", handler = toggle_mode, update = false },
      { lhs = "/", handler = prompt_filter, update = false },
      { lhs = "<Space>", handler = toggle_section, update = true },
      { lhs = "<CR>", handler = toggle_section, update = true },
      { lhs = "?", handler = toggle_keymap_help, update = false, close_help = false },
    },
  })
end

---@param issues I18nStatusDoctorIssue[]
---@param ctx table from doctor
---@param config I18nStatusConfig
function M.open_doctor_results(issues, ctx, config)
  -- Save the current window to return to when closing
  local source_win = vim.api.nvim_get_current_win()
  local layout = review_buffers.open_doctor_layout(config, MODE_PROBLEMS, nil)
  local list_buf = layout.list_buf
  local detail_buf = layout.detail_buf
  local list_win = layout.list_win
  local detail_win = layout.detail_win
  local list_width = layout.list_width

  state.set_languages(ctx.cache.key, ctx.cache.languages)
  local project = state.project_for_key(ctx.cache.key)
  local primary = (project and project.primary_lang)
    or (config and config.primary_lang)
    or (ctx.cache.languages[1] or "")
  local display_lang = (project and project.current_lang) or primary
  local problems_all_items = aggregate_issues_by_key(issues, ctx.cache, primary, display_lang)
  local problems_items = review_filters.filter_items_by_key(problems_all_items, nil)
  local problems_section_items =
    review_sections.group_problem_items(problems_items, PROBLEMS_SECTION_ORDER, STATUS_SECTION_ORDER, "=")
  local problems_section_state = review_sections.new_section_state(PROBLEMS_SECTION_ORDER)
  local overview_section_state = review_sections.new_section_state(STATUS_SECTION_ORDER)
  local views = {
    [MODE_PROBLEMS] = {
      all_items = problems_all_items,
      items = problems_items,
      section_items = problems_section_items,
      section_state = problems_section_state,
      section_order = PROBLEMS_SECTION_ORDER,
      section_labels = PROBLEMS_SECTION_LABELS,
      summary_labels = PROBLEMS_SUMMARY_LABELS,
      dirty = false,
    },
    [MODE_OVERVIEW] = {
      all_items = nil,
      items = nil,
      section_items = nil,
      section_state = overview_section_state,
      section_order = STATUS_SECTION_ORDER,
      section_labels = STATUS_SECTION_LABELS,
      summary_labels = STATUS_SUMMARY_LABELS,
      dirty = true,
    },
  }

  local augroup = vim.api.nvim_create_augroup("i18n-status-review-" .. list_buf, { clear = true })

  local review_ctx = {
    source_buf = ctx.bufnr,
    source_win = source_win,
    mode = MODE_PROBLEMS,
    views = views,
    items = problems_items,
    view_items = problems_items,
    detail_item = problems_items[1],
    filter_query = nil,
    list_buf = list_buf,
    detail_buf = detail_buf,
    list_win = list_win,
    detail_win = detail_win,
    config = config,
    is_doctor_review = true,
    issues = issues,
    cache = ctx.cache,
    primary_lang = primary,
    display_lang = display_lang,
    augroup = augroup,
    project_key = ctx.cache.key,
    list_width = list_width,
    section_items = problems_section_items,
    section_state = problems_section_state,
    section_order = PROBLEMS_SECTION_ORDER,
    section_labels = PROBLEMS_SECTION_LABELS,
    summary_labels = PROBLEMS_SUMMARY_LABELS,
    line_to_item = {},
    line_to_section = {},
    -- Doctor context fields for refresh operations
    fallback_ns = ctx.fallback_ns,
    ignore_patterns = ctx.ignore_patterns,
    is_ignored = ctx.is_ignored,
    items_by_buf = ctx.items_by_buf,
    project_keys = ctx.project_keys,
    start_dir = ctx.start_dir,
    buffers = ctx.buffers,
  }

  function review_ctx:toggle_help()
    toggle_keymap_help(self)
  end

  review_state[list_buf] = review_ctx
  review_state[detail_buf] = review_ctx

  review_buffers.render_doctor_list(review_ctx, REVIEW_NS)
  review_buffers.render_doctor_detail(review_ctx, REVIEW_NS)

  set_list_keymaps(list_buf)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = list_buf,
    callback = function()
      local current = review_state[list_buf]
      -- Early exit if closing or invalid state to prevent wasted work
      if not current or current.closing then
        return
      end
      if not vim.api.nvim_win_is_valid(current.list_win) then
        return
      end
      update_detail(current)
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    callback = function()
      local current = review_state[list_buf]
      if current and vim.api.nvim_win_is_valid(current.list_win) then
        current.list_width = vim.api.nvim_win_get_width(current.list_win)
        review_buffers.update_review_winbar(current)
      end
    end,
  })

  vim.api.nvim_set_current_win(list_win)

  return review_ctx
end

---@return boolean
M.is_doctor_open = is_doctor_open

return M
