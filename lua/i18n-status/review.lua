---@class I18nStatusReview
local M = {}

local config_mod = require("i18n-status.config")
local core = require("i18n-status.core")
local resources = require("i18n-status.resources")
local state = require("i18n-status.state")
local util = require("i18n-status.util")
local resolve = require("i18n-status.resolve")

local ops = require("i18n-status.ops")

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
---@field filter_state string|nil Filter state ("missing", "all", etc.)
---@field sort_state string|nil Sort state
---@field config table|nil Plugin configuration
---@field cache table|nil Resource cache
---@field primary_lang string|nil Primary language
---@field secondary_langs string[]|nil Secondary languages
---@field display_lang string|nil Display language for Doctor UI
---@field mode string|nil Doctor UI mode ("problems" or "overview")
---@field views table|nil Doctor UI views
---@field augroup integer|nil Autocmd group ID
---@field update_timer userdata|nil Update timer
---@field debounce_update function|nil Debounced update function
---@field pending_edit boolean|nil Edit in progress flag
---@field is_closing boolean|nil Closing in progress flag

---@type table<integer, I18nStatusReviewCtx>
local review_state = {}
local REVIEW_NS = vim.api.nvim_create_namespace("i18n-status-review")

local highlights_ready = false
local hl_cache = {}

local function hl_exists(name)
  -- Check cache first to avoid repeated pcall overhead
  if hl_cache[name] ~= nil then
    return hl_cache[name]
  end

  local ok = pcall(vim.api.nvim_get_hl, 0, { name = name })
  hl_cache[name] = ok
  return ok
end

-- Clear cache when colorscheme changes
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    hl_cache = {}
    highlights_ready = false
  end,
})

local function choose_hl(...)
  local candidates = { ... }
  for _, candidate in ipairs(candidates) do
    if candidate and hl_exists(candidate) then
      return candidate
    end
  end
  return "Normal"
end

local function define_hl(group, ...)
  vim.api.nvim_set_hl(0, group, { default = true, link = choose_hl(...) })
end

local function ensure_review_highlights()
  if highlights_ready then
    return
  end

  define_hl("I18nStatusReviewListNormal", "TelescopeNormal", "NormalFloat")
  define_hl("I18nStatusReviewListCursorLine", "TelescopeSelection", "CursorLine")
  define_hl("I18nStatusReviewDetailNormal", "TelescopePreviewNormal", "NormalFloat")
  define_hl("I18nStatusReviewBorder", "TelescopeBorder", "FloatBorder")
  define_hl("I18nStatusReviewTitle", "TelescopeTitle", "FloatTitle")
  define_hl("I18nStatusReviewHeader", "TelescopeResultsTitle", "Title")
  define_hl("I18nStatusReviewDivider", "Comment")
  define_hl("I18nStatusReviewMeta", "TelescopeResultsComment", "Comment")
  define_hl("I18nStatusReviewKey", "TelescopeResultsIdentifier", "Identifier")
  define_hl("I18nStatusReviewTableHeader", "TelescopePromptPrefix", "SpecialComment")
  define_hl("I18nStatusReviewStatusOk", "DiagnosticOk", "DiffAdd")
  define_hl("I18nStatusReviewStatusMissing", "DiagnosticError", "ErrorMsg")
  define_hl("I18nStatusReviewStatusFallback", "DiagnosticInfo", "DiffChange")
  define_hl("I18nStatusReviewStatusLocalized", "DiagnosticHint", "DiffChange")
  define_hl("I18nStatusReviewStatusMismatch", "DiagnosticWarn", "WarningMsg")
  define_hl("I18nStatusReviewStatusDefault", "Normal")
  define_hl("I18nStatusReviewPrimary", "TelescopePromptPrefix", "Identifier")
  define_hl("I18nStatusReviewFocus", "Search")
  define_hl("I18nStatusReviewSectionHeader", "LazyH1", "Title")
  define_hl("I18nStatusReviewHeader", "Comment")

  highlights_ready = true
end

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

local status_highlights = {
  ["="] = "I18nStatusReviewStatusOk",
  ["×"] = "I18nStatusReviewStatusMissing",
  ["?"] = "I18nStatusReviewStatusFallback",
  ["≠"] = "I18nStatusReviewStatusLocalized",
  ["!"] = "I18nStatusReviewStatusMismatch",
}

local STATUS_SECTION_ORDER = { "×", "!", "?", "≠", "=" }
local STATUS_SECTION_LABELS = {
  ["×"] = "Missing",
  ["!"] = "Mismatch",
  ["?"] = "Fallback",
  ["≠"] = "Localized",
  ["="] = "Same",
}
local STATUS_SUMMARY_LABELS = {
  ["×"] = "missing",
  ["!"] = "mismatch",
  ["?"] = "fallback",
  ["≠"] = "localized",
  ["="] = "same",
}

local PROBLEMS_SECTION_ORDER = { "unused", "×", "!", "?", "≠", "=" }
local PROBLEMS_SECTION_LABELS = {
  unused = "Unused",
  ["×"] = "Missing",
  ["!"] = "Mismatch",
  ["?"] = "Fallback",
  ["≠"] = "Localized",
  ["="] = "Same",
}
local PROBLEMS_SUMMARY_LABELS = {
  unused = "unused",
  ["×"] = "missing",
  ["!"] = "mismatch",
  ["?"] = "fallback",
  ["≠"] = "localized",
  ["="] = "same",
}

local MODE_PROBLEMS = "problems"
local MODE_OVERVIEW = "overview"

---@param mode string|nil
---@return string
local function mode_label(mode)
  if mode == MODE_OVERVIEW then
    return "Overview"
  end
  return "Problems"
end

local KEYMAP_HELP = {
  { keys = "q / <Esc>", desc = "Close review UI" },
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

local function build_review_winbar(list_width, mode)
  -- Lazy.nvim style: left-aligned header, right-aligned keymaps
  local header = " I18nDoctor [" .. mode_label(mode) .. "] "

  -- Keymap hint variations (pipe-separated for clarity)
  local full_keymaps =
    " q:quit │ e:edit │ E:locale │ r:rename │ a:add │ Tab:mode │ gd:goto │ Space:toggle │ ?:help "
  local medium_keymaps = " q:quit │ e:edit │ E:locale │ a:add │ Tab:mode │ ?:help "
  local short_keymaps = " q:quit │ Tab:mode │ ?:help "

  -- Calculate display widths
  local header_width = vim.fn.strdisplaywidth(header)
  local full_width = vim.fn.strdisplaywidth(full_keymaps)
  local medium_width = vim.fn.strdisplaywidth(medium_keymaps)

  -- Available width (account for borders and padding)
  local available_width = math.max(list_width - 4, 20)

  -- Choose keymap display based on available width
  local keymaps
  if header_width + full_width + 2 <= available_width then
    keymaps = full_keymaps
  elseif header_width + medium_width + 2 <= available_width then
    keymaps = medium_keymaps
  else
    keymaps = short_keymaps
  end

  -- Build winbar with left-right split (%= aligns following content to the right)
  return "%#I18nStatusReviewHeader#" .. header .. "%*" .. "%=" .. "%#I18nStatusReviewMeta#" .. keymaps .. "%*"
end

---@param ctx table
local function update_winbar(ctx)
  if ctx.list_win and vim.api.nvim_win_is_valid(ctx.list_win) then
    vim.wo[ctx.list_win].winbar = build_review_winbar(ctx.list_width or 0, ctx.mode)
  end
end

local function highlight_for_status(status)
  return status_highlights[status] or "I18nStatusReviewStatusDefault"
end

---@param ctx table
local function close_review(ctx)
  if not ctx or ctx.closing then
    return
  end
  ctx.closing = true

  -- Disable all autocmds during cleanup to prevent performance overhead
  local save_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"

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

  -- Restore eventignore after a delay to avoid triggering heavy autocmds
  vim.schedule(function()
    vim.o.eventignore = save_eventignore
  end)
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param decorations { line: integer, group: string, col_start?: integer, col_end?: integer }[]
local function apply_decorations(buf, decorations)
  vim.api.nvim_buf_clear_namespace(buf, REVIEW_NS, 0, -1)
  for _, deco in ipairs(decorations or {}) do
    if deco.group and deco.line then
      vim.api.nvim_buf_add_highlight(buf, REVIEW_NS, deco.group, deco.line, deco.col_start or 0, deco.col_end or -1)
    end
  end
end

---@param buf integer
---@param width integer|nil
local function add_list_divider(buf, width)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not width or width <= 0 then
    return
  end
  local divider = string.rep("─", math.max(width, 10))
  vim.api.nvim_buf_set_extmark(buf, REVIEW_NS, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      {
        { divider, "I18nStatusReviewDivider" },
      },
    },
    priority = 200,
  })
end

local function build_keymap_help_lines()
  local title = "I18nDoctor keymaps"
  local divider = string.rep("-", #title)
  local max_key = 0
  for _, entry in ipairs(KEYMAP_HELP) do
    max_key = math.max(max_key, vim.fn.strdisplaywidth(entry.keys))
  end
  local format = " %-" .. max_key .. "s  %s "
  local lines = { " " .. title .. " ", " " .. divider .. " " }
  for _, entry in ipairs(KEYMAP_HELP) do
    table.insert(lines, string.format(format, entry.keys, entry.desc))
  end
  return lines
end

---@param ctx table
close_keymap_help = function(ctx)
  if ctx.help_win and vim.api.nvim_win_is_valid(ctx.help_win) then
    pcall(vim.api.nvim_win_close, ctx.help_win, true)
  end
  if ctx.help_buf and vim.api.nvim_buf_is_valid(ctx.help_buf) then
    pcall(vim.api.nvim_buf_delete, ctx.help_buf, { force = true })
  end
  ctx.help_win = nil
  ctx.help_buf = nil
end

---@param ctx table
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
  vim.bo[buf].filetype = "i18n-status-review-help"
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

---@param ctx table
local function toggle_keymap_help(ctx)
  if ctx.help_win and vim.api.nvim_win_is_valid(ctx.help_win) then
    close_keymap_help(ctx)
  else
    open_keymap_help(ctx)
  end
end

---Groups items by their status symbol
---@param items I18nStatusResolved[]
---@return table<string, I18nStatusResolved[]>
local function group_items_by_status(items)
  local groups = {}
  for _, status in ipairs(STATUS_SECTION_ORDER) do
    groups[status] = {}
  end

  for _, item in ipairs(items) do
    local status = item.status or "="
    if groups[status] then
      table.insert(groups[status], item)
    else
      table.insert(groups["="], item)
    end
  end

  return groups
end

---Groups items by unused or status (problems view)
---@param items I18nStatusResolved[]
---@return table<string, I18nStatusResolved[]>
local function group_items_for_problems(items)
  local groups = { unused = {} }
  for _, status in ipairs(STATUS_SECTION_ORDER) do
    groups[status] = {}
  end

  for _, item in ipairs(items) do
    if item.unused then
      table.insert(groups.unused, item)
    else
      local status = item.status or "="
      if groups[status] then
        table.insert(groups[status], item)
      else
        table.insert(groups["="], item)
      end
    end
  end

  return groups
end

---@return table<string, { expanded: boolean, count?: integer }>
local function new_section_state(section_order)
  local sections = {}
  for _, section in ipairs(section_order or STATUS_SECTION_ORDER) do
    sections[section] = { expanded = true }
  end
  return sections
end

---Calculates summary line with total count and per-status breakdown
---@param section_items table<string, I18nStatusResolved[]>
---@param section_order string[]|nil
---@param summary_labels table<string, string>|nil
---@return string
local function calculate_summary(section_items, section_order, summary_labels)
  local total = 0

  for _, items in pairs(section_items) do
    total = total + #items
  end

  local parts = {}
  local order = section_order or STATUS_SECTION_ORDER
  local labels = summary_labels or STATUS_SUMMARY_LABELS
  for _, status in ipairs(order) do
    local count = #(section_items[status] or {})
    if count > 0 then
      local label = labels[status] or status
      table.insert(parts, label .. ": " .. count)
    end
  end

  if #parts == 0 then
    return "Total: 0 keys"
  end

  return string.format("Total: %d keys  (%s)", total, table.concat(parts, "  "))
end

---@param buf integer
---@param ctx table
local function render_list(buf, ctx)
  local section_items = ctx.section_items or {}
  local section_state = ctx.section_state or {}

  local lines = {}
  local decorations = {}
  local line_to_item = {}
  local line_to_section = {}

  local section_order = ctx.section_order or STATUS_SECTION_ORDER
  local section_labels = ctx.section_labels or STATUS_SECTION_LABELS
  local summary = calculate_summary(section_items, section_order, ctx.summary_labels or STATUS_SUMMARY_LABELS)
  table.insert(lines, summary)
  table.insert(decorations, { line = 0, group = "I18nStatusReviewHeader" })

  for _, status in ipairs(section_order) do
    local items = section_items[status] or {}
    local count = #items

    if count > 0 then
      table.insert(lines, "")

      local sect = section_state[status] or { expanded = true }
      local indicator = sect.expanded and "▼" or "▶"
      local label = section_labels[status] or status
      local header = string.format("%s %s (%d)", indicator, label, count)
      local header_line = #lines
      table.insert(lines, header)

      line_to_section[header_line + 1] = status

      table.insert(decorations, {
        line = header_line,
        group = "I18nStatusReviewSectionHeader",
      })

      if sect.expanded then
        for _, item in ipairs(items) do
          local item_line = #lines
          table.insert(lines, "  " .. item.key .. " [" .. item.status .. "]")

          line_to_item[item_line + 1] = item

          local key_len = 2 + #(item.key or "")
          local status_group = highlight_for_status(item.status)
          table.insert(decorations, {
            line = item_line,
            group = "I18nStatusReviewKey",
            col_start = 2,
            col_end = key_len,
          })
          table.insert(decorations, {
            line = item_line,
            group = status_group,
            col_start = key_len + 1,
          })
        end
      end
    end
  end

  if #lines == 1 then
    table.insert(lines, "")
    table.insert(lines, "(no items)")
    table.insert(decorations, { line = 2, group = "I18nStatusReviewMeta" })
  end

  ctx.line_to_item = line_to_item
  ctx.line_to_section = line_to_section

  local view_items = {}
  for _, item in pairs(line_to_item) do
    table.insert(view_items, item)
  end
  ctx.view_items = view_items

  set_lines(buf, lines)
  apply_decorations(buf, decorations)

  local width = math.max(math.min((ctx.list_width or 0) - 2, 160), 12)
  add_list_divider(buf, width)
  update_winbar(ctx)
end

---@param value string|nil
---@param max_width integer
---@return string
local function sanitize_value(value, max_width)
  local text = value or ""
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

---@param key string
---@param lang string
---@param label string|nil
---@return string
local function build_edit_prompt(key, lang, label)
  local lines = {}
  if label and label ~= "" then
    table.insert(lines, label)
  end
  table.insert(lines, "Key: " .. key)
  table.insert(lines, "Locale: " .. lang)
  table.insert(lines, "")
  table.insert(lines, "New value: ")
  return table.concat(lines, "\n")
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
  if not lang or lang == "" then
    return
  end
  if not vim.tbl_contains(order, lang) then
    table.insert(order, lang)
  end
end

---@param ctx table
---@param hover table
---@return string[]
local function build_lang_order(ctx, hover)
  local order = {}
  for _, lang in ipairs(hover.lang_order or {}) do
    ensure_lang(order, lang)
  end
  if hover.values then
    for lang, _ in pairs(hover.values) do
      ensure_lang(order, lang)
    end
  end
  if ctx.cache and ctx.cache.languages then
    for _, lang in ipairs(ctx.cache.languages) do
      ensure_lang(order, lang)
    end
  end
  return order
end

---@param ctx table
local function render_detail(ctx)
  local buf = ctx.detail_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local item = ctx.detail_item
  if not item then
    set_lines(buf, { "(no selection)" })
    apply_decorations(buf, { { line = 0, group = "I18nStatusReviewMeta" } })
    return
  end

  local hover = item.hover or {}
  local lines = {}
  local decorations = {}

  local function append(text, group, col_start, col_end)
    table.insert(lines, text)
    if group then
      table.insert(decorations, {
        line = #lines - 1,
        group = group,
        col_start = col_start,
        col_end = col_end,
      })
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

  local function pad_to_width(str, target_width)
    local current_width = vim.fn.strdisplaywidth(str)
    local padding_needed = target_width - current_width
    if padding_needed <= 0 then
      return str
    end
    return str .. string.rep(" ", padding_needed)
  end

  local key = item.key or "(unknown)"
  local divider_width = math.max(math.min(vim.fn.strdisplaywidth(key), 80), 8)
  append(key, "I18nStatusReviewHeader")
  append(string.rep("-", divider_width), "I18nStatusReviewDivider")

  local status_symbol = hover.status or item.status or "="
  append("status: [" .. status_symbol .. "]", highlight_for_status(status_symbol))
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
    table.insert(meta, "primary=" .. ctx.primary_lang)
  end
  if hover.focus_lang and hover.focus_lang ~= ctx.primary_lang then
    table.insert(meta, "focus=" .. hover.focus_lang)
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
    local max_locale_width = 6 -- Minimum to match "Locale" header
    local max_value_width = 5 -- Minimum to match "Value" header
    local max_source_width = 6 -- Minimum to match "Source" header
    local row_data = {}

    for _, lang in ipairs(lang_order) do
      local info = (hover.values and hover.values[lang]) or {}
      local source = info.file and util.shorten_path(info.file) or "-"

      local value
      if info.value and info.value ~= "" then
        value = sanitize_value(info.value, 60)
      elseif info.missing or missing[lang] then
        value = "(missing)"
      else
        value = "(empty)"
      end
      local row_group = locale_highlight(lang, info, missing, localized, mismatch)

      -- Measure display widths
      local locale_width = vim.fn.strdisplaywidth(lang)
      local value_width = vim.fn.strdisplaywidth(value)
      local source_width = vim.fn.strdisplaywidth(source)

      -- Update maximum widths
      max_locale_width = math.max(max_locale_width, locale_width)
      max_value_width = math.max(max_value_width, value_width)
      max_source_width = math.max(max_source_width, source_width)

      -- Store row data
      table.insert(row_data, {
        lang = lang,
        value = value,
        source = source,
        row_group = row_group,
      })
    end

    -- Render header and divider with dynamic widths
    local header_locale = pad_to_width("Locale", max_locale_width)
    local header_value = pad_to_width("Value", max_value_width)
    local header_source = pad_to_width("Source", max_source_width)
    append(header_locale .. " | " .. header_value .. " | " .. header_source, "I18nStatusReviewTableHeader")

    local divider_locale = string.rep("-", max_locale_width)
    local divider_value = string.rep("-", max_value_width)
    local divider_source = string.rep("-", max_source_width)
    append(divider_locale .. " | " .. divider_value .. " | " .. divider_source, "I18nStatusReviewDivider")

    -- Second pass: render aligned rows
    for _, row in ipairs(row_data) do
      local padded_locale = pad_to_width(row.lang, max_locale_width)
      local padded_value = pad_to_width(row.value, max_value_width)
      local padded_source = pad_to_width(row.source, max_source_width)
      append(padded_locale .. " | " .. padded_value .. " | " .. padded_source, row.row_group)
    end
  end

  set_lines(buf, lines)
  apply_decorations(buf, decorations)
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
  render_detail(ctx)
end

-- Forward declarations
local refresh_doctor_items

---@param issues I18nStatusDoctorIssue[]
---@param cache table
---@param primary_lang string
---@return I18nStatusResolved[]
local function build_resolved_items(keys, cache, primary_lang, display_lang)
  if not keys or #keys == 0 then
    return {}
  end

  local resolve_state = {
    primary_lang = primary_lang,
    current_lang = display_lang,
    languages = cache.languages or {},
  }

  local dummy_items = {}
  for _, key in ipairs(keys) do
    table.insert(dummy_items, { key = key, lnum = 0, col = 0 })
  end

  return resolve.compute(dummy_items, resolve_state, cache.index)
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

---@param float_config I18nStatusReviewFloatConfig
---@return integer, integer, integer, integer
local function calculate_float_dimensions(float_config)
  local width = vim.o.columns
  local height = vim.o.lines

  local win_width = math.floor(width * (float_config.width or 0.8))
  local win_height = math.floor(height * (float_config.height or 0.8))

  local row = math.floor((height - win_height) / 2)
  local col = math.floor((width - win_width) / 2)

  return win_width, win_height, row, col
end

---@param buf integer
---@param width integer
---@param height integer
---@param row integer
---@param col integer
---@param border string
---@param focusable boolean|nil
---@return integer
local function create_float_win(buf, width, height, row, col, border, focusable, title, title_pos)
  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = border,
    style = "minimal",
    focusable = focusable ~= false,
  }

  -- Add title if provided
  if title then
    win_config.title = title
    win_config.title_pos = title_pos or "center"
  end

  return vim.api.nvim_open_win(buf, false, win_config)
end

---@param ctx table
---@param lang string
local function edit_lang(ctx, lang)
  local item = ctx.detail_item
  if not item then
    return
  end

  local info = item.hover and item.hover.values and item.hover.values[lang]
  local current = info and info.value or ""
  local prompt = build_edit_prompt(item.key, lang, "Edit locale: " .. lang)

  vim.ui.input({ prompt = prompt, default = current }, function(input)
    if input == nil then
      return
    end

    local root = resources.start_dir(ctx.source_buf or vim.api.nvim_get_current_buf())
    local namespace = item.key:match("^(.-):") or resources.fallback_namespace(root)
    local key_path = item.key:match("^[^:]+:(.+)$") or ""
    local path = (info and info.file) or resources.namespace_path(root, lang, namespace)

    if not path then
      vim.notify("i18n-status review: resource path not found (" .. lang .. ")", vim.log.levels.WARN)
      return
    end

    util.ensure_dir(util.dirname(path))
    local data, style = resources.read_json_table(path)
    if not data then
      vim.notify("i18n-status review: failed to read json (" .. (style.error or "unknown") .. ")", vim.log.levels.WARN)
      return
    end

    local path_in_file = resources.key_path_for_file(namespace, key_path, root, lang, path)
    util.set_nested(data, path_in_file, input)
    resources.write_json_table(path, data, style)

    if ctx.config then
      core.refresh_all(ctx.config)
    else
      core.refresh_now(ctx.source_buf or vim.api.nvim_get_current_buf(), config_mod.setup({}))
    end

    if ctx.is_doctor_review then
      local doctor = require("i18n-status.doctor")
      ctx.issues = doctor.refresh(ctx)
      refresh_doctor_items(ctx)
    end
  end)
end

---@param ctx table
local function edit_focus(ctx)
  local focus_lang = ctx.display_lang or ctx.primary_lang
  if not focus_lang or focus_lang == "" then
    return
  end
  edit_lang(ctx, focus_lang)
end

---@param ctx table
local function edit_locale_select(ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  local languages = ctx.cache and ctx.cache.languages or {}
  if not languages or #languages == 0 then
    vim.notify("i18n-status review: no languages available", vim.log.levels.WARN)
    return
  end

  local function format_lang(lang)
    local info = item.hover and item.hover.values and item.hover.values[lang]
    local status = ""
    if info then
      if info.missing then
        status = " [missing]"
      elseif info.value and info.value ~= "" then
        local preview = info.value:sub(1, 30)
        if #info.value > 30 then
          preview = preview .. "..."
        end
        status = " - " .. preview
      end
    end
    return lang .. status
  end

  local function is_builtin_ui_select()
    local ok, info = pcall(debug.getinfo, vim.ui.select, "S")
    if not ok or not info or not info.source then
      return false
    end
    return info.source:match("vim/ui.lua") ~= nil
  end

  local function select_single_key()
    local lines = { "Select locale to edit:" }
    for i, lang in ipairs(languages) do
      lines[#lines + 1] = string.format("%d: %s", i, format_lang(lang))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Type number (1-%d) to edit (q cancels)", #languages)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = "i18n-status-review"
    vim.b[buf].i18n_status_review = true
    vim.b[buf].lsp_enabled = false
    vim.b[buf].treesitter_enabled = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local max_width = 0
    for _, line in ipairs(lines) do
      local width = vim.fn.strdisplaywidth(line)
      if width > max_width then
        max_width = width
      end
    end

    local padding = 2
    local border = (ctx.config and ctx.config.doctor and ctx.config.doctor.float and ctx.config.doctor.float.border)
      or "rounded"
    local win_width = math.min(max_width + padding, vim.o.columns - 4)
    local win_height = math.min(#lines, vim.o.lines - 4)
    local row = math.floor((vim.o.lines - win_height) / 2)
    local col = math.floor((vim.o.columns - win_width) / 2)

    local prev_win = vim.api.nvim_get_current_win()
    local win = create_float_win(buf, win_width, win_height, row, col, border, true, "I18nDoctor - Edit", "center")
    vim.api.nvim_set_current_win(win)

    local function close_float()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
    end

    local function accept(index)
      close_float()
      edit_lang(ctx, languages[index])
    end

    for i = 1, #languages do
      vim.keymap.set("n", tostring(i), function()
        accept(i)
      end, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "q", close_float, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "Q", close_float, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close_float, { buffer = buf, nowait = true, silent = true })
  end

  if is_builtin_ui_select() and #languages <= 9 then
    select_single_key()
    return
  end

  local add_blank_line = is_builtin_ui_select()
  local last_lang = languages[#languages]

  vim.ui.select(languages, {
    prompt = "Select locale to edit:",
    format_item = function(lang)
      local label = format_lang(lang)
      if add_blank_line and lang == last_lang then
        label = label .. "\n"
      end
      return label
    end,
  }, function(selected_lang)
    if not selected_lang then
      return
    end
    edit_lang(ctx, selected_lang)
  end)
end

---@param ctx table
local function rename_item(ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  local source_buf = ctx.source_buf or vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = "Rename i18n key", default = item.key }, function(input)
    if not input or util.trim(input) == "" or input == item.key then
      return
    end
    local ok, err = ops.rename({
      item = item,
      source_buf = source_buf,
      new_key = input,
      config = ctx.config,
    })
    if not ok then
      if err then
        vim.notify("i18n-status review: " .. err, vim.log.levels.WARN)
      end
      return
    end
    if ctx.is_doctor_review then
      local doctor = require("i18n-status.doctor")
      ctx.issues = doctor.refresh(ctx, { full = true })
      refresh_doctor_items(ctx)
    end
  end)
end

---Write a single translation value to a language file
---@param namespace string Namespace
---@param key_path string Key path within namespace
---@param lang string Language code
---@param value string Translation value
---@param root string Project root directory
---@return boolean success
local function write_single_translation(namespace, key_path, lang, value, root)
  local path = resources.namespace_path(root, lang, namespace)
  if not path then
    return false
  end

  if not util.ensure_dir(util.dirname(path)) then
    return false
  end

  local data, style = resources.read_json_table(path)
  if not data then
    return false
  end

  local path_in_file = resources.key_path_for_file(namespace, key_path, root, lang, path)
  util.set_nested(data, path_in_file, value)
  resources.write_json_table(path, data, style)
  return true
end

---Write translations to all language files and notify results
---@param namespace string Namespace
---@param key_path string Key path within namespace
---@param translations table<string, string> Language to value mapping
---@param root string Project root directory
---@param languages string[] List of languages
---@param full_key string Full key name for notification
---@return integer success_count
---@return string[] failed_langs
local function write_translations_to_files(namespace, key_path, translations, root, languages, full_key)
  local success_count = 0
  local failed_langs = {}

  for _, lang in ipairs(languages) do
    if write_single_translation(namespace, key_path, lang, translations[lang], root) then
      success_count = success_count + 1
    else
      table.insert(failed_langs, lang)
    end
  end

  if success_count == #languages then
    vim.notify("Successfully added key: " .. full_key, vim.log.levels.INFO)
  elseif success_count > 0 then
    vim.notify(
      string.format(
        "Partially added: %d/%d languages (%s failed)",
        success_count,
        #languages,
        table.concat(failed_langs, ", ")
      ),
      vim.log.levels.WARN
    )
  else
    vim.notify("Failed to add key", vim.log.levels.ERROR)
  end

  return success_count, failed_langs
end

---Collect translations for all languages sequentially via vim.ui.input
---@param full_key string Full key name to display in prompts
---@param languages string[] List of languages
---@param on_complete fun(translations: table<string, string>) Callback when all translations collected
local function collect_translations(full_key, languages, on_complete)
  local translations = {}
  local current_index = 1

  local function prompt_next()
    if current_index > #languages then
      on_complete(translations)
      return
    end

    local lang = languages[current_index]
    local prompt = string.format("Add key: %s\nLocale: %s\n\nValue: ", full_key, lang)

    vim.ui.input({ prompt = prompt, default = "" }, function(input)
      if input == nil then
        return
      end
      translations[lang] = input
      current_index = current_index + 1
      prompt_next()
    end)
  end

  prompt_next()
end

---Add missing key across all languages
---@param ctx table Review context
local function add_key(ctx)
  local item = ctx.detail_item
  if not item then
    return
  end
  if item.status ~= "×" then
    vim.notify("Key already exists in primary language", vim.log.levels.WARN)
    return
  end

  local languages = ctx.cache and ctx.cache.languages or {}
  if #languages == 0 then
    vim.notify("No languages available", vim.log.levels.WARN)
    return
  end

  local root = resources.start_dir(ctx.source_buf or vim.api.nvim_get_current_buf())
  local namespace = item.key:match("^(.-):") or resources.fallback_namespace(root)
  local key_path = item.key:match("^[^:]+:(.+)$") or ""

  collect_translations(item.key, languages, function(translations)
    write_translations_to_files(namespace, key_path, translations, root, languages, item.key)

    if ctx.config then
      core.refresh_all(ctx.config)
    end
    if ctx.is_doctor_review then
      local doctor = require("i18n-status.doctor")
      ctx.issues = doctor.refresh(ctx)
      refresh_doctor_items(ctx)
    end
  end)
end

---Validate key name for I18nAddKey command
---@param key string Key name to validate
---@return boolean valid Whether the key is valid
---@return string|nil error_msg Error message if invalid
local function validate_key_name(key)
  if not key or util.trim(key) == "" then
    return false, "Key name cannot be empty"
  end

  local colon_pos = key:find(":")
  local second_colon = colon_pos and key:find(":", colon_pos + 1)
  if second_colon then
    return false, "Key name can only contain one ':' separator"
  end

  local namespace = colon_pos and key:sub(1, colon_pos - 1)
  local key_path = colon_pos and key:sub(colon_pos + 1) or key

  if namespace then
    if namespace == "" then
      return false, "Namespace cannot be empty"
    end
    if not namespace:match("^[%w_%-%.]+$") then
      return false, "Namespace can only contain alphanumeric characters, '_', '-', and '.'"
    end
  end

  if not key_path or key_path == "" then
    return false, "Key path cannot be empty"
  end

  if key_path:match("^%.") or key_path:match("%.$") then
    return false, "Key path cannot start or end with a dot"
  end

  if key_path:match("%.%.") then
    return false, "Key path cannot contain consecutive dots"
  end

  if not key_path:match("^[%w_%-%.]+$") then
    return false, "Key path can only contain alphanumeric characters, '_', '-', and '.'"
  end

  return true, nil
end

---Check if a key exists in the cache index
---@param cache table Resource cache
---@param full_key string Full key name
---@return boolean
local function key_exists_in_cache(cache, full_key)
  if not cache or not cache.index then
    return false
  end
  for _, entries in pairs(cache.index) do
    if entries[full_key] then
      return true
    end
  end
  return false
end

---Validate translations have no empty values
---@param translations table<string, string> Language to value mapping
---@param languages string[] List of languages
---@return boolean valid
local function validate_translations_non_empty(translations, languages)
  for _, lang in ipairs(languages) do
    if not translations[lang] or util.trim(translations[lang]) == "" then
      vim.notify("All language values must be provided (empty values not allowed)", vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---Add a new key from command (I18nAddKey)
---@param cfg I18nStatusConfig Config
function M.add_key_command(cfg)
  if not cfg then
    vim.notify("i18n-status: not configured", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local root = resources.start_dir(bufnr)
  local cache = resources.ensure_index(root)
  local languages = cache and cache.languages or {}

  if #languages == 0 then
    vim.notify("No languages available", vim.log.levels.WARN)
    return
  end

  local fallback_ns = resources.fallback_namespace(root)
  local prompt_msg = string.format("Add key (namespace omitted → %s): ", fallback_ns)

  vim.ui.input({ prompt = prompt_msg }, function(key_input)
    if not key_input then
      return
    end

    local key = util.trim(key_input)
    local valid, err_msg = validate_key_name(key)
    if not valid then
      vim.notify(err_msg, vim.log.levels.ERROR)
      return
    end

    local full_key = key:match(":") and key or (fallback_ns .. ":" .. key)
    local namespace = full_key:match("^(.-):")
    local key_path = full_key:match("^[^:]+:(.+)$") or ""

    local function do_add_key()
      collect_translations(full_key, languages, function(translations)
        if not validate_translations_non_empty(translations, languages) then
          return
        end
        write_translations_to_files(namespace, key_path, translations, root, languages, full_key)
        core.refresh_all(cfg)
      end)
    end

    if key_exists_in_cache(cache, full_key) then
      local confirm_msg = string.format("Key already exists: %s\nOverwrite in all languages? (y/N)", full_key)
      vim.ui.input({ prompt = confirm_msg }, function(confirm)
        if confirm and confirm:lower() == "y" then
          do_add_key()
        end
      end)
    else
      do_add_key()
    end
  end)
end

---@param ctx table
local function jump_to_definition(ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  if ctx.is_doctor_review and ctx.mode == MODE_OVERVIEW then
    local function pick_info(lang)
      return item.hover and item.hover.values and item.hover.values[lang]
    end

    local info = nil
    if ctx.display_lang and ctx.display_lang ~= "" then
      info = pick_info(ctx.display_lang)
    end
    if not info or not info.file then
      if ctx.primary_lang and ctx.primary_lang ~= "" then
        info = pick_info(ctx.primary_lang)
      end
    end
    if (not info or not info.file) and item.hover and item.hover.values then
      for _, v in pairs(item.hover.values) do
        if v and v.file then
          info = v
          break
        end
      end
    end
    if not info or not info.file then
      vim.notify("i18n-status review: definition file not found", vim.log.levels.WARN)
      return
    end

    close_review(ctx)
    vim.api.nvim_cmd({ cmd = "edit", args = { info.file } }, {})
    return
  end

  local project = ctx.project_key and state.project_for_key(ctx.project_key)
  local focus_lang = (project and project.current_lang)
    or (project and project.primary_lang)
    or (ctx.config and ctx.config.primary_lang)
  if not focus_lang or focus_lang == "" then
    return
  end

  local info = item.hover and item.hover.values and item.hover.values[focus_lang]
  if not info or not info.file then
    vim.notify("i18n-status review: definition file not found", vim.log.levels.WARN)
    return
  end

  -- Close the review UI
  close_review(ctx)

  -- Open the file
  vim.api.nvim_cmd({ cmd = "edit", args = { info.file } }, {})
end

---@param ctx table
local function update_section_counts(view)
  if not view or not view.section_state or not view.section_items then
    return
  end
  for status, items in pairs(view.section_items) do
    if view.section_state[status] then
      view.section_state[status].count = #items
    end
  end
end

---@param ctx table
local function apply_view(ctx, view)
  if not view then
    return
  end
  ctx.items = view.items or {}
  ctx.section_items = view.section_items or {}
  ctx.section_state = view.section_state or {}
  ctx.section_order = view.section_order
  ctx.section_labels = view.section_labels
  ctx.summary_labels = view.summary_labels
end

---@param ctx table
local function refresh_problems(ctx)
  local view = ctx.views and ctx.views[MODE_PROBLEMS]
  if not view then
    return
  end
  view.items = aggregate_issues_by_key(ctx.issues or {}, ctx.cache, ctx.primary_lang, ctx.display_lang)
  view.section_items = group_items_for_problems(view.items)
  view.section_order = PROBLEMS_SECTION_ORDER
  view.section_labels = PROBLEMS_SECTION_LABELS
  view.summary_labels = PROBLEMS_SUMMARY_LABELS
  view.dirty = false
  update_section_counts(view)
end

---@param ctx table
local function refresh_overview(ctx)
  local view = ctx.views and ctx.views[MODE_OVERVIEW]
  if not view then
    return
  end
  if not view.dirty and view.items then
    return
  end
  local keys = collect_all_keys(ctx)
  view.items = build_resolved_items(keys, ctx.cache, ctx.primary_lang, ctx.display_lang)
  view.section_items = group_items_by_status(view.items)
  view.section_order = STATUS_SECTION_ORDER
  view.section_labels = STATUS_SECTION_LABELS
  view.summary_labels = STATUS_SUMMARY_LABELS
  view.dirty = false
  update_section_counts(view)
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
  apply_view(ctx, view)
  render_list(ctx.list_buf, ctx)
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
  apply_view(ctx, view)
  render_list(ctx.list_buf, ctx)
  update_detail(ctx)
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
    render_list(ctx.list_buf, ctx)

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
  local function map(lhs, handler, opts)
    opts = opts or {}
    vim.keymap.set("n", lhs, function()
      local ctx = review_state[buf]
      if not ctx then
        return
      end
      -- Close help window before executing action (except for help toggle and close actions)
      if opts.close_help ~= false then
        close_keymap_help(ctx)
      end
      if opts.update ~= false then
        update_detail(ctx)
      end
      handler(ctx)
    end, { buffer = buf, silent = true, nowait = true })
  end

  map("q", close_review, { update = false, close_help = false })
  map("<Esc>", close_review, { update = false, close_help = false })
  map("e", edit_focus)
  map("E", edit_locale_select)
  map("r", rename_item)
  map("a", add_key)
  map("gd", jump_to_definition)
  map("<Tab>", toggle_mode, { update = false })
  map("<Space>", toggle_section, { update = true })
  map("<CR>", toggle_section, { update = true })
  map("?", toggle_keymap_help, { update = false, close_help = false })
end

---@param issues I18nStatusDoctorIssue[]
---@param ctx table from doctor
---@param config I18nStatusConfig
function M.open_doctor_results(issues, ctx, config)
  -- Save the current window to return to when closing
  local source_win = vim.api.nvim_get_current_win()

  local list_buf = vim.api.nvim_create_buf(false, true)
  local detail_buf = vim.api.nvim_create_buf(false, true)

  ensure_review_highlights()

  for _, buf in ipairs({ list_buf, detail_buf }) do
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "i18n-status-review"
    vim.b[buf].i18n_status_review = true

    -- Disable LSP and Treesitter to prevent unnecessary attachment and cleanup
    vim.b[buf].lsp_enabled = false
    vim.b[buf].treesitter_enabled = false
  end

  local float_config = (config and config.doctor and config.doctor.float)
    or {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    }

  local win_width, win_height, row, col = calculate_float_dimensions(float_config)

  -- Split the width: 40% for list, 60% for detail
  local list_width = math.floor(win_width * 0.4)
  local detail_width = win_width - list_width

  local border = float_config.border or "rounded"

  -- Calculate border offset (most border styles use 2 chars for left+right borders)
  local border_offset = (border == "none" or border == "shadow") and 0 or 2

  local list_win =
    create_float_win(list_buf, list_width, win_height, row, col, border, true, "I18nDoctor - Key List", "center")
  local detail_win = create_float_win(
    detail_buf,
    detail_width - border_offset,
    win_height,
    row,
    col + list_width + border_offset,
    border,
    false,
    "I18nDoctor - Preview",
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
  vim.wo[list_win].winbar = build_review_winbar(list_width, MODE_PROBLEMS)

  vim.wo[detail_win].winhighlight = table.concat({
    "Normal:I18nStatusReviewDetailNormal",
    "NormalFloat:I18nStatusReviewDetailNormal",
    "FloatBorder:I18nStatusReviewBorder",
    "FloatTitle:I18nStatusReviewTitle",
  }, ",")
  vim.wo[detail_win].cursorline = false

  state.set_languages(ctx.cache.key, ctx.cache.languages)
  local project = state.project_for_key(ctx.cache.key)
  local primary = (project and project.primary_lang) or config.primary_lang or (ctx.cache.languages[1] or "")
  local display_lang = (project and project.current_lang) or primary
  local problems_items = aggregate_issues_by_key(issues, ctx.cache, primary, display_lang)
  local problems_section_items = group_items_for_problems(problems_items)
  local problems_section_state = new_section_state(PROBLEMS_SECTION_ORDER)
  local overview_section_state = new_section_state(STATUS_SECTION_ORDER)
  local views = {
    [MODE_PROBLEMS] = {
      items = problems_items,
      section_items = problems_section_items,
      section_state = problems_section_state,
      section_order = PROBLEMS_SECTION_ORDER,
      section_labels = PROBLEMS_SECTION_LABELS,
      summary_labels = PROBLEMS_SUMMARY_LABELS,
      dirty = false,
    },
    [MODE_OVERVIEW] = {
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
    list_buf = list_buf,
    detail_buf = detail_buf,
    list_win = list_win,
    detail_win = detail_win,
    config = config or config_mod.setup({}),
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

  render_list(list_buf, review_ctx)
  render_detail(review_ctx)

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
      if vim.api.nvim_win_is_valid(list_win) then
        local current_width = vim.api.nvim_win_get_width(list_win)
        local current = review_state[list_buf]
        local mode = current and current.mode or MODE_PROBLEMS
        vim.wo[list_win].winbar = build_review_winbar(current_width, mode)
      end
    end,
  })

  vim.api.nvim_set_current_win(list_win)

  return review_ctx
end

M.is_doctor_open = is_doctor_open

return M
