---@class I18nStatusReviewSharedUi
local M = {}

local DEFAULT_HELP_WINHIGHLIGHT = table.concat({
  "Normal:I18nStatusReviewDetailNormal",
  "NormalFloat:I18nStatusReviewDetailNormal",
  "FloatBorder:I18nStatusReviewBorder",
}, ",")

---@class I18nStatusKeymapHelpEntry
---@field keys string
---@field desc string

---@class I18nStatusHelpFloatOptions
---@field title string
---@field filetype string
---@field keymaps I18nStatusKeymapHelpEntry[]
---@field border string|nil
---@field winhighlight string|nil
---@field focusable boolean|nil
---@field zindex integer|nil

---@class I18nStatusFilterNormalizeOptions
---@field lowercase boolean|nil

---@class I18nStatusFilterPromptOptions
---@field prompt string
---@field default string|nil
---@field lowercase boolean|nil
---@field skip fun(ctx: table): boolean|nil
---@field on_confirm fun(ctx: table, normalized: string|nil, raw_input: string)

---@class I18nStatusContextKeymapBinding
---@field lhs string
---@field handler fun(ctx: table)
---@field nowait boolean|nil
---@field silent boolean|nil
---@field close_help boolean|nil
---@field update boolean|nil
---@field desc string|nil

---@class I18nStatusContextKeymapOptions
---@field bufnr integer
---@field state table<integer, table>
---@field bindings I18nStatusContextKeymapBinding[]
---@field mode string|string[]|nil
---@field before fun(ctx: table, binding: I18nStatusContextKeymapBinding)|nil

---@param title string
---@param keymaps I18nStatusKeymapHelpEntry[]
---@return string[]
function M.build_keymap_help_lines(title, keymaps)
  local safe_title = type(title) == "string" and title or "keymaps"
  local entries = keymaps or {}
  local divider = string.rep("-", #safe_title)
  local max_key = 0
  for _, entry in ipairs(entries) do
    max_key = math.max(max_key, vim.fn.strdisplaywidth(entry.keys or ""))
  end
  local format = " %-" .. max_key .. "s  %s "
  local lines = { " " .. safe_title .. " ", " " .. divider .. " " }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format(format, entry.keys or "", entry.desc or "")
  end
  return lines
end

---@param lines string[]
---@return integer
---@return integer
---@return integer
---@return integer
local function centered_help_dimensions(lines)
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

  return win_width, win_height, row, col
end

---@param ctx table|nil
function M.close_help_window(ctx)
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

---@param ctx table
---@param opts I18nStatusHelpFloatOptions
---@return integer|nil
---@return integer|nil
function M.open_help_window(ctx, opts)
  if not ctx or type(opts) ~= "table" then
    return nil, nil
  end

  M.close_help_window(ctx)

  local lines = M.build_keymap_help_lines(opts.title, opts.keymaps or {})
  local win_width, win_height, row, col = centered_help_dimensions(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = opts.filetype or "i18n-status-review-help"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    border = opts.border or "rounded",
    style = "minimal",
    focusable = opts.focusable == true,
    zindex = opts.zindex or 100,
  })

  vim.wo[win].winhighlight = opts.winhighlight or DEFAULT_HELP_WINHIGHLIGHT

  ctx.help_win = win
  ctx.help_buf = buf

  return win, buf
end

---@param ctx table
---@param opts I18nStatusHelpFloatOptions
function M.toggle_help_window(ctx, opts)
  if not ctx then
    return
  end
  if ctx.help_win and vim.api.nvim_win_is_valid(ctx.help_win) then
    M.close_help_window(ctx)
    return
  end
  M.open_help_window(ctx, opts)
end

---@param query string|nil
---@param opts I18nStatusFilterNormalizeOptions|nil
---@return string|nil
function M.normalize_filter_query(query, opts)
  if type(query) ~= "string" then
    return nil
  end
  local normalized = vim.trim(query)
  if normalized == "" then
    return nil
  end
  if opts and opts.lowercase then
    return normalized:lower()
  end
  return normalized
end

---@param ctx table
---@param opts I18nStatusFilterPromptOptions
function M.prompt_filter(ctx, opts)
  if not ctx or type(opts) ~= "table" or type(opts.on_confirm) ~= "function" then
    return
  end

  vim.ui.input({ prompt = opts.prompt or "Filter: ", default = opts.default or "" }, function(input)
    if input == nil then
      return
    end
    if opts.skip and opts.skip(ctx) then
      return
    end
    local normalized = M.normalize_filter_query(input, { lowercase = opts.lowercase })
    opts.on_confirm(ctx, normalized, input)
  end)
end

---@param opts I18nStatusContextKeymapOptions
function M.bind_context_keymaps(opts)
  if type(opts) ~= "table" or type(opts.bufnr) ~= "number" then
    return
  end
  local state = opts.state
  local bindings = opts.bindings or {}
  local mode = opts.mode or "n"
  for _, binding in ipairs(bindings) do
    if type(binding) == "table" and type(binding.lhs) == "string" and type(binding.handler) == "function" then
      vim.keymap.set(mode, binding.lhs, function()
        local ctx = state and state[opts.bufnr]
        if not ctx then
          return
        end
        if opts.before then
          opts.before(ctx, binding)
        end
        binding.handler(ctx)
      end, {
        buffer = opts.bufnr,
        silent = binding.silent ~= false,
        nowait = binding.nowait ~= false,
        desc = binding.desc,
      })
    end
  end
end

return M
