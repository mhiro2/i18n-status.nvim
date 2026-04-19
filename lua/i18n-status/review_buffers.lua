---@class I18nStatusReviewBuffers
local M = {}

local extract_diff = require("i18n-status.extract_diff")
local fs = require("i18n-status.fs")
local review_filters = require("i18n-status.review_filters")
local review_sections = require("i18n-status.review_sections")
local treesitter = require("i18n-status.treesitter")
local review_ui = require("i18n-status.review_ui")

---@class I18nStatusBufferDecoration
---@field line integer
---@field group string
---@field col_start integer|nil
---@field col_end integer|nil

---@class I18nStatusDoctorLayout
---@field list_buf integer
---@field detail_buf integer
---@field list_win integer
---@field detail_win integer
---@field list_width integer

---@class I18nStatusExtractLayout
---@field list_buf integer
---@field resource_buf integer
---@field source_preview_buf integer
---@field list_win integer
---@field resource_win integer
---@field source_preview_win integer
---@field list_width integer

---@class I18nStatusExtractPreviewDeps
---@field current_candidate fun(ctx: I18nStatusExtractReviewCtx): I18nStatusExtractCandidate|nil
---@field candidate_text fun(ctx: I18nStatusExtractReviewCtx, candidate: I18nStatusExtractCandidate): string

local LIST_WINHIGHLIGHT = table.concat({
  "Normal:I18nStatusReviewListNormal",
  "NormalFloat:I18nStatusReviewListNormal",
  "FloatBorder:I18nStatusReviewBorder",
  "FloatTitle:I18nStatusReviewTitle",
  "CursorLine:I18nStatusReviewListCursorLine",
}, ",")

local DETAIL_WINHIGHLIGHT = table.concat({
  "Normal:I18nStatusReviewDetailNormal",
  "NormalFloat:I18nStatusReviewDetailNormal",
  "FloatBorder:I18nStatusReviewBorder",
  "FloatTitle:I18nStatusReviewTitle",
}, ",")

---@param cfg I18nStatusConfig|nil
---@return I18nStatusReviewFloatConfig
local function float_config_for(cfg)
  return (cfg and cfg.doctor and cfg.doctor.float) or {
    width = 0.8,
    height = 0.8,
    border = "rounded",
  }
end

---@param border string
---@return integer
local function border_offset(border)
  if border == "none" or border == "shadow" then
    return 0
  end
  return 2
end

---@param buf integer
---@param filetype string|nil
---@param opts { review?: boolean }|nil
local function prepare_buffer(buf, filetype, opts)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  if filetype then
    vim.bo[buf].filetype = filetype
  end
  if opts and opts.review then
    vim.b[buf].i18n_status_review = true
    vim.b[buf].lsp_enabled = false
    vim.b[buf].treesitter_enabled = false
  end
end

---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param namespace integer
---@param decorations I18nStatusBufferDecoration[]|nil
function M.apply_decorations(buf, namespace, decorations)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, decoration in ipairs(decorations or {}) do
    if decoration.group and decoration.line then
      vim.api.nvim_buf_add_highlight(
        buf,
        namespace,
        decoration.group,
        decoration.line,
        decoration.col_start or 0,
        decoration.col_end or -1
      )
    end
  end
end

---@param buf integer
---@param namespace integer
---@param width integer|nil
function M.add_list_divider(buf, namespace, width)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not width or width <= 0 then
    return
  end

  local divider = string.rep("─", math.max(width, 10))
  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      {
        { divider, "I18nStatusReviewDivider" },
      },
    },
    priority = 200,
  })
end

---@param ctx table
function M.update_review_winbar(ctx)
  if ctx.list_win and vim.api.nvim_win_is_valid(ctx.list_win) then
    vim.wo[ctx.list_win].winbar = review_ui.build_review_winbar(ctx.list_width or 0, ctx.mode, ctx.filter_query)
  end
end

---@param buf integer
---@param namespace integer
---@param message string
function M.render_empty_buffer(buf, namespace, message)
  M.set_lines(buf, { message })
  M.apply_decorations(buf, namespace, {
    { line = 0, group = "I18nStatusReviewMeta" },
  })
end

---@param value string|nil
---@param max_width integer
---@return string
local function sanitize_value(value, max_width)
  local text = type(value) == "string" and value or ""
  text = text:gsub("\r", " "):gsub("\n", " ")
  text = text:gsub("%s+", " ")
  if text == "" then
    return "(empty)"
  end

  local width = vim.fn.strdisplaywidth(text)
  local limit = math.max(max_width or 60, 10)
  if width > limit then
    text = vim.fn.strcharpart(text, 0, limit - 1) .. "…"
  end
  return text
end

---@param list string[]|nil
---@return table<string, boolean>
local function list_to_set(list)
  local set = {}
  for _, lang in ipairs(list or {}) do
    set[lang] = true
  end
  return set
end

---@param order string[]
---@param lang string|nil
local function ensure_lang(order, lang)
  if not lang or lang == "" or vim.tbl_contains(order, lang) then
    return
  end
  order[#order + 1] = lang
end

---@param ctx I18nStatusReviewCtx
---@param hover table
---@return string[]
local function build_lang_order(ctx, hover)
  local order = {}
  for _, lang in ipairs(hover.lang_order or {}) do
    ensure_lang(order, lang)
  end
  for lang, _ in pairs(hover.values or {}) do
    ensure_lang(order, lang)
  end
  for _, lang in ipairs((ctx.cache and ctx.cache.languages) or {}) do
    ensure_lang(order, lang)
  end
  return order
end

---@param ctx I18nStatusReviewCtx
---@param namespace integer
function M.render_doctor_list(ctx, namespace)
  local section_items = ctx.section_items or {}
  local section_state = ctx.section_state or {}
  local lines = {}
  local decorations = {}
  local line_to_item = {}
  local line_to_section = {}

  local section_order = ctx.section_order or {}
  local section_labels = ctx.section_labels or {}
  local summary = review_sections.calculate_summary(section_items, section_order, ctx.summary_labels or {})
  lines[#lines + 1] = summary
  decorations[#decorations + 1] = { line = 0, group = "I18nStatusReviewHeader" }

  for _, status in ipairs(section_order) do
    local items = section_items[status] or {}
    if #items > 0 then
      lines[#lines + 1] = ""

      local section = section_state[status] or { expanded = true }
      local indicator = section.expanded and "▼" or "▶"
      local label = section_labels[status] or status
      local header = string.format("%s %s (%d)", indicator, label, #items)
      local header_line = #lines
      lines[#lines + 1] = header
      line_to_section[header_line + 1] = status
      decorations[#decorations + 1] = {
        line = header_line,
        group = "I18nStatusReviewSectionHeader",
      }

      if section.expanded then
        for _, item in ipairs(items) do
          local item_line = #lines
          lines[#lines + 1] = "  " .. item.key .. " [" .. item.status .. "]"
          line_to_item[item_line + 1] = item

          local key_len = 2 + #(item.key or "")
          decorations[#decorations + 1] = {
            line = item_line,
            group = "I18nStatusReviewKey",
            col_start = 2,
            col_end = key_len,
          }
          decorations[#decorations + 1] = {
            line = item_line,
            group = review_ui.highlight_for_status(item.status),
            col_start = key_len + 1,
          }
        end
      end
    end
  end

  if #lines == 1 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(no items)"
    decorations[#decorations + 1] = { line = 2, group = "I18nStatusReviewMeta" }
  end

  ctx.line_to_item = line_to_item
  ctx.line_to_section = line_to_section
  ctx.view_items = {}
  for line = 1, #lines do
    local item = line_to_item[line]
    if item then
      ctx.view_items[#ctx.view_items + 1] = item
    end
  end

  M.set_lines(ctx.list_buf, lines)
  M.apply_decorations(ctx.list_buf, namespace, decorations)
  M.add_list_divider(ctx.list_buf, namespace, math.max(math.min((ctx.list_width or 0) - 2, 160), 12))
  M.update_review_winbar(ctx)
end

---@param ctx I18nStatusReviewCtx
---@param namespace integer
function M.render_doctor_detail(ctx, namespace)
  local buf = ctx.detail_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local item = ctx.detail_item
  if not item then
    M.render_empty_buffer(buf, namespace, "(no selection)")
    return
  end

  local hover = item.hover or {}
  local lines = {}
  local decorations = {}

  local function append(text, group, col_start, col_end)
    lines[#lines + 1] = text
    if group then
      decorations[#decorations + 1] = {
        line = #lines - 1,
        group = group,
        col_start = col_start,
        col_end = col_end,
      }
    end
  end

  local function locale_highlight(lang, info, missing, localized, mismatch)
    if info.missing or missing[lang] then
      return "I18nStatusReviewStatusMissing"
    end
    if mismatch[lang] then
      return "I18nStatusReviewStatusMismatch"
    end
    if localized[lang] then
      return "I18nStatusReviewStatusLocalized"
    end
    if lang == ctx.primary_lang then
      return "I18nStatusReviewPrimary"
    end
    if hover.focus_lang and lang == hover.focus_lang then
      return "I18nStatusReviewFocus"
    end
    return "I18nStatusReviewStatusOk"
  end

  local function pad_to_width(text, target_width)
    local current_width = vim.fn.strdisplaywidth(text)
    if current_width >= target_width then
      return text
    end
    return text .. string.rep(" ", target_width - current_width)
  end

  local key = item.key or "(unknown)"
  append(key, "I18nStatusReviewHeader")
  append(string.rep("-", math.max(math.min(vim.fn.strdisplaywidth(key), 80), 8)), "I18nStatusReviewDivider")

  local status_symbol = hover.status or item.status or "="
  append("status: [" .. status_symbol .. "]", review_ui.highlight_for_status(status_symbol))
  if hover.namespace then
    append("namespace: " .. hover.namespace, "I18nStatusReviewMeta")
  end
  if hover.reason then
    append("reason: " .. hover.reason, "I18nStatusReviewMeta")
  end
  if item.unused then
    append("usage: unused", "I18nStatusReviewMeta")
  end

  local meta = {}
  if ctx.primary_lang and ctx.primary_lang ~= "" then
    meta[#meta + 1] = "primary=" .. ctx.primary_lang
  end
  if hover.focus_lang and hover.focus_lang ~= ctx.primary_lang then
    meta[#meta + 1] = "focus=" .. hover.focus_lang
  end
  if #meta > 0 then
    append(table.concat(meta, ", "), "I18nStatusReviewMeta")
  end

  local function append_lang_list(label, values, group)
    if values and #values > 0 then
      append(label .. ": " .. table.concat(values, ", "), group)
    end
  end

  append_lang_list("missing locales", hover.missing_langs, "I18nStatusReviewStatusMissing")
  append_lang_list("localized languages", hover.localized_langs, "I18nStatusReviewStatusLocalized")
  append_lang_list("placeholder mismatch", hover.mismatch_langs, "I18nStatusReviewStatusMismatch")
  append("", nil)

  local lang_order = build_lang_order(ctx, hover)
  local missing = list_to_set(hover.missing_langs)
  local localized = list_to_set(hover.localized_langs)
  local mismatch = list_to_set(hover.mismatch_langs)
  if #lang_order == 0 then
    append("(no translation data)", "I18nStatusReviewMeta")
  else
    local max_locale_width = 6
    local max_value_width = 5
    local max_source_width = 6
    local rows = {}

    for _, lang in ipairs(lang_order) do
      local info = (hover.values and hover.values[lang]) or {}
      local source = info.file and fs.shorten_path(info.file) or "-"
      local value = "(empty)"
      if info.value and info.value ~= "" then
        value = sanitize_value(info.value, 60)
      elseif info.missing or missing[lang] then
        value = "(missing)"
      end

      max_locale_width = math.max(max_locale_width, vim.fn.strdisplaywidth(lang))
      max_value_width = math.max(max_value_width, vim.fn.strdisplaywidth(value))
      max_source_width = math.max(max_source_width, vim.fn.strdisplaywidth(source))
      rows[#rows + 1] = {
        lang = lang,
        value = value,
        source = source,
        group = locale_highlight(lang, info, missing, localized, mismatch),
      }
    end

    append(
      pad_to_width("Locale", max_locale_width)
        .. " | "
        .. pad_to_width("Value", max_value_width)
        .. " | "
        .. pad_to_width("Source", max_source_width),
      "I18nStatusReviewTableHeader"
    )
    append(
      string.rep("-", max_locale_width)
        .. " | "
        .. string.rep("-", max_value_width)
        .. " | "
        .. string.rep("-", max_source_width),
      "I18nStatusReviewDivider"
    )

    for _, row in ipairs(rows) do
      append(
        pad_to_width(row.lang, max_locale_width)
          .. " | "
          .. pad_to_width(row.value, max_value_width)
          .. " | "
          .. pad_to_width(row.source, max_source_width),
        row.group
      )
    end
  end

  M.set_lines(buf, lines)
  M.apply_decorations(buf, namespace, decorations)
end

---@param text string
---@param max_width integer
---@return string
local function preview_text(text, max_width)
  local normalized = vim.trim((text or ""):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " "))
  if normalized == "" then
    normalized = "<empty>"
  end

  local limit = math.max(8, max_width or 30)
  if vim.fn.strdisplaywidth(normalized) <= limit then
    return normalized
  end
  return vim.fn.strcharpart(normalized, 0, limit - 1) .. "…"
end

---@param status string
---@return string
function M.extract_status_highlight(status)
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
function M.extract_status_icon(status)
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

---@param ctx I18nStatusExtractReviewCtx
---@return { total: integer, selected: integer, ready: integer, conflict: integer, invalid: integer, errors: integer }
local function extract_status_counts(ctx)
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

---@param win integer
---@param line_map table<integer, integer>|nil
---@param target_id integer|nil
function M.focus_line_by_id(win, line_map, target_id)
  if not target_id or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for line, mapped_id in pairs(line_map or {}) do
    if mapped_id == target_id then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      return
    end
  end
end

---@param ctx I18nStatusExtractReviewCtx
---@param namespace integer
---@param preferred_candidate_id integer|nil
function M.render_extract_list(ctx, namespace, preferred_candidate_id)
  local lines = {}
  local decorations = {}
  ctx.line_to_candidate = {}
  ctx.view_candidates = {}

  local filter_query = review_filters.normalize_query(ctx.filter_query, { lowercase = true })
  for _, candidate in ipairs(ctx.candidates) do
    if review_filters.candidate_matches(candidate, filter_query) then
      ctx.view_candidates[#ctx.view_candidates + 1] = candidate
    end
  end

  local counts = extract_status_counts(ctx)
  lines[#lines + 1] = string.format(
    "selected=%d/%d ready=%d conflict=%d invalid=%d error=%d",
    counts.selected,
    counts.total,
    counts.ready,
    counts.conflict,
    counts.invalid,
    counts.errors
  )
  decorations[#decorations + 1] = { line = 0, group = "I18nStatusReviewHeader" }

  if ctx.status_message and ctx.status_message ~= "" then
    lines[#lines + 1] = ctx.status_message
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  end
  if filter_query then
    lines[#lines + 1] = string.format("filter=/%s shown=%d/%d", ctx.filter_query, #ctx.view_candidates, #ctx.candidates)
    decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewMeta" }
  end
  lines[#lines + 1] = ""

  local checkbox_w = 4
  local status_mode_w = 8
  local padding = 2
  local content_w = math.max(20, ctx.list_width - checkbox_w - status_mode_w - padding)
  local text_w = math.max(8, math.floor(content_w * 0.40))
  local key_w = math.max(8, content_w - text_w)

  lines[#lines + 1] = string.format("    %-" .. text_w .. "s %-" .. key_w .. "s %s", "Text", "Key", "Stat")
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewTableHeader" }
  lines[#lines + 1] = "  "
    .. string.rep("─", math.min(ctx.list_width - 2, checkbox_w + text_w + key_w + status_mode_w))
  decorations[#decorations + 1] = { line = #lines - 1, group = "I18nStatusReviewDivider" }

  for _, candidate in ipairs(ctx.view_candidates) do
    local marker = candidate.selected and "x" or " "
    local text_col = preview_text(candidate.text, text_w)
    local key_col = preview_text(candidate.proposed_key, key_w)
    local icon = M.extract_status_icon(candidate.status)
    local mode_label = candidate.mode == "reuse" and "reuse" or "new"
    lines[#lines + 1] =
      string.format("[%s] %-" .. text_w .. "s %-" .. key_w .. "s %s %s", marker, text_col, key_col, icon, mode_label)
    local line_nr = #lines
    ctx.line_to_candidate[line_nr] = candidate.id

    local line_text = lines[line_nr]
    local checkbox_end = display_col_to_byte_col(line_text, checkbox_w)
    local text_end = display_col_to_byte_col(line_text, checkbox_w + text_w)
    local key_end = display_col_to_byte_col(line_text, checkbox_w + text_w + key_w)

    decorations[#decorations + 1] = {
      line = line_nr - 1,
      group = "I18nStatusReviewText",
      col_start = checkbox_end,
      col_end = text_end,
    }
    decorations[#decorations + 1] = {
      line = line_nr - 1,
      group = "I18nStatusReviewKey",
      col_start = text_end,
      col_end = key_end,
    }
    decorations[#decorations + 1] = {
      line = line_nr - 1,
      group = M.extract_status_highlight(candidate.status),
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

  M.set_lines(ctx.list_buf, lines)
  M.apply_decorations(ctx.list_buf, namespace, decorations)
  vim.wo[ctx.list_win].winbar =
    "%#I18nStatusReviewHeader# I18nExtract Review %*%=%#I18nStatusReviewMeta# ?:help  q:quit %*"
  M.focus_line_by_id(ctx.list_win, ctx.line_to_candidate, preferred_candidate_id)
end

---@param ctx I18nStatusExtractReviewCtx
---@param namespace integer
---@param deps I18nStatusExtractPreviewDeps
function M.render_extract_resource_preview(ctx, namespace, deps)
  local candidate = deps.current_candidate(ctx)
  if not candidate then
    M.render_empty_buffer(ctx.resource_buf, namespace, "(no selection)")
    return
  end

  candidate.text = deps.candidate_text(ctx, candidate)
  local lines = {}
  local decorations = {}

  lines[#lines + 1] = candidate.proposed_key
  decorations[#decorations + 1] = { line = 0, group = "I18nStatusReviewKey" }
  lines[#lines + 1] = string.rep("─", math.max(10, math.min(80, vim.fn.strdisplaywidth(candidate.proposed_key))))
  decorations[#decorations + 1] = { line = 1, group = "I18nStatusReviewDivider" }

  local status_line = "status: " .. candidate.status
  lines[#lines + 1] = status_line
  decorations[#decorations + 1] = { line = 2, group = "I18nStatusReviewMeta", col_start = 0, col_end = #"status: " }
  decorations[#decorations + 1] = {
    line = 2,
    group = M.extract_status_highlight(candidate.status),
    col_start = #"status: ",
    col_end = -1,
  }

  local mode_line = "mode: " .. candidate.mode
  lines[#lines + 1] = mode_line
  decorations[#decorations + 1] = { line = 3, group = "I18nStatusReviewMeta", col_start = 0, col_end = #"mode: " }
  decorations[#decorations + 1] = { line = 3, group = "I18nStatusReviewKey", col_start = #"mode: ", col_end = -1 }

  if candidate.error then
    lines[#lines + 1] = "reason: " .. candidate.error
    decorations[#decorations + 1] =
      { line = #lines - 1, group = "I18nStatusReviewMeta", col_start = 0, col_end = #"reason: " }
    decorations[#decorations + 1] = {
      line = #lines - 1,
      group = "I18nStatusReviewStatusMissing",
      col_start = #"reason: ",
      col_end = -1,
    }
  end
  lines[#lines + 1] = ""

  for _, line in ipairs(extract_diff.resource_diff_lines(candidate, ctx.languages, ctx.primary_lang, ctx.start_dir)) do
    lines[#lines + 1] = line
    local line_nr = #lines - 1
    if line == "Resource diff:" then
      decorations[#decorations + 1] = { line = line_nr, group = "I18nStatusReviewHeader" }
    elseif line:match("^%(") then
      decorations[#decorations + 1] = { line = line_nr, group = "I18nStatusReviewMeta" }
    else
      local plus_pos = line:find(": %+ ")
      if plus_pos then
        decorations[#decorations + 1] = {
          line = line_nr,
          group = "I18nStatusReviewPath",
          col_start = 0,
          col_end = plus_pos - 1,
        }
        decorations[#decorations + 1] = {
          line = line_nr,
          group = "I18nStatusReviewDiffAdd",
          col_start = plus_pos - 1,
          col_end = plus_pos + 3,
        }
        local after_plus = plus_pos + 3
        local colon_after_key = line:find(": ", after_plus)
        if colon_after_key then
          decorations[#decorations + 1] = {
            line = line_nr,
            group = "I18nStatusReviewKey",
            col_start = after_plus,
            col_end = colon_after_key - 1,
          }
          decorations[#decorations + 1] = {
            line = line_nr,
            group = "I18nStatusReviewValue",
            col_start = colon_after_key + 1,
            col_end = -1,
          }
        else
          decorations[#decorations + 1] = {
            line = line_nr,
            group = "I18nStatusReviewDiffAdd",
            col_start = after_plus,
            col_end = -1,
          }
        end
      end
    end
  end

  M.set_lines(ctx.resource_buf, lines)
  M.apply_decorations(ctx.resource_buf, namespace, decorations)
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

  local lang = treesitter.parser_lang_for_filetype(src_ft)
  if not lang then
    return
  end

  local parser_ok = treesitter.has_parser(lang)
  if not parser_ok then
    return
  end

  if pcall(vim.treesitter.start, ctx.source_preview_buf, lang) then
    ctx._source_preview_ts_started = true
  end
end

---@param ctx I18nStatusExtractReviewCtx
---@param namespace integer
---@param deps I18nStatusExtractPreviewDeps
function M.render_extract_source_preview(ctx, namespace, deps)
  local buf = ctx.source_preview_buf
  local candidate = deps.current_candidate(ctx)
  if not candidate then
    M.render_empty_buffer(buf, namespace, "(no selection)")
    return
  end
  if not vim.api.nvim_buf_is_valid(ctx.source_buf) then
    M.render_empty_buffer(buf, namespace, "(source unavailable)")
    return
  end

  local context_lines = 5
  local total = vim.api.nvim_buf_line_count(ctx.source_buf)
  local start_line = math.max(0, candidate.lnum - context_lines)
  local end_line = math.min(total, candidate.lnum + context_lines + 1)
  local source_lines = vim.api.nvim_buf_get_lines(ctx.source_buf, start_line, end_line, false)

  M.set_lines(buf, source_lines)
  ensure_source_preview_treesitter(ctx)

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local focus_buf_line = candidate.lnum - start_line
  for i = 0, #source_lines - 1 do
    local real_nr = start_line + i + 1
    local is_focus = i == focus_buf_line
    local extmark_opts = {
      virt_text = {
        {
          is_focus and string.format("> %3d │ ", real_nr) or string.format("  %3d │ ", real_nr),
          is_focus and "I18nStatusReviewFocus" or "LineNr",
        },
      },
      virt_text_pos = "inline",
    }
    if is_focus then
      extmark_opts.line_hl_group = "CursorLine"
    end
    vim.api.nvim_buf_set_extmark(buf, namespace, i, 0, extmark_opts)
  end
end

---@param config I18nStatusConfig|nil
---@param mode string|nil
---@param filter_query string|nil
---@return I18nStatusDoctorLayout
function M.open_doctor_layout(config, mode, filter_query)
  review_ui.ensure_review_highlights()

  local list_buf = vim.api.nvim_create_buf(false, true)
  local detail_buf = vim.api.nvim_create_buf(false, true)
  prepare_buffer(list_buf, "i18n-status-review", { review = true })
  prepare_buffer(detail_buf, "i18n-status-review", { review = true })

  local float_config = float_config_for(config)
  local win_width, win_height, row, col = review_ui.calculate_float_dimensions(float_config)
  local list_width = math.floor(win_width * 0.4)
  local detail_width = win_width - list_width
  local border = float_config.border or "rounded"
  local offset = border_offset(border)

  local list_win = review_ui.create_float_win(
    list_buf,
    list_width,
    win_height,
    row,
    col,
    border,
    true,
    "I18nDoctor - Key List",
    "center"
  )
  local detail_win = review_ui.create_float_win(
    detail_buf,
    detail_width - offset,
    win_height,
    row,
    col + list_width + offset,
    border,
    false,
    "I18nDoctor - Preview",
    "center"
  )

  vim.wo[list_win].winhighlight = LIST_WINHIGHLIGHT
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].winbar = review_ui.build_review_winbar(list_width, mode, filter_query)
  vim.wo[detail_win].winhighlight = DETAIL_WINHIGHLIGHT
  vim.wo[detail_win].cursorline = false

  return {
    list_buf = list_buf,
    detail_buf = detail_buf,
    list_win = list_win,
    detail_win = detail_win,
    list_width = list_width,
  }
end

---@param config I18nStatusConfig|nil
---@return I18nStatusExtractLayout
function M.open_extract_layout(config)
  review_ui.ensure_review_highlights()

  local list_buf = vim.api.nvim_create_buf(false, true)
  local resource_buf = vim.api.nvim_create_buf(false, true)
  local source_preview_buf = vim.api.nvim_create_buf(false, true)
  prepare_buffer(list_buf, "i18n-status-extract-review", nil)
  prepare_buffer(resource_buf, "i18n-status-extract-review", nil)
  prepare_buffer(source_preview_buf, nil, nil)

  local float_config = float_config_for(config)
  local win_width, win_height, row, col = review_ui.calculate_float_dimensions(float_config)
  local list_width = math.max(36, math.floor(win_width * 0.45))
  local border = float_config.border or "rounded"
  local offset = border_offset(border)
  local detail_width = math.max(win_width - list_width - offset, 24)
  local resource_height = math.floor(win_height * 0.45)
  local source_height = math.max(win_height - resource_height - offset, 4)

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
    col + list_width + offset,
    border,
    false,
    "Resource Changes",
    "center"
  )
  local source_preview_win = review_ui.create_float_win(
    source_preview_buf,
    detail_width,
    source_height,
    row + resource_height + offset,
    col + list_width + offset,
    border,
    false,
    "Source Preview",
    "center"
  )

  vim.wo[list_win].winhighlight = LIST_WINHIGHLIGHT
  vim.wo[list_win].cursorline = true
  vim.wo[resource_win].winhighlight = DETAIL_WINHIGHLIGHT
  vim.wo[source_preview_win].winhighlight = DETAIL_WINHIGHLIGHT

  return {
    list_buf = list_buf,
    resource_buf = resource_buf,
    source_preview_buf = source_preview_buf,
    list_win = list_win,
    resource_win = resource_win,
    source_preview_win = source_preview_win,
    list_width = list_width,
  }
end

return M
