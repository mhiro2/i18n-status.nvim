---@class I18nStatusScanItem
---@field key string
---@field raw string
---@field namespace string
---@field lnum integer
---@field col integer
---@field end_col integer
---@field fallback boolean

---@class I18nStatusHardcodedItem
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field text string
---@field kind string

---@class I18nStatusHoverValue
---@field value string|nil
---@field file string|nil
---@field missing boolean

---@class I18nStatusHover
---@field key string
---@field namespace string|nil
---@field status string|nil
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
---@field status string
---@field hover I18nStatusHover

return {}
