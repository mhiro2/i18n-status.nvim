---@class I18nStatusExtractReview
local M = {}

local extract_review_apply = require("i18n-status.extract_review_apply")
local review_buffers = require("i18n-status.review_buffers")
local review_filters = require("i18n-status.review_filters")
local review_shared_ui = require("i18n-status.review_shared_ui")

local EXTRACT_REVIEW_NS = vim.api.nvim_create_namespace("i18n-status-extract-review")
local EXTRACT_REVIEW_TRACK_NS = vim.api.nvim_create_namespace("i18n-status-extract-review-track")

---@class I18nStatusExtractCandidate
---@field id integer
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field text string
---@field namespace string
---@field t_func string
---@field proposed_key string
---@field new_key string
---@field mode 'new'|'reuse'
---@field selected boolean
---@field status 'ready'|'conflict_existing'|'invalid_key'|'error'
---@field error string|nil
---@field mark_id integer|nil

---@class I18nStatusExtractApplySummary
---@field applied integer
---@field skipped integer
---@field failed integer

---@class I18nStatusExtractReviewCtx
---@field source_buf integer
---@field source_win integer|nil
---@field list_buf integer
---@field resource_buf integer
---@field source_preview_buf integer
---@field list_win integer
---@field resource_win integer
---@field source_preview_win integer
---@field cfg I18nStatusConfig
---@field candidates I18nStatusExtractCandidate[]
---@field view_candidates I18nStatusExtractCandidate[]
---@field line_to_candidate table<integer, integer>
---@field existing_keys table<string, boolean>
---@field languages string[]
---@field primary_lang string
---@field start_dir string
---@field list_width integer
---@field augroup integer
---@field status_message string|nil
---@field filter_query string|nil
---@field closing boolean|nil
---@field statuses_dirty boolean
---@field help_win integer|nil
---@field help_buf integer|nil
---@field track_namespace integer
---@field current_candidate fun(ctx: I18nStatusExtractReviewCtx): I18nStatusExtractCandidate|nil
---@field _source_preview_ts_started boolean|nil

---@class I18nStatusExtractReviewOpenOpts
---@field bufnr integer
---@field cfg I18nStatusConfig
---@field candidates I18nStatusExtractCandidate[]
---@field existing_keys table<string, boolean>
---@field languages string[]
---@field primary_lang string
---@field start_dir string

---@type table<integer, I18nStatusExtractReviewCtx>
local review_state = {}

local KEYMAP_HELP = {
  { keys = "j / k", desc = "Move cursor" },
  { keys = "Space", desc = "Toggle selection" },
  { keys = "/", desc = "Filter candidates" },
  { keys = "a / A", desc = "Select all / none" },
  { keys = "r", desc = "Edit key" },
  { keys = "u / U", desc = "Reuse existing / new key mode" },
  { keys = "<CR>", desc = "Apply selected candidates" },
  { keys = "q / <Esc>", desc = "Close extract review" },
  { keys = "?", desc = "Toggle keymap help" },
}

---@type fun(ctx: I18nStatusExtractReviewCtx)
local close_keymap_help

---@param ctx I18nStatusExtractReviewCtx
close_keymap_help = function(ctx)
  review_shared_ui.close_help_window(ctx)
end

---@param ctx I18nStatusExtractReviewCtx
local function toggle_keymap_help(ctx)
  review_shared_ui.toggle_help_window(ctx, {
    title = "I18nExtract keymaps",
    keymaps = KEYMAP_HELP,
    filetype = "i18n-status-extract-review-help",
  })
end

---@param line string
---@param display_col integer
---@return integer
local function display_col_to_byte_col(line, display_col)
  if line == "" then
    return 0
  end
  local target = math.max(0, display_col or 0)
  if target == 0 then
    return 0
  end
  local total_width = vim.fn.strdisplaywidth(line)
  if target >= total_width then
    return #line
  end

  local byte_col = 0
  local width = 0
  local line_len = #line
  while byte_col < line_len do
    local first_byte = line:byte(byte_col + 1) or 0
    local char_len = 1
    if first_byte >= 0xF0 then
      char_len = 4
    elseif first_byte >= 0xE0 then
      char_len = 3
    elseif first_byte >= 0xC2 then
      char_len = 2
    end
    local next_byte_col = math.min(byte_col + char_len, line_len)
    local ch = line:sub(byte_col + 1, next_byte_col)
    local ch_width = vim.api.nvim_strwidth(ch)
    if width + ch_width > target then
      return byte_col
    end
    width = width + ch_width
    byte_col = next_byte_col
    if width == target then
      return byte_col
    end
  end

  return line_len
end

---@param bufnr integer
---@param candidate I18nStatusExtractCandidate
---@return integer start_col
---@return integer end_col
local function byte_columns_for_candidate(bufnr, candidate)
  local start_line = vim.api.nvim_buf_get_lines(bufnr, candidate.lnum, candidate.lnum + 1, false)[1] or ""
  local end_line = start_line
  if candidate.end_lnum ~= candidate.lnum then
    end_line = vim.api.nvim_buf_get_lines(bufnr, candidate.end_lnum, candidate.end_lnum + 1, false)[1] or ""
  end

  local start_col = display_col_to_byte_col(start_line, candidate.col)
  local end_col = display_col_to_byte_col(end_line, candidate.end_col)
  if candidate.end_lnum == candidate.lnum and end_col < start_col then
    end_col = start_col
  end

  return start_col, end_col
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
local function create_track_mark(ctx, candidate)
  local bufnr = ctx.source_buf
  if not vim.api.nvim_buf_is_valid(bufnr) then
    candidate.mark_id = nil
    candidate.status = "error"
    candidate.error = "buffer is invalid"
    return
  end

  local start_col, end_col = byte_columns_for_candidate(bufnr, candidate)
  candidate.mark_id = vim.api.nvim_buf_set_extmark(bufnr, EXTRACT_REVIEW_TRACK_NS, candidate.lnum, start_col, {
    end_row = candidate.end_lnum,
    end_col = end_col,
  })
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@return integer|nil
---@return integer|nil
---@return integer|nil
---@return integer|nil
local function candidate_range(ctx, candidate)
  if not candidate.mark_id then
    return nil, nil, nil, nil
  end
  local mark =
    vim.api.nvim_buf_get_extmark_by_id(ctx.source_buf, EXTRACT_REVIEW_TRACK_NS, candidate.mark_id, { details = true })
  if #mark < 3 then
    return nil, nil, nil, nil
  end
  local details = mark[3]
  if type(details) ~= "table" or type(details.end_row) ~= "number" or type(details.end_col) ~= "number" then
    return nil, nil, nil, nil
  end
  return mark[1], mark[2], details.end_row, details.end_col
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@return string
local function candidate_text(ctx, candidate)
  local srow, scol, erow, ecol = candidate_range(ctx, candidate)
  if not srow then
    return candidate.text or ""
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_text, ctx.source_buf, srow, scol, erow, ecol, {})
  if not ok then
    return candidate.text or ""
  end
  return table.concat(lines, "\n")
end

---@param ctx I18nStatusExtractReviewCtx
---@return I18nStatusExtractCandidate|nil
local function current_candidate(ctx)
  if not ctx or not vim.api.nvim_win_is_valid(ctx.list_win) then
    return nil
  end
  local fallback = nil
  if ctx.view_candidates and #ctx.view_candidates > 0 then
    fallback = ctx.view_candidates[1]
  elseif not review_filters.normalize_query(ctx.filter_query, { lowercase = true }) then
    fallback = ctx.candidates[1]
  end
  local cursor = vim.api.nvim_win_get_cursor(ctx.list_win)
  local line = cursor[1]
  local id = ctx.line_to_candidate[line]
  if not id then
    return fallback
  end
  for _, candidate in ipairs(ctx.view_candidates or ctx.candidates) do
    if candidate.id == id then
      return candidate
    end
  end
  return fallback
end

---@param ctx I18nStatusExtractReviewCtx
---@param preferred_candidate_id integer|nil
local function refresh_views(ctx, preferred_candidate_id)
  ctx.statuses_dirty = true
  if ctx.statuses_dirty then
    extract_review_apply.refresh_candidate_statuses(ctx.candidates, ctx.existing_keys)
    ctx.statuses_dirty = false
  end
  review_buffers.render_extract_list(ctx, EXTRACT_REVIEW_NS, preferred_candidate_id)
  review_buffers.render_extract_resource_preview(ctx, EXTRACT_REVIEW_NS, {
    current_candidate = current_candidate,
    candidate_text = candidate_text,
  })
  review_buffers.render_extract_source_preview(ctx, EXTRACT_REVIEW_NS, {
    current_candidate = current_candidate,
    candidate_text = candidate_text,
  })
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
local function edit_candidate_key(ctx, candidate)
  vim.ui.input({
    prompt = "Extract key: ",
    default = candidate.proposed_key,
  }, function(input)
    if input == nil then
      return
    end
    candidate.mode = "new"
    candidate.selected = true
    candidate.proposed_key = vim.trim(input)
    refresh_views(ctx, candidate.id)
  end)
end

---@param ctx I18nStatusExtractReviewCtx
local function prompt_filter(ctx)
  review_shared_ui.prompt_filter(ctx, {
    prompt = "Extract filter (/ to clear): ",
    default = ctx.filter_query or "",
    lowercase = true,
    on_confirm = function(current, normalized)
      current.filter_query = normalized
      refresh_views(current, nil)
    end,
  })
end

---@param ctx I18nStatusExtractReviewCtx
local function toggle_current_selection(ctx)
  local candidate = current_candidate(ctx)
  if not candidate then
    return
  end
  candidate.selected = not candidate.selected
  refresh_views(ctx, candidate.id)
end

---@param ctx I18nStatusExtractReviewCtx
local function select_all(ctx)
  for _, candidate in ipairs(ctx.candidates) do
    candidate.selected = true
  end
  refresh_views(ctx, current_candidate(ctx) and current_candidate(ctx).id or nil)
end

---@param ctx I18nStatusExtractReviewCtx
local function select_none(ctx)
  for _, candidate in ipairs(ctx.candidates) do
    candidate.selected = false
  end
  refresh_views(ctx, current_candidate(ctx) and current_candidate(ctx).id or nil)
end

---@param ctx I18nStatusExtractReviewCtx
local function choose_reuse_mode(ctx)
  local candidate = current_candidate(ctx)
  if not candidate then
    return
  end

  if not ctx.existing_keys[candidate.proposed_key] then
    vim.notify("i18n-status extract: no existing key to reuse for " .. candidate.proposed_key, vim.log.levels.INFO)
    return
  end

  if candidate.status ~= "conflict_existing" or candidate.mode ~= "new" then
    candidate.mode = "reuse"
    candidate.selected = true
    refresh_views(ctx, candidate.id)
    return
  end

  local options = {
    "Reuse existing key (Recommended)",
    "Edit key",
    "Skip",
  }

  vim.ui.select(options, {
    prompt = "Resolve key conflict: " .. candidate.proposed_key,
  }, function(choice)
    if choice == options[1] then
      candidate.mode = "reuse"
      candidate.selected = true
      refresh_views(ctx, candidate.id)
      return
    end
    if choice == options[2] then
      edit_candidate_key(ctx, candidate)
      return
    end
    if choice == options[3] then
      candidate.selected = false
      refresh_views(ctx, candidate.id)
    end
  end)
end

---@param ctx I18nStatusExtractReviewCtx
local function choose_new_mode(ctx)
  local candidate = current_candidate(ctx)
  if not candidate then
    return
  end
  candidate.mode = "new"
  candidate.selected = true
  candidate.proposed_key = candidate.new_key or candidate.proposed_key
  refresh_views(ctx, candidate.id)
end

---@type fun(ctx: I18nStatusExtractReviewCtx, cancelled: boolean)
local close_review

local function apply_selected(ctx)
  extract_review_apply.apply_selected(ctx, {
    candidate_range = candidate_range,
    candidate_text = candidate_text,
    close_review = close_review,
    refresh_views = refresh_views,
  })
end

---@param ctx I18nStatusExtractReviewCtx
---@param cancelled boolean
close_review = function(ctx, cancelled)
  if not ctx or ctx.closing then
    return
  end
  ctx.closing = true

  if vim.api.nvim_buf_is_valid(ctx.source_buf) then
    vim.api.nvim_buf_clear_namespace(ctx.source_buf, EXTRACT_REVIEW_TRACK_NS, 0, -1)
  end

  local source_win = ctx.source_win
  local list_buf = ctx.list_buf
  local resource_buf = ctx.resource_buf
  local source_preview_buf = ctx.source_preview_buf
  local list_win = ctx.list_win
  local resource_win = ctx.resource_win
  local source_preview_win = ctx.source_preview_win

  close_keymap_help(ctx)

  review_state[list_buf] = nil
  review_state[resource_buf] = nil
  review_state[source_preview_buf] = nil

  pcall(vim.api.nvim_del_augroup_by_id, ctx.augroup)

  if vim.api.nvim_win_is_valid(source_preview_win) then
    pcall(vim.api.nvim_win_close, source_preview_win, true)
  end
  if vim.api.nvim_win_is_valid(resource_win) then
    pcall(vim.api.nvim_win_close, resource_win, true)
  end
  if vim.api.nvim_win_is_valid(list_win) then
    pcall(vim.api.nvim_win_close, list_win, true)
  end
  if source_win and vim.api.nvim_win_is_valid(source_win) then
    pcall(vim.api.nvim_set_current_win, source_win)
  end

  if vim.api.nvim_buf_is_valid(list_buf) then
    pcall(vim.api.nvim_buf_delete, list_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(resource_buf) then
    pcall(vim.api.nvim_buf_delete, resource_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(source_preview_buf) then
    pcall(vim.api.nvim_buf_delete, source_preview_buf, { force = true })
  end

  if cancelled then
    vim.notify("i18n-status extract: cancelled", vim.log.levels.INFO)
  end
end

---@param buf integer
local function set_list_keymaps(buf)
  review_shared_ui.bind_context_keymaps({
    bufnr = buf,
    state = review_state,
    bindings = {
      {
        lhs = "q",
        handler = function(ctx)
          close_review(ctx, true)
        end,
      },
      {
        lhs = "<Esc>",
        handler = function(ctx)
          close_review(ctx, true)
        end,
      },
      { lhs = "<Space>", handler = toggle_current_selection },
      { lhs = "a", handler = select_all },
      { lhs = "A", handler = select_none },
      {
        lhs = "r",
        handler = function(ctx)
          local candidate = current_candidate(ctx)
          if candidate then
            edit_candidate_key(ctx, candidate)
          end
        end,
      },
      { lhs = "/", handler = prompt_filter },
      { lhs = "u", handler = choose_reuse_mode },
      { lhs = "U", handler = choose_new_mode },
      { lhs = "<CR>", handler = apply_selected },
      { lhs = "?", handler = toggle_keymap_help },
    },
  })
end

---@param bufnr integer
---@return boolean
local function is_open_for_buffer(bufnr)
  for _, ctx in pairs(review_state) do
    if ctx and ctx.source_buf == bufnr and ctx.list_win and vim.api.nvim_win_is_valid(ctx.list_win) then
      return true
    end
  end
  return false
end

---@param opts I18nStatusExtractReviewOpenOpts
---@return I18nStatusExtractReviewCtx|nil
function M.open(opts)
  if not opts or not opts.bufnr or not vim.api.nvim_buf_is_valid(opts.bufnr) then
    return nil
  end
  if is_open_for_buffer(opts.bufnr) then
    vim.notify("i18n-status extract: review UI is already open", vim.log.levels.WARN)
    return nil
  end
  if not opts.candidates or #opts.candidates == 0 then
    return nil
  end

  local source_win = vim.api.nvim_get_current_win()
  local layout = review_buffers.open_extract_layout(opts.cfg)
  local list_buf = layout.list_buf
  local resource_buf = layout.resource_buf
  local source_preview_buf = layout.source_preview_buf
  local list_win = layout.list_win
  local resource_win = layout.resource_win
  local source_preview_win = layout.source_preview_win
  local list_width = layout.list_width

  local augroup = vim.api.nvim_create_augroup("i18n-status-extract-review-" .. list_buf, { clear = true })

  local ctx = {
    source_buf = opts.bufnr,
    source_win = source_win,
    list_buf = list_buf,
    resource_buf = resource_buf,
    source_preview_buf = source_preview_buf,
    list_win = list_win,
    resource_win = resource_win,
    source_preview_win = source_preview_win,
    cfg = opts.cfg,
    candidates = vim.deepcopy(opts.candidates),
    view_candidates = {},
    line_to_candidate = {},
    existing_keys = vim.deepcopy(opts.existing_keys or {}),
    languages = vim.deepcopy(opts.languages or {}),
    primary_lang = opts.primary_lang,
    start_dir = opts.start_dir,
    list_width = list_width,
    augroup = augroup,
    status_message = nil,
    filter_query = nil,
    closing = false,
    statuses_dirty = true,
    help_win = nil,
    help_buf = nil,
    track_namespace = EXTRACT_REVIEW_TRACK_NS,
    current_candidate = current_candidate,
  }

  for _, candidate in ipairs(ctx.candidates) do
    create_track_mark(ctx, candidate)
  end

  review_state[list_buf] = ctx
  review_state[resource_buf] = ctx
  review_state[source_preview_buf] = ctx

  set_list_keymaps(list_buf)

  local function resolve_ctx()
    return review_state[list_buf] or review_state[resource_buf] or review_state[source_preview_buf]
  end

  local function handle_external_close(cancelled)
    local current = resolve_ctx()
    if not current or current.closing then
      return
    end
    close_review(current, cancelled)
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = list_buf,
    callback = function()
      local current = resolve_ctx()
      if not current or current.closing then
        return
      end
      review_buffers.render_extract_resource_preview(current, EXTRACT_REVIEW_NS, {
        current_candidate = current_candidate,
        candidate_text = candidate_text,
      })
      review_buffers.render_extract_source_preview(current, EXTRACT_REVIEW_NS, {
        current_candidate = current_candidate,
        candidate_text = candidate_text,
      })
    end,
  })
  for _, win_id in ipairs({ list_win, resource_win, source_preview_win }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(win_id),
      callback = function()
        handle_external_close(true)
      end,
    })
  end
  for _, buf_id in ipairs({ list_buf, resource_buf, source_preview_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = augroup,
      buffer = buf_id,
      callback = function()
        handle_external_close(true)
      end,
    })
  end

  refresh_views(ctx, ctx.candidates[1] and ctx.candidates[1].id or nil)
  vim.api.nvim_set_current_win(list_win)

  return ctx
end

M._test = {
  normalize_key_input = extract_review_apply.normalize_key_input,
  status_icon = review_buffers.extract_status_icon,
  refresh_candidate_statuses = function(candidates, existing_keys)
    extract_review_apply.refresh_candidate_statuses(candidates, existing_keys)
  end,
  applicable_candidates = function(candidates, existing_keys)
    local ctx = {
      candidates = candidates,
      existing_keys = existing_keys,
      statuses_dirty = true,
    }
    return extract_review_apply.applicable_candidates(ctx, candidates)
  end,
  build_apply_message = extract_review_apply.build_apply_message,
  set_reuse_mode = function(candidate)
    candidate.mode = "reuse"
  end,
  set_new_mode = function(candidate)
    candidate.mode = "new"
  end,
}

return M
