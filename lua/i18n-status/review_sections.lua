---@class I18nStatusReviewSections
local M = {}

---@param section_order string[]|nil
---@return table<string, { expanded: boolean, count?: integer }>
function M.new_section_state(section_order)
  local sections = {}
  for _, section in ipairs(section_order or {}) do
    sections[section] = { expanded = true }
  end
  return sections
end

---@param items I18nStatusResolved[]|nil
---@param section_order string[]
---@param default_status string
---@return table<string, I18nStatusResolved[]>
function M.group_items_by_status(items, section_order, default_status)
  local groups = {}
  for _, status in ipairs(section_order or {}) do
    groups[status] = {}
  end

  local fallback = default_status or section_order[1]
  for _, item in ipairs(items or {}) do
    local status = item.status or fallback
    if not groups[status] then
      status = fallback
    end
    groups[status] = groups[status] or {}
    groups[status][#groups[status] + 1] = item
  end

  return groups
end

---@param items I18nStatusResolved[]|nil
---@param section_order string[]
---@param status_order string[]
---@param default_status string
---@return table<string, I18nStatusResolved[]>
function M.group_problem_items(items, section_order, status_order, default_status)
  local groups = { unused = {} }
  local problem_items = {}
  for _, item in ipairs(items or {}) do
    if item.unused then
      groups.unused[#groups.unused + 1] = item
    else
      problem_items[#problem_items + 1] = item
    end
  end
  local grouped = M.group_items_by_status(problem_items, status_order, default_status)

  for _, section in ipairs(section_order or {}) do
    if section ~= "unused" then
      groups[section] = grouped[section] or {}
    end
  end

  return groups
end

---@param section_items table<string, I18nStatusResolved[]>
---@param section_order string[]|nil
---@param summary_labels table<string, string>|nil
---@return string
function M.calculate_summary(section_items, section_order, summary_labels)
  local total = 0
  for _, items in pairs(section_items or {}) do
    total = total + #items
  end

  local parts = {}
  for _, status in ipairs(section_order or {}) do
    local count = #((section_items or {})[status] or {})
    if count > 0 then
      local label = (summary_labels or {})[status] or status
      parts[#parts + 1] = label .. ": " .. count
    end
  end

  if #parts == 0 then
    return "Total: 0 keys"
  end
  return string.format("Total: %d keys  (%s)", total, table.concat(parts, "  "))
end

---@param view I18nStatusReviewView|nil
function M.update_section_counts(view)
  if not view or not view.section_state or not view.section_items then
    return
  end
  for status, items in pairs(view.section_items) do
    if view.section_state[status] then
      view.section_state[status].count = #items
    end
  end
end

---@param ctx I18nStatusReviewCtx
---@param view I18nStatusReviewView|nil
function M.apply_view(ctx, view)
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

---@class I18nStatusReviewRebuildOptions
---@field mode_overview string
---@field filter fun(items: I18nStatusResolved[]|nil, query: string|nil): I18nStatusResolved[]
---@field group_overview fun(items: I18nStatusResolved[]|nil): table<string, I18nStatusResolved[]>
---@field group_problems fun(items: I18nStatusResolved[]|nil): table<string, I18nStatusResolved[]>

---@param view I18nStatusReviewView|nil
---@param mode "problems"|"overview"
---@param filter_query string|nil
---@param opts I18nStatusReviewRebuildOptions
function M.rebuild_view(view, mode, filter_query, opts)
  if not view then
    return
  end

  local filtered = opts.filter(view.all_items, filter_query)
  view.items = filtered
  if mode == opts.mode_overview then
    view.section_items = opts.group_overview(filtered)
  else
    view.section_items = opts.group_problems(filtered)
  end
  M.update_section_counts(view)
end

return M
