---@class I18nStatusExtractReview
local M = {}

local core = require("i18n-status.core")
local extract_diff = require("i18n-status.extract_diff")
local key_write = require("i18n-status.key_write")
local review_ui = require("i18n-status.review_ui")
local util = require("i18n-status.util")

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

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param decorations { line: integer, group: string, col_start?: integer, col_end?: integer }[]
local function apply_decorations(buf, decorations)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, EXTRACT_REVIEW_NS, 0, -1)
  for _, deco in ipairs(decorations or {}) do
    vim.api.nvim_buf_add_highlight(
      buf,
      EXTRACT_REVIEW_NS,
      deco.group,
      deco.line,
      deco.col_start or 0,
      deco.col_end or -1
    )
  end
end

---@param text string
---@param max_width integer
---@return string
local function preview_text(text, max_width)
  local normalized = vim.trim((text or ""):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " "))
  if normalized == "" then
    normalized = "<empty>"
  end
  local width = vim.fn.strdisplaywidth(normalized)
  local limit = math.max(8, max_width or 30)
  if width <= limit then
    return normalized
  end
  return vim.fn.strcharpart(normalized, 0, limit - 1) .. "…"
end

---@param query string|nil
---@return string|nil
local function normalize_filter_query(query)
  if type(query) ~= "string" then
    return nil
  end
  local trimmed = vim.trim(query)
  if trimmed == "" then
    return nil
  end
  return trimmed:lower()
end

---@param candidate I18nStatusExtractCandidate
---@param query string|nil
---@return boolean
local function candidate_matches_filter(candidate, query)
  if not query then
    return true
  end
  local key = (candidate.proposed_key or ""):lower()
  if key:find(query, 1, true) then
    return true
  end
  local text = (candidate.text or ""):lower()
  return text:find(query, 1, true) ~= nil
end

---@return string[]
local function build_keymap_help_lines()
  local title = "I18nExtract keymaps"
  local divider = string.rep("-", #title)
  local max_key = 0
  for _, entry in ipairs(KEYMAP_HELP) do
    max_key = math.max(max_key, vim.fn.strdisplaywidth(entry.keys))
  end
  local format = " %-" .. max_key .. "s  %s "
  local lines = { " " .. title .. " ", " " .. divider .. " " }
  for _, entry in ipairs(KEYMAP_HELP) do
    lines[#lines + 1] = string.format(format, entry.keys, entry.desc)
  end
  return lines
end

---@param ctx I18nStatusExtractReviewCtx
close_keymap_help = function(ctx)
  if not ctx then
    return
  end
  if ctx.help_win and vim.api.nvim_win_is_valid(ctx.help_win) then
    pcall(vim.api.nvim_win_close, ctx.help_win, true)
  end
  if ctx.help_buf and vim.api.nvim_buf_is_valid(ctx.help_buf) then
    pcall(vim.api.nvim_buf_delete, ctx.help_buf, { force = true })
  end
  ctx.help_win = nil
  ctx.help_buf = nil
end

---@param ctx I18nStatusExtractReviewCtx
local function open_keymap_help(ctx)
  close_keymap_help(ctx)
  local lines = build_keymap_help_lines()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local max_width = math.max(math.floor(vim.o.columns * 0.6), 20)
  local win_width = math.min(width + 4, max_width)
  win_width = math.max(win_width, 20)
  local max_height = math.max(math.floor(vim.o.lines * 0.5), #lines + 2)
  local win_height = math.min(#lines + 2, max_height)
  win_height = math.max(win_height, #lines)
  local total_lines = math.max(vim.o.lines, win_height)
  local total_cols = math.max(vim.o.columns, win_width)
  local row = math.max(math.floor((total_lines - win_height) / 2), 0)
  local col = math.max(math.floor((total_cols - win_width) / 2), 0)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "i18n-status-extract-review-help"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
    focusable = false,
    zindex = 100,
  })

  vim.wo[win].winhighlight = table.concat({
    "Normal:I18nStatusReviewDetailNormal",
    "NormalFloat:I18nStatusReviewDetailNormal",
    "FloatBorder:I18nStatusReviewBorder",
  }, ",")

  ctx.help_win = win
  ctx.help_buf = buf
end

---@param ctx I18nStatusExtractReviewCtx
local function toggle_keymap_help(ctx)
  if ctx.help_win and vim.api.nvim_win_is_valid(ctx.help_win) then
    close_keymap_help(ctx)
    return
  end
  open_keymap_help(ctx)
end

local split_key = util.split_i18n_key

---@param key string
---@param default_ns string
---@return string|nil
---@return string|nil
local function normalize_key_input(key, default_ns)
  if type(key) ~= "string" or vim.trim(key) == "" then
    return nil, "empty key"
  end
  local trimmed = vim.trim(key)
  local colon_pos = trimmed:find(":")
  local second_colon = colon_pos and trimmed:find(":", colon_pos + 1)
  if second_colon then
    return nil, "key can only contain one ':' separator"
  end

  local full_key = trimmed
  if not colon_pos then
    if not default_ns or default_ns == "" then
      return nil, "namespace is required"
    end
    full_key = default_ns .. ":" .. trimmed
  end

  local namespace, key_path = split_key(full_key)
  if not namespace or not key_path then
    return nil, "invalid key format"
  end
  if key_path:match("^%.") or key_path:match("%.$") or key_path:match("%.%.") then
    return nil, "invalid key path"
  end
  if not namespace:match("^[%w_%-%.]+$") then
    return nil, "invalid namespace format"
  end
  if not key_path:match("^[%w_%-%.]+$") then
    return nil, "invalid key path format"
  end
  return full_key, nil
end

---@param candidate I18nStatusExtractCandidate
---@param existing_keys table<string, boolean>
---@return string|nil normalized_key
local function refresh_candidate_status(candidate, existing_keys)
  local normalized, err = normalize_key_input(candidate.proposed_key, candidate.namespace)
  if not normalized then
    candidate.status = "invalid_key"
    candidate.error = err
    return nil
  end

  candidate.proposed_key = normalized
  if candidate.mode == "reuse" then
    if existing_keys[normalized] then
      candidate.status = "ready"
      candidate.error = nil
      return normalized
    end
    candidate.status = "error"
    candidate.error = "reuse target does not exist"
    return normalized
  end

  if existing_keys[normalized] then
    candidate.status = "conflict_existing"
    candidate.error = nil
    return normalized
  end

  candidate.status = "ready"
  candidate.error = nil
  return normalized
end

---@param candidates I18nStatusExtractCandidate[]
---@param existing_keys table<string, boolean>
local function refresh_candidate_statuses(candidates, existing_keys)
  local new_key_owner = {}
  for _, candidate in ipairs(candidates) do
    local normalized = refresh_candidate_status(candidate, existing_keys)
    if normalized and candidate.mode == "new" and candidate.status == "ready" then
      local owner = new_key_owner[normalized]
      if owner then
        candidate.status = "conflict_existing"
        candidate.error = "duplicate candidate key"
        if owner.status == "ready" then
          owner.status = "conflict_existing"
          owner.error = "duplicate candidate key"
        end
      else
        new_key_owner[normalized] = candidate
      end
    end
  end
end

---@param summary I18nStatusExtractApplySummary
---@return string
local function build_apply_message(summary)
  return string.format(
    "i18n-status extract: applied=%d skipped=%d failed=%d",
    summary.applied,
    summary.skipped,
    summary.failed
  )
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
---@param candidate_id integer|nil
local function focus_candidate_line(ctx, candidate_id)
  if not candidate_id or not vim.api.nvim_win_is_valid(ctx.list_win) then
    return
  end
  for line, id in pairs(ctx.line_to_candidate or {}) do
    if id == candidate_id then
      pcall(vim.api.nvim_win_set_cursor, ctx.list_win, { line, 0 })
      return
    end
  end
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
  elseif not normalize_filter_query(ctx.filter_query) then
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

---@param status string
---@return string
local function highlight_for_status(status)
  if status == "ready" then
    return "I18nStatusReviewStatusOk"
  end
  if status == "conflict_existing" then
    return "I18nStatusReviewStatusMismatch"
  end
  if status == "invalid_key" then
    return "I18nStatusReviewStatusMissing"
  end
  return "I18nStatusReviewStatusFallback"
end

---@param status string
---@return string
local function status_icon(status)
  if status == "ready" then
    return "✓"
  end
  if status == "conflict_existing" then
    return "⚠"
  end
  if status == "invalid_key" or status == "error" then
    return "✗"
  end
  return "?"
end

---@param ctx I18nStatusExtractReviewCtx
---@return table
local function status_counts(ctx)
  local counts = {
    total = #ctx.candidates,
    selected = 0,
    ready = 0,
    conflict = 0,
    invalid = 0,
    errors = 0,
  }

  for _, candidate in ipairs(ctx.candidates) do
    if candidate.selected then
      counts.selected = counts.selected + 1
    end
    if candidate.status == "ready" then
      counts.ready = counts.ready + 1
    elseif candidate.status == "conflict_existing" then
      counts.conflict = counts.conflict + 1
    elseif candidate.status == "invalid_key" then
      counts.invalid = counts.invalid + 1
    elseif candidate.status == "error" then
      counts.errors = counts.errors + 1
    end
  end

  return counts
end

---@param ctx I18nStatusExtractReviewCtx
---@param preferred_candidate_id integer|nil
local function render_list(ctx, preferred_candidate_id)
  if ctx.statuses_dirty then
    refresh_candidate_statuses(ctx.candidates, ctx.existing_keys)
    ctx.statuses_dirty = false
  end

  local lines = {}
  local decorations = {}
  ctx.line_to_candidate = {}
  ctx.view_candidates = {}
  local filter_query = normalize_filter_query(ctx.filter_query)
  for _, candidate in ipairs(ctx.candidates) do
    if candidate_matches_filter(candidate, filter_query) then
      ctx.view_candidates[#ctx.view_candidates + 1] = candidate
    end
  end

  local counts = status_counts(ctx)
  lines[#lines + 1] = string.format(
    "selected=%d/%d ready=%d conflict=%d invalid=%d error=%d",
    counts.selected,
    counts.total,
    counts.ready,
    counts.conflict,
    counts.invalid,
    counts.errors
  )
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewHeader" }

  if ctx.status_message and ctx.status_message ~= "" then
    lines[#lines + 1] = ctx.status_message
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  end
  if filter_query then
    lines[#lines + 1] = string.format("filter=/%s shown=%d/%d", ctx.filter_query, #ctx.view_candidates, #ctx.candidates)
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  end
  lines[#lines + 1] = ""

  -- Calculate column widths dynamically
  local checkbox_w = 4 -- "[x] "
  local padding = 2
  local status_mode_w = 8 -- "✓ new " + padding
  local content_w = math.max(20, ctx.list_width - checkbox_w - status_mode_w - padding)
  local text_w = math.max(8, math.floor(content_w * 0.40))
  local key_w = math.max(8, content_w - text_w)

  -- Table header
  local header_line = string.format("    %-" .. text_w .. "s %-" .. key_w .. "s %s", "Text", "Key", "Stat")
  lines[#lines + 1] = header_line
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewTableHeader" }
  local divider_len = math.min(ctx.list_width - 2, checkbox_w + text_w + key_w + status_mode_w)
  lines[#lines + 1] = "  " .. string.rep("─", divider_len)
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewDivider" }

  for _, candidate in ipairs(ctx.view_candidates) do
    local marker = candidate.selected and "x" or " "
    local text_col = preview_text(candidate.text, text_w)
    local key_col = preview_text(candidate.proposed_key, key_w)
    local icon = status_icon(candidate.status)
    local mode_label = candidate.mode == "reuse" and "reuse" or "new"
    local line =
      string.format("[%s] %-" .. text_w .. "s %-" .. key_w .. "s %s %s", marker, text_col, key_col, icon, mode_label)
    lines[#lines + 1] = line
    local lineno = #lines
    ctx.line_to_candidate[lineno] = candidate.id

    -- Per-column highlights
    local line_str = lines[lineno]
    local cb_end = display_col_to_byte_col(line_str, checkbox_w)
    local text_end = display_col_to_byte_col(line_str, checkbox_w + text_w)
    local key_end = display_col_to_byte_col(line_str, checkbox_w + text_w + key_w)
    -- text column
    decorations[#decorations + 1] = {
      line = lineno - 1,
      group = "I18nStatusReviewText",
      col_start = cb_end,
      col_end = text_end,
    }
    -- key column
    decorations[#decorations + 1] = {
      line = lineno - 1,
      group = "I18nStatusReviewKey",
      col_start = text_end,
      col_end = key_end,
    }
    -- status icon
    decorations[#decorations + 1] = {
      line = lineno - 1,
      group = highlight_for_status(candidate.status),
      col_start = key_end,
      col_end = -1,
    }
  end

  if #ctx.candidates == 0 then
    lines[#lines + 1] = "(no extract candidates)"
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  elseif #ctx.view_candidates == 0 then
    lines[#lines + 1] = "(no candidates matched filter)"
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  end

  set_lines(ctx.list_buf, lines)
  apply_decorations(ctx.list_buf, decorations)

  vim.wo[ctx.list_win].winbar =
    "%#I18nStatusReviewHeader# I18nExtract Review %*%=%#I18nStatusReviewMeta# ?:help  q:quit %*"

  focus_candidate_line(ctx, preferred_candidate_id)
end

---@param ctx I18nStatusExtractReviewCtx
local function render_resource_preview(ctx)
  local candidate = current_candidate(ctx)
  if not candidate then
    set_lines(ctx.resource_buf, { "(no selection)" })
    apply_decorations(ctx.resource_buf, { { line = 0, group = "I18nStatusReviewMeta" } })
    return
  end

  candidate.text = candidate_text(ctx, candidate)

  local lines = {}
  local decorations = {}

  -- Key header
  lines[#lines + 1] = candidate.proposed_key
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewKey" }
  lines[#lines + 1] = string.rep("─", math.max(10, math.min(80, vim.fn.strdisplaywidth(candidate.proposed_key))))
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewDivider" }

  -- Metadata with colored values
  local status_line = string.format("status: %s", candidate.status)
  lines[#lines + 1] = status_line
  local status_label_len = #"status: "
  decorations[#decorations + 1] =
    { line = #lines - 1, group = "I18nStatusReviewMeta", col_start = 0, col_end = status_label_len }
  decorations[#decorations + 1] =
    { line = #lines - 1, group = highlight_for_status(candidate.status), col_start = status_label_len, col_end = -1 }

  local mode_line = string.format("mode: %s", candidate.mode)
  lines[#lines + 1] = mode_line
  local mode_label_len = #"mode: "
  decorations[#decorations + 1] =
    { line = #lines - 1, group = "I18nStatusReviewMeta", col_start = 0, col_end = mode_label_len }
  decorations[#decorations + 1] =
    { line = #lines - 1, group = "I18nStatusReviewKey", col_start = mode_label_len, col_end = -1 }

  if candidate.error then
    local reason_line = "reason: " .. candidate.error
    lines[#lines + 1] = reason_line
    local reason_label_len = #"reason: "
    decorations[#decorations + 1] =
      { line = #lines - 1, group = "I18nStatusReviewMeta", col_start = 0, col_end = reason_label_len }
    decorations[#decorations + 1] =
      { line = #lines - 1, group = "I18nStatusReviewStatusMissing", col_start = reason_label_len, col_end = -1 }
  end
  lines[#lines + 1] = ""

  -- Resource diff lines with per-part highlights
  local resource_lines = extract_diff.resource_diff_lines(candidate, ctx.languages, ctx.primary_lang, ctx.start_dir)
  for _, line in ipairs(resource_lines) do
    lines[#lines + 1] = line
    local lineno = #lines - 1

    if line == "Resource diff:" then
      decorations[#decorations + 1] = { line = lineno, group = "I18nStatusReviewHeader" }
    elseif line:match("^%(") then
      -- "(reuse existing key: ...)" or "(invalid key)"
      decorations[#decorations + 1] = { line = lineno, group = "I18nStatusReviewMeta" }
    else
      -- Format: "path: + "key": value"
      local plus_pos = line:find(": %+ ")
      if plus_pos then
        -- path portion
        decorations[#decorations + 1] =
          { line = lineno, group = "I18nStatusReviewPath", col_start = 0, col_end = plus_pos - 1 }
        -- ": + " separator
        decorations[#decorations + 1] =
          { line = lineno, group = "I18nStatusReviewDiffAdd", col_start = plus_pos - 1, col_end = plus_pos + 3 }
        -- key and value portion
        local after_plus = plus_pos + 3
        local colon_after_key = line:find(": ", after_plus)
        if colon_after_key then
          -- "key" part
          decorations[#decorations + 1] =
            { line = lineno, group = "I18nStatusReviewKey", col_start = after_plus, col_end = colon_after_key - 1 }
          -- value part
          decorations[#decorations + 1] =
            { line = lineno, group = "I18nStatusReviewValue", col_start = colon_after_key + 1, col_end = -1 }
        else
          decorations[#decorations + 1] =
            { line = lineno, group = "I18nStatusReviewDiffAdd", col_start = after_plus, col_end = -1 }
        end
      end
    end
  end

  set_lines(ctx.resource_buf, lines)
  apply_decorations(ctx.resource_buf, decorations)
end

---@param ctx I18nStatusExtractReviewCtx
local function ensure_source_preview_treesitter(ctx)
  if ctx._source_preview_ts_started then
    return
  end
  local src_ft = vim.bo[ctx.source_buf].filetype
  if not src_ft or src_ft == "" then
    return
  end
  local lang = vim.treesitter.language.get_lang(src_ft)
  if not lang then
    return
  end
  local ok = pcall(vim.treesitter.start, ctx.source_preview_buf, lang)
  if ok then
    ctx._source_preview_ts_started = true
  end
end

---@param ctx I18nStatusExtractReviewCtx
local function render_source_preview(ctx)
  local buf = ctx.source_preview_buf
  local candidate = current_candidate(ctx)
  if not candidate then
    set_lines(buf, { "(no selection)" })
    apply_decorations(buf, { { line = 0, group = "I18nStatusReviewMeta" } })
    return
  end

  if not vim.api.nvim_buf_is_valid(ctx.source_buf) then
    set_lines(buf, { "(source unavailable)" })
    apply_decorations(buf, { { line = 0, group = "I18nStatusReviewMeta" } })
    return
  end

  local context_lines = 5
  local lnum = candidate.lnum
  local total = vim.api.nvim_buf_line_count(ctx.source_buf)
  local start_line = math.max(0, lnum - context_lines)
  local end_line = math.min(total, lnum + context_lines + 1)

  local source_lines = vim.api.nvim_buf_get_lines(ctx.source_buf, start_line, end_line, false)

  -- Set raw source lines (treesitter highlights the actual code)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
  vim.bo[buf].modifiable = false

  ensure_source_preview_treesitter(ctx)

  -- Line number gutter + focus marker via inline virtual text
  vim.api.nvim_buf_clear_namespace(buf, EXTRACT_REVIEW_NS, 0, -1)
  local focus_buf_line = lnum - start_line
  for i = 0, #source_lines - 1 do
    local real_nr = start_line + i + 1
    local is_focus = (i == focus_buf_line)
    local prefix = is_focus and string.format("> %3d │ ", real_nr) or string.format("  %3d │ ", real_nr)
    local prefix_hl = is_focus and "I18nStatusReviewFocus" or "LineNr"
    local extmark_opts = {
      virt_text = { { prefix, prefix_hl } },
      virt_text_pos = "inline",
    }
    if is_focus then
      extmark_opts.line_hl_group = "CursorLine"
    end
    vim.api.nvim_buf_set_extmark(buf, EXTRACT_REVIEW_NS, i, 0, extmark_opts)
  end
end

---@param ctx I18nStatusExtractReviewCtx
---@param preferred_candidate_id integer|nil
local function refresh_views(ctx, preferred_candidate_id)
  ctx.statuses_dirty = true
  render_list(ctx, preferred_candidate_id)
  render_resource_preview(ctx)
  render_source_preview(ctx)
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
  vim.ui.input({
    prompt = "Extract filter (/ to clear): ",
    default = ctx.filter_query or "",
  }, function(input)
    if input == nil then
      return
    end
    local trimmed = vim.trim(input)
    if trimmed == "" then
      ctx.filter_query = nil
    else
      ctx.filter_query = trimmed
    end
    refresh_views(ctx, nil)
  end)
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

---@param ctx I18nStatusExtractReviewCtx
---@param candidates I18nStatusExtractCandidate[]
---@return I18nStatusExtractCandidate[]
---@return integer skipped
local function applicable_candidates(ctx, candidates)
  ctx.statuses_dirty = true
  refresh_candidate_statuses(ctx.candidates, ctx.existing_keys)
  ctx.statuses_dirty = false
  local applicable = {}
  local skipped = 0
  for _, candidate in ipairs(candidates) do
    if candidate.selected and candidate.status == "ready" then
      applicable[#applicable + 1] = candidate
    elseif candidate.selected then
      skipped = skipped + 1
    end
  end
  return applicable, skipped
end

---@type fun(ctx: I18nStatusExtractReviewCtx, cancelled: boolean)
local close_review

---@param replacement string
---@param row integer
---@param col integer
---@return integer
---@return integer
local function replacement_end_position(replacement, row, col)
  local lines = vim.split(replacement, "\n", { plain = true })
  if #lines == 1 then
    return row, col + #lines[1]
  end
  return row + #lines - 1, #lines[#lines]
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@return boolean applied
local function apply_candidate(ctx, candidate)
  local srow, scol, erow, ecol = candidate_range(ctx, candidate)
  if not srow then
    return false
  end

  local namespace, key_path = split_key(candidate.proposed_key)
  if not namespace or not key_path then
    return false
  end

  local source_text = candidate_text(ctx, candidate)
  candidate.text = source_text

  local replacement = string.format('{%s("%s")}', candidate.t_func or "t", candidate.proposed_key)
  local replaced, replace_err =
    pcall(vim.api.nvim_buf_set_text, ctx.source_buf, srow, scol, erow, ecol, { replacement })
  if not replaced then
    candidate.error = "failed to update source buffer (" .. tostring(replace_err) .. ")"
    return false
  end

  if candidate.mode == "new" then
    local translations = {}
    for _, lang in ipairs(ctx.languages) do
      translations[lang] = lang == ctx.primary_lang and source_text or ""
    end
    local success_count, failed_langs =
      key_write.write_translations(namespace, key_path, translations, ctx.start_dir, ctx.languages)
    if success_count == 0 then
      local rollback_lines = vim.split(source_text, "\n", { plain = true })
      local rollback_erow, rollback_ecol = replacement_end_position(replacement, srow, scol)
      local rollback_ok, rollback_err =
        pcall(vim.api.nvim_buf_set_text, ctx.source_buf, srow, scol, rollback_erow, rollback_ecol, rollback_lines)
      if not rollback_ok then
        candidate.error = "failed to rollback source buffer (" .. tostring(rollback_err) .. ")"
        vim.notify("i18n-status extract: " .. candidate.error, vim.log.levels.ERROR)
        return false
      end
      if type(failed_langs) == "table" and #failed_langs > 0 then
        candidate.error = "failed to write resource files (" .. table.concat(failed_langs, ", ") .. ")"
      else
        candidate.error = "failed to write resource files"
      end
      return false
    end
  end

  ctx.existing_keys[candidate.proposed_key] = true
  candidate.error = nil
  if candidate.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, ctx.source_buf, EXTRACT_REVIEW_TRACK_NS, candidate.mark_id)
    candidate.mark_id = nil
  end

  return true
end

---@param ctx I18nStatusExtractReviewCtx
---@param targets I18nStatusExtractCandidate[]
local function apply_targets(ctx, targets)
  if #targets == 0 then
    vim.notify("i18n-status extract: no candidates selected", vim.log.levels.INFO)
    return
  end

  local preferred = current_candidate(ctx)
  local preferred_id = preferred and preferred.id or nil

  local summary = {
    applied = 0,
    skipped = 0,
    failed = 0,
  }

  local applicable, skipped = applicable_candidates(ctx, targets)
  summary.skipped = skipped

  local applied_ids = {}
  for _, candidate in ipairs(applicable) do
    if apply_candidate(ctx, candidate) then
      summary.applied = summary.applied + 1
      applied_ids[candidate.id] = true
    else
      summary.failed = summary.failed + 1
    end
  end

  if summary.applied > 0 then
    local remaining = {}
    for _, candidate in ipairs(ctx.candidates) do
      if not applied_ids[candidate.id] then
        remaining[#remaining + 1] = candidate
      end
    end
    ctx.candidates = remaining

    core.refresh(ctx.source_buf, ctx.cfg, 0, { force = true })
    core.refresh_all(ctx.cfg)
  end

  ctx.status_message =
    string.format("last apply: applied=%d skipped=%d failed=%d", summary.applied, summary.skipped, summary.failed)
  local level = summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify(build_apply_message(summary), level)

  if #ctx.candidates == 0 then
    close_review(ctx, false)
    return
  end

  refresh_views(ctx, preferred_id)
end

local function apply_selected(ctx)
  local targets = {}
  for _, candidate in ipairs(ctx.candidates) do
    if candidate.selected then
      targets[#targets + 1] = candidate
    end
  end
  if #targets == 0 then
    vim.notify("i18n-status extract: no selected candidates", vim.log.levels.INFO)
    return
  end
  apply_targets(ctx, targets)
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
  local function map(lhs, handler)
    vim.keymap.set("n", lhs, function()
      local ctx = review_state[buf]
      if not ctx then
        return
      end
      handler(ctx)
    end, { buffer = buf, silent = true, nowait = true })
  end

  map("q", function(ctx)
    close_review(ctx, true)
  end)
  map("<Esc>", function(ctx)
    close_review(ctx, true)
  end)
  map("<Space>", toggle_current_selection)
  map("a", select_all)
  map("A", select_none)
  map("r", function(ctx)
    local candidate = current_candidate(ctx)
    if candidate then
      edit_candidate_key(ctx, candidate)
    end
  end)
  map("/", prompt_filter)
  map("u", choose_reuse_mode)
  map("U", choose_new_mode)
  map("<CR>", apply_selected)
  map("?", toggle_keymap_help)
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

  review_ui.ensure_review_highlights()

  local source_win = vim.api.nvim_get_current_win()

  local list_buf = vim.api.nvim_create_buf(false, true)
  local resource_buf = vim.api.nvim_create_buf(false, true)
  local source_preview_buf = vim.api.nvim_create_buf(false, true)
  for _, buf in ipairs({ list_buf, resource_buf, source_preview_buf }) do
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
  end
  vim.bo[list_buf].filetype = "i18n-status-extract-review"
  vim.bo[resource_buf].filetype = "i18n-status-extract-review"

  local float_config = (opts.cfg and opts.cfg.doctor and opts.cfg.doctor.float)
    or {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    }

  local win_width, win_height, row, col = review_ui.calculate_float_dimensions(float_config)
  local list_width = math.max(36, math.floor(win_width * 0.45))
  local border = float_config.border or "rounded"
  local border_offset = (border == "none" or border == "shadow") and 0 or 2

  local detail_width = win_width - list_width - border_offset
  detail_width = math.max(detail_width, 24)
  local resource_height = math.floor(win_height * 0.45)
  local source_height = win_height - resource_height - border_offset
  source_height = math.max(source_height, 4)

  local list_win = review_ui.create_float_win(
    list_buf,
    list_width,
    win_height,
    row,
    col,
    border,
    true,
    "I18nExtract - Candidates",
    "center"
  )
  local resource_win = review_ui.create_float_win(
    resource_buf,
    detail_width,
    resource_height,
    row,
    col + list_width + border_offset,
    border,
    false,
    "Resource Changes",
    "center"
  )
  local source_preview_win = review_ui.create_float_win(
    source_preview_buf,
    detail_width,
    source_height,
    row + resource_height + border_offset,
    col + list_width + border_offset,
    border,
    false,
    "Source Preview",
    "center"
  )

  vim.wo[list_win].winhighlight = table.concat({
    "Normal:I18nStatusReviewListNormal",
    "NormalFloat:I18nStatusReviewListNormal",
    "FloatBorder:I18nStatusReviewBorder",
    "FloatTitle:I18nStatusReviewTitle",
    "CursorLine:I18nStatusReviewListCursorLine",
  }, ",")
  vim.wo[list_win].cursorline = true

  local detail_winhighlight = table.concat({
    "Normal:I18nStatusReviewDetailNormal",
    "NormalFloat:I18nStatusReviewDetailNormal",
    "FloatBorder:I18nStatusReviewBorder",
    "FloatTitle:I18nStatusReviewTitle",
  }, ",")
  vim.wo[resource_win].winhighlight = detail_winhighlight
  vim.wo[source_preview_win].winhighlight = detail_winhighlight

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
      render_resource_preview(current)
      render_source_preview(current)
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
  normalize_key_input = normalize_key_input,
  status_icon = status_icon,
  refresh_candidate_statuses = function(candidates, existing_keys)
    refresh_candidate_statuses(candidates, existing_keys)
  end,
  applicable_candidates = function(candidates, existing_keys)
    refresh_candidate_statuses(candidates, existing_keys)
    local applicable = {}
    local skipped = 0
    for _, candidate in ipairs(candidates) do
      if candidate.selected and candidate.status == "ready" then
        applicable[#applicable + 1] = candidate
      elseif candidate.selected then
        skipped = skipped + 1
      end
    end
    return applicable, skipped
  end,
  build_apply_message = build_apply_message,
  set_reuse_mode = function(candidate)
    candidate.mode = "reuse"
  end,
  set_new_mode = function(candidate)
    candidate.mode = "new"
  end,
}

return M
