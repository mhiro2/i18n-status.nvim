---@class I18nStatusUI
local M = {}

local fs = require("i18n-status.fs")

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
        local shortened_path = fs.shorten_path(info.file)
        file = " (`" .. shortened_path .. "`)"
      end
      table.insert(lines, "- " .. md_escape(lang) .. ": " .. value .. suffix .. file)
    end
  end

  local placeholders = item.hover and item.hover.status == "!" and item.hover.placeholders
  if placeholders then
    local primary = item.hover.primary_lang
    table.insert(lines, "")
    table.insert(lines, "## Placeholders")
    -- The core reports the primary language and every mismatched language.
    local placeholder_langs = { primary }
    for _, lang in ipairs(order) do
      if lang ~= primary then
        table.insert(placeholder_langs, lang)
      end
    end
    for _, lang in ipairs(placeholder_langs) do
      local names = placeholders[lang]
      if names then
        local listed = #names > 0 and md_escape_join(names, ", ") or "(none)"
        table.insert(lines, "- " .. md_escape(lang) .. ": " .. listed)
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
