---@class I18nStatusResolve
local M = {}

local util = require("i18n-status.util")

---@alias I18nStatusString "="|"≠"|"?"|"×"|"!"

---@class I18nStatusHoverValue
---@field value string|nil
---@field file string|nil
---@field missing boolean

---@class I18nStatusHoverInfo
---@field key string
---@field namespace string|nil
---@field status I18nStatusString|nil
---@field reason string|nil
---@field primary_lang string
---@field display_lang string
---@field focus_lang string
---@field lang_order string[]
---@field values table<string, I18nStatusHoverValue>
---@field missing_langs string[]|nil
---@field localized_langs string[]|nil
---@field mismatch_langs string[]|nil

---@class I18nStatusResolved
---@field key string
---@field text string
---@field status I18nStatusString
---@field hover I18nStatusHoverInfo

---@param value string|nil
---@param key string|nil
---@param raw string|nil
---@return boolean
local function is_missing(value, key, raw)
  if value == nil or value == "" then
    return true
  end
  if raw and value == raw then
    return true
  end
  if key and value == key then
    return true
  end
  if key then
    local key_path = key:match("^[^:]+:(.+)$")
    if key_path and value == key_path then
      return true
    end
  end
  return false
end

---@param index table
---@param lang string
---@param key string
---@return I18nStatusResourceItem|nil
local function safe_index_get(index, lang, key)
  if not index or type(index) ~= "table" then
    return nil
  end
  local lang_table = index[lang]
  if not lang_table or type(lang_table) ~= "table" then
    return nil
  end
  return lang_table[key]
end

---@param primary string
---@param others table
---@return boolean
---@return string[]
local function placeholder_mismatch_langs(primary, others)
  local base = util.extract_placeholders(primary or "")
  local mismatches = {}
  for _, item in pairs(others) do
    if item and item.value then
      local current = util.extract_placeholders(item.value)
      if not util.placeholder_equal(base, current) then
        table.insert(mismatches, item.lang or "")
      end
    end
  end
  return #mismatches > 0, mismatches
end

---@param item I18nStatusScanItem
---@return I18nStatusResolved
local function make_invalid_result(item)
  return {
    key = item.key,
    text = item.raw or item.key,
    status = "×",
    hover = { key = item.key, status = "×", reason = "invalid_index" },
  }
end

---@param items I18nStatusScanItem[]
---@param state I18nStatusState
---@param index table
---@return I18nStatusResolved[]
function M.compute(items, state, index)
  local resolved = {}

  if not index or type(index) ~= "table" then
    for _, item in ipairs(items) do
      table.insert(resolved, make_invalid_result(item))
    end
    return resolved
  end

  local languages = state.languages or {}
  local primary = state.primary_lang

  -- Build lang_order once outside the items loop
  local lang_order = { primary }
  for _, lang in ipairs(languages) do
    if lang ~= primary then
      table.insert(lang_order, lang)
    end
  end

  for _, item in ipairs(items) do
    local key = item.key
    local display_lang = state.current_lang or primary
    local primary_item = safe_index_get(index, primary, key)
    local primary_value = primary_item and primary_item.value or nil
    local display_item = safe_index_get(index, display_lang, key)
    local display_value = display_item and display_item.value or primary_value
    local hover = {
      key = key,
      namespace = item.namespace,
      status = nil,
      reason = nil,
      primary_lang = primary,
      display_lang = display_lang,
      focus_lang = display_lang,
      lang_order = lang_order,
      values = {},
    }
    local missing_primary = is_missing(primary_value, item.key, item.raw)
    hover.values[primary] = {
      value = primary_value,
      file = primary_item and primary_item.file or nil,
      missing = missing_primary,
    }

    -- Always compare against all languages (except primary)
    local compare_langs = {}
    for _, lang in ipairs(languages) do
      if lang ~= primary then
        table.insert(compare_langs, lang)
      end
    end

    local any_missing = false
    local any_localized = false
    local missing_langs = {}
    local localized_langs = {}
    local other_items = {}
    local compare_items = {}
    for _, lang in ipairs(languages) do
      if lang ~= primary then
        local entry = safe_index_get(index, lang, key)
        local value = entry and entry.value or nil
        local missing = is_missing(value, item.key, item.raw)
        hover.values[lang] = {
          value = value,
          file = entry and entry.file or nil,
          missing = missing,
        }
        other_items[lang] = entry
      end
    end
    for _, lang in ipairs(compare_langs) do
      local entry = other_items[lang]
      local value = entry and entry.value or nil
      local missing = is_missing(value, item.key, item.raw)
      if missing then
        any_missing = true
        table.insert(missing_langs, lang)
      elseif primary_value and value ~= primary_value then
        any_localized = true
        table.insert(localized_langs, lang)
      end
      if entry then
        compare_items[lang] = { value = entry.value, lang = lang }
      end
    end

    local status = "="
    if missing_primary then
      status = "×"
    else
      local has_mismatch, mismatch_langs = placeholder_mismatch_langs(primary_value, compare_items)
      hover.mismatch_langs = mismatch_langs
      if has_mismatch then
        status = "!"
      elseif any_missing then
        status = "?"
      elseif any_localized then
        status = "≠"
      end
    end
    hover.missing_langs = missing_langs
    hover.localized_langs = localized_langs
    local reason = nil
    if missing_primary then
      reason = "missing_primary"
    elseif status == "!" then
      reason = "placeholder_mismatch"
    elseif status == "?" then
      reason = "fallback"
    elseif status == "≠" then
      reason = "localized"
    end
    hover.status = status
    hover.reason = reason

    table.insert(resolved, {
      key = key,
      text = display_value or "",
      status = status,
      hover = hover,
    })
  end

  return resolved
end

return M
