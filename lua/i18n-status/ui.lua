---@class I18nStatusUI
local M = {}

local util = require("i18n-status.util")

---@alias UiMenuItem { label: string, action: string }|string

---@class UiSelectOptions
---@field prompt? string
---@field format_item? fun(item: UiMenuItem): string

---@param items UiMenuItem[]
---@param opts UiSelectOptions
---@param on_choice fun(item: UiMenuItem|nil)
function M.select(items, opts, on_choice)
  opts = opts or {}
  local format_item = opts.format_item
  if not format_item then
    format_item = function(item)
      if type(item) == "table" then
        return item.label or item.action or vim.inspect(item)
      end
      if item == nil then
        return ""
      end
      return tostring(item)
    end
    opts.format_item = format_item
  end

  local has_telescope, telescope = pcall(require, "telescope.pickers")
  if has_telescope and telescope then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local pickers = require("telescope.pickers")
    local entry_maker = function(item)
      local formatted = format_item(item)
      return {
        value = item,
        display = formatted,
        ordinal = formatted,
      }
    end
    pickers
      .new({}, {
        prompt_title = opts.prompt or "select",
        finder = finders.new_table({ results = items, entry_maker = entry_maker }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          local actions = require("telescope.actions")
          local action_state = require("telescope.actions.state")
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            on_choice(selection and selection.value or nil)
          end)
          return true
        end,
      })
      :find()
    return
  end

  vim.ui.select(items, opts, on_choice)
end

---@class FormatHoverLinesOptions
---@field include_actions? boolean

---Escape Markdown special characters to prevent formatting issues
---@param s string
---@return string
local function md_escape(s)
  return (s:gsub("([`|*_%[%]])", "\\%1"))
end

---Escape each element in an array and join them
---@param arr string[]
---@param sep string
---@return string
local function md_escape_join(arr, sep)
  local escaped = {}
  for i, v in ipairs(arr) do
    escaped[i] = md_escape(v)
  end
  return table.concat(escaped, sep)
end

---@param item I18nStatusResolved
---@param opts? FormatHoverLinesOptions
---@return string[]
function M.format_hover_lines(item, opts)
  opts = opts or {}
  local include_actions = opts.include_actions == true
  local lines = {}
  table.insert(lines, "**" .. md_escape(item.key) .. "**")
  table.insert(lines, "")
  if item.hover and item.hover.namespace then
    table.insert(lines, "- namespace: `" .. item.hover.namespace .. "`")
  end
  if item.hover and item.hover.status then
    table.insert(lines, "- status: `[" .. item.hover.status .. "]`")
  end
  if item.hover and item.hover.reason then
    table.insert(lines, "- reason: `" .. item.hover.reason .. "`")
  end
  -- Show focus comparison (primary vs current) if different
  if
    item.hover
    and item.hover.focus_lang
    and item.hover.primary_lang
    and item.hover.focus_lang ~= item.hover.primary_lang
  then
    table.insert(lines, "- focus: `" .. item.hover.primary_lang .. " vs " .. item.hover.focus_lang .. "`")
  end
  if item.hover and item.hover.missing_langs and #item.hover.missing_langs > 0 then
    table.insert(lines, "- fallback_langs: `" .. table.concat(item.hover.missing_langs, ", ") .. "`")
  end
  if item.hover and item.hover.localized_langs and #item.hover.localized_langs > 0 then
    table.insert(lines, "- localized_langs (vs primary): `" .. table.concat(item.hover.localized_langs, ", ") .. "`")
  end
  if item.hover and item.hover.mismatch_langs and #item.hover.mismatch_langs > 0 then
    table.insert(lines, "- mismatch_langs: `" .. table.concat(item.hover.mismatch_langs, ", ") .. "`")
  end

  table.insert(lines, "")
  table.insert(lines, "## Translations")

  local order = (item.hover and item.hover.lang_order) or {}
  if #order == 0 and item.hover and item.hover.values then
    for lang, _ in pairs(item.hover.values) do
      table.insert(order, lang)
    end
    table.sort(order)
  end
  for _, lang in ipairs(order) do
    local info = item.hover and item.hover.values and item.hover.values[lang]
    if info then
      local value = md_escape(info.value or "")
      local suffix = ""
      if info.missing then
        suffix = " (missing)"
      end
      local file = ""
      if info.file then
        local shortened_path = util.shorten_path(info.file)
        file = " (`" .. shortened_path .. "`)"
      end
      table.insert(lines, "- " .. md_escape(lang) .. ": " .. value .. suffix .. file)
    end
  end

  if item.hover and item.hover.status == "!" then
    local primary = item.hover.primary_lang
    local primary_info = item.hover.values and item.hover.values[primary]
    if primary_info then
      local base = util.extract_placeholders(primary_info.value or "")
      local base_list = {}
      for name, _ in pairs(base) do
        table.insert(base_list, name)
      end
      table.sort(base_list)
      table.insert(lines, "")
      table.insert(lines, "## Placeholders")
      table.insert(lines, "- " .. md_escape(primary) .. ": " .. md_escape_join(base_list, ", "))
      for _, lang in ipairs(order) do
        if lang ~= primary then
          local info = item.hover.values and item.hover.values[lang]
          local current = util.extract_placeholders(info and info.value or "")
          if not util.placeholder_equal(base, current) then
            local list = {}
            for name, _ in pairs(current) do
              table.insert(list, name)
            end
            table.sort(list)
            table.insert(lines, "- " .. md_escape(lang) .. ": " .. md_escape_join(list, ", "))
          end
        end
      end
    end
  end

  -- Add action hints only if requested
  if include_actions then
    table.insert(lines, "")
    table.insert(lines, "## Actions")
    table.insert(lines, "- `e`: Edit focus language")
    table.insert(lines, "- `E`: Edit primary language")
    table.insert(lines, "- `r`: Rename key")
    table.insert(lines, "- `gd`: Open definition file")
    table.insert(lines, "- `<Tab>`: Switch panes")
  end

  return lines
end

---@class UiHoverOptions
---@field border? string
---@field focus_id? string

---@param lines string[]
---@param opts? UiHoverOptions
function M.open_hover(lines, opts)
  local lsp_util = vim.lsp.util
  local options = opts or {}
  if not options.border then
    options.border = "rounded"
  end
  options.focus_id = options.focus_id or "i18n-status-hover"
  lsp_util.open_floating_preview(lines, "markdown", options)
end

return M
