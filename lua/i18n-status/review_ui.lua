---@class I18nStatusReviewUi
local M = {}

local highlights_ready = false
local hl_cache = {}

M.MODE_PROBLEMS = "problems"
M.MODE_OVERVIEW = "overview"

M.STATUS_SECTION_ORDER = { "×", "!", "?", "≠", "=" }
M.STATUS_SECTION_LABELS = {
  ["×"] = "Missing",
  ["!"] = "Mismatch",
  ["?"] = "Fallback",
  ["≠"] = "Localized",
  ["="] = "Same",
}
M.STATUS_SUMMARY_LABELS = {
  ["×"] = "missing",
  ["!"] = "mismatch",
  ["?"] = "fallback",
  ["≠"] = "localized",
  ["="] = "same",
}

M.PROBLEMS_SECTION_ORDER = { "unused", "×", "!", "?", "≠", "=" }
M.PROBLEMS_SECTION_LABELS = {
  unused = "Unused",
  ["×"] = "Missing",
  ["!"] = "Mismatch",
  ["?"] = "Fallback",
  ["≠"] = "Localized",
  ["="] = "Same",
}
M.PROBLEMS_SUMMARY_LABELS = {
  unused = "unused",
  ["×"] = "missing",
  ["!"] = "mismatch",
  ["?"] = "fallback",
  ["≠"] = "localized",
  ["="] = "same",
}

local status_highlights = {
  ["="] = "I18nStatusReviewStatusOk",
  ["×"] = "I18nStatusReviewStatusMissing",
  ["?"] = "I18nStatusReviewStatusFallback",
  ["≠"] = "I18nStatusReviewStatusLocalized",
  ["!"] = "I18nStatusReviewStatusMismatch",
}

---@param name string
---@return boolean
local function hl_exists(name)
  if hl_cache[name] ~= nil then
    return hl_cache[name]
  end

  local ok = pcall(vim.api.nvim_get_hl, 0, { name = name })
  hl_cache[name] = ok
  return ok
end

---@vararg string
---@return string
local function choose_hl(...)
  local candidates = { ... }
  for _, candidate in ipairs(candidates) do
    if candidate and hl_exists(candidate) then
      return candidate
    end
  end
  return "Normal"
end

---@param group string
---@vararg string
local function define_hl(group, ...)
  vim.api.nvim_set_hl(0, group, { default = true, link = choose_hl(...) })
end

local function mode_label(mode)
  if mode == M.MODE_OVERVIEW then
    return "Overview"
  end
  return "Problems"
end

-- Reset highlight cache on colorscheme updates.
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    hl_cache = {}
    highlights_ready = false
  end,
})

function M.ensure_review_highlights()
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

  highlights_ready = true
end

---@param status I18nStatusString|nil
---@return string
function M.highlight_for_status(status)
  return status_highlights[status] or "I18nStatusReviewStatusDefault"
end

---@param list_width integer
---@param mode string|nil
---@param filter_query string|nil
---@return string
function M.build_review_winbar(list_width, mode, filter_query)
  local available_width = math.max(list_width - 4, 20)
  local header = " I18nDoctor [" .. mode_label(mode) .. "] "
  local normalized_query = filter_query and vim.trim(filter_query) or nil
  if normalized_query and normalized_query ~= "" then
    local with_filter = header .. "[/" .. normalized_query .. "] "
    if vim.fn.strdisplaywidth(with_filter) <= available_width then
      header = with_filter
    end
  end

  local full_keymaps =
    " q:quit │ /:filter │ e:edit │ E:locale │ r:rename │ a:add │ Tab:mode │ gd:goto │ Space:toggle │ ?:help "
  local medium_keymaps = " q:quit │ /:filter │ e:edit │ E:locale │ a:add │ Tab:mode │ ?:help "
  local short_keymaps = " q:quit │ Tab:mode │ ?:help "

  local header_width = vim.fn.strdisplaywidth(header)
  local full_width = vim.fn.strdisplaywidth(full_keymaps)
  local medium_width = vim.fn.strdisplaywidth(medium_keymaps)

  local keymaps
  if header_width + full_width + 2 <= available_width then
    keymaps = full_keymaps
  elseif header_width + medium_width + 2 <= available_width then
    keymaps = medium_keymaps
  else
    keymaps = short_keymaps
  end

  return "%#I18nStatusReviewHeader#" .. header .. "%*" .. "%=" .. "%#I18nStatusReviewMeta#" .. keymaps .. "%*"
end

---@param float_config I18nStatusReviewFloatConfig
---@return integer, integer, integer, integer
function M.calculate_float_dimensions(float_config)
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
---@param title string|nil
---@param title_pos string|nil
---@return integer
function M.create_float_win(buf, width, height, row, col, border, focusable, title, title_pos)
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

  if title then
    win_config.title = title
    win_config.title_pos = title_pos or "center"
  end

  return vim.api.nvim_open_win(buf, false, win_config)
end

return M
