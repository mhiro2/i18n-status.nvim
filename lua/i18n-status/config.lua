---@class I18nStatusConfig
---@field primary_lang string
---@field inline I18nStatusInlineConfig
---@field resource_watch I18nStatusResourceWatchConfig
---@field doctor I18nStatusDoctorConfig
---@field auto_hover I18nStatusAutoHoverConfig
---@field extract I18nStatusExtractConfig
local M = {}

local util = require("i18n-status.util")

---@class I18nStatusInlineConfig
---@field position "eol"|"after_key"
---@field max_len integer
---@field visible_only boolean
---@field status_only boolean
---@field debounce_ms integer
---@field hl table

---@class I18nStatusResourceWatchConfig
---@field enabled boolean
---@field debounce_ms integer

---@class I18nStatusDoctorFloatConfig
---@field width number
---@field height number
---@field border string

---@class I18nStatusDoctorConfig
---@field ignore_keys string[]
---@field float I18nStatusDoctorFloatConfig

---@class I18nStatusAutoHoverConfig
---@field enabled boolean

---@class I18nStatusExtractConfig
---@field min_length integer
---@field exclude_components string[]
---@field key_separator "."|"_"|"-"

---@type I18nStatusConfig
local defaults = {
  primary_lang = "en",
  inline = {
    position = "eol",
    max_len = 80,
    visible_only = true,
    status_only = false,
    debounce_ms = 80,
    hl = {
      text = "Comment",
      same = "I18nStatusSame",
      diff = "I18nStatusDiff",
      fallback = "I18nStatusFallback",
      missing = "I18nStatusMissing",
      mismatch = "I18nStatusMismatch",
    },
  },
  resource_watch = {
    enabled = true,
    debounce_ms = 200,
  },
  doctor = {
    ignore_keys = {},
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
  },
  auto_hover = {
    enabled = true,
  },
  extract = {
    min_length = 2,
    exclude_components = { "Trans", "Translation" },
    key_separator = "-",
  },
}

---@param opts I18nStatusConfig|nil
---@return I18nStatusConfig
function M.setup(opts)
  local merged = util.tbl_deep_merge(defaults, opts or {})

  -- Validation
  M._validate(merged)

  return merged
end

---@param config I18nStatusConfig
local function validate(config)
  local warnings = {}

  -- Validate primary_lang
  if config.primary_lang ~= nil and type(config.primary_lang) ~= "string" then
    table.insert(warnings, "primary_lang must be a string, got " .. type(config.primary_lang))
    config.primary_lang = defaults.primary_lang
  end

  -- Validate inline.position
  if config.inline and config.inline.position then
    if config.inline.position ~= "eol" and config.inline.position ~= "after_key" then
      table.insert(
        warnings,
        'inline.position must be "eol" or "after_key", got "' .. tostring(config.inline.position) .. '"'
      )
      config.inline.position = defaults.inline.position
    end
  end

  -- Validate inline.max_len
  if config.inline and config.inline.max_len ~= nil then
    if
      type(config.inline.max_len) ~= "number"
      or config.inline.max_len < 1
      or math.floor(config.inline.max_len) ~= config.inline.max_len
    then
      table.insert(warnings, "inline.max_len must be a positive integer, got " .. tostring(config.inline.max_len))
      config.inline.max_len = defaults.inline.max_len
    end
  end

  -- Validate inline.visible_only
  if config.inline and config.inline.visible_only ~= nil and type(config.inline.visible_only) ~= "boolean" then
    table.insert(warnings, "inline.visible_only must be a boolean, got " .. type(config.inline.visible_only))
    config.inline.visible_only = defaults.inline.visible_only
  end

  -- Validate inline.status_only
  if config.inline and config.inline.status_only ~= nil and type(config.inline.status_only) ~= "boolean" then
    table.insert(warnings, "inline.status_only must be a boolean, got " .. type(config.inline.status_only))
    config.inline.status_only = defaults.inline.status_only
  end

  -- Validate inline.debounce_ms
  if config.inline and config.inline.debounce_ms ~= nil then
    if
      type(config.inline.debounce_ms) ~= "number"
      or config.inline.debounce_ms < 0
      or math.floor(config.inline.debounce_ms) ~= config.inline.debounce_ms
    then
      table.insert(
        warnings,
        "inline.debounce_ms must be a non-negative integer, got " .. tostring(config.inline.debounce_ms)
      )
      config.inline.debounce_ms = defaults.inline.debounce_ms
    end
  end

  -- Validate inline.hl
  if config.inline and config.inline.hl ~= nil and type(config.inline.hl) ~= "table" then
    table.insert(warnings, "inline.hl must be a table, got " .. type(config.inline.hl))
    config.inline.hl = defaults.inline.hl
  end

  -- Validate resource_watch.enabled
  if
    config.resource_watch
    and config.resource_watch.enabled ~= nil
    and type(config.resource_watch.enabled) ~= "boolean"
  then
    table.insert(warnings, "resource_watch.enabled must be a boolean, got " .. type(config.resource_watch.enabled))
    config.resource_watch.enabled = defaults.resource_watch.enabled
  end

  -- Validate resource_watch.debounce_ms
  if config.resource_watch and config.resource_watch.debounce_ms ~= nil then
    if
      type(config.resource_watch.debounce_ms) ~= "number"
      or config.resource_watch.debounce_ms < 0
      or math.floor(config.resource_watch.debounce_ms) ~= config.resource_watch.debounce_ms
    then
      table.insert(
        warnings,
        "resource_watch.debounce_ms must be a non-negative integer, got " .. tostring(config.resource_watch.debounce_ms)
      )
      config.resource_watch.debounce_ms = defaults.resource_watch.debounce_ms
    end
  end

  -- Validate doctor.ignore_keys
  if config.doctor and config.doctor.ignore_keys ~= nil then
    if type(config.doctor.ignore_keys) ~= "table" then
      table.insert(warnings, "doctor.ignore_keys must be a table (array), got " .. type(config.doctor.ignore_keys))
      config.doctor.ignore_keys = defaults.doctor.ignore_keys
    else
      -- Check if all elements are strings and filter out invalid ones
      local valid_keys = {}
      for i, v in ipairs(config.doctor.ignore_keys) do
        if type(v) == "string" then
          table.insert(valid_keys, v)
        else
          table.insert(warnings, "doctor.ignore_keys[" .. i .. "] must be a string, got " .. type(v))
        end
      end
      config.doctor.ignore_keys = valid_keys
    end
  end

  -- Validate auto_hover.enabled
  if config.auto_hover and config.auto_hover.enabled ~= nil and type(config.auto_hover.enabled) ~= "boolean" then
    table.insert(warnings, "auto_hover.enabled must be a boolean, got " .. type(config.auto_hover.enabled))
    config.auto_hover.enabled = defaults.auto_hover.enabled
  end

  -- Validate extract.min_length
  if config.extract and config.extract.min_length ~= nil then
    if
      type(config.extract.min_length) ~= "number"
      or config.extract.min_length < 0
      or math.floor(config.extract.min_length) ~= config.extract.min_length
    then
      table.insert(
        warnings,
        "extract.min_length must be a non-negative integer, got " .. tostring(config.extract.min_length)
      )
      config.extract.min_length = defaults.extract.min_length
    end
  end

  -- Validate extract.exclude_components
  if config.extract and config.extract.exclude_components ~= nil then
    if type(config.extract.exclude_components) ~= "table" then
      table.insert(
        warnings,
        "extract.exclude_components must be a table (array), got " .. type(config.extract.exclude_components)
      )
      config.extract.exclude_components = defaults.extract.exclude_components
    else
      local valid_components = {}
      for i, value in ipairs(config.extract.exclude_components) do
        if type(value) == "string" and value ~= "" then
          table.insert(valid_components, value)
        else
          table.insert(
            warnings,
            "extract.exclude_components[" .. i .. "] must be a non-empty string, got " .. type(value)
          )
        end
      end
      if #valid_components == 0 then
        config.extract.exclude_components = defaults.extract.exclude_components
      else
        config.extract.exclude_components = valid_components
      end
    end
  end

  -- Validate extract.key_separator
  if config.extract and config.extract.key_separator ~= nil then
    if type(config.extract.key_separator) ~= "string" or not config.extract.key_separator:match("^[%._%-]$") then
      table.insert(
        warnings,
        'extract.key_separator must be one of ".", "_" or "-", got ' .. tostring(config.extract.key_separator)
      )
      config.extract.key_separator = defaults.extract.key_separator
    end
  end

  -- Validate doctor.float.width
  if config.doctor and config.doctor.float and config.doctor.float.width ~= nil then
    if
      type(config.doctor.float.width) ~= "number"
      or config.doctor.float.width <= 0
      or config.doctor.float.width > 1
    then
      table.insert(
        warnings,
        "doctor.float.width must be a number between 0.0 and 1.0, got " .. tostring(config.doctor.float.width)
      )
      config.doctor.float.width = defaults.doctor.float.width
    end
  end

  -- Validate doctor.float.height
  if config.doctor and config.doctor.float and config.doctor.float.height ~= nil then
    if
      type(config.doctor.float.height) ~= "number"
      or config.doctor.float.height <= 0
      or config.doctor.float.height > 1
    then
      table.insert(
        warnings,
        "doctor.float.height must be a number between 0.0 and 1.0, got " .. tostring(config.doctor.float.height)
      )
      config.doctor.float.height = defaults.doctor.float.height
    end
  end

  -- Validate doctor.float.border
  if config.doctor and config.doctor.float and config.doctor.float.border ~= nil then
    local valid_borders = { "none", "single", "double", "rounded", "solid", "shadow" }
    if
      type(config.doctor.float.border) ~= "string" or not vim.tbl_contains(valid_borders, config.doctor.float.border)
    then
      table.insert(
        warnings,
        "doctor.float.border must be one of: "
          .. table.concat(valid_borders, ", ")
          .. ", got "
          .. tostring(config.doctor.float.border)
      )
      config.doctor.float.border = defaults.doctor.float.border
    end
  end

  -- Report warnings
  if #warnings > 0 then
    vim.notify("i18n-status: invalid configuration detected:\n" .. table.concat(warnings, "\n"), vim.log.levels.WARN)
  end
end

---@param config I18nStatusConfig
function M._validate(config)
  validate(config)
end

return M
