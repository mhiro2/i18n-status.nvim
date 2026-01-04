---@class I18nStatusHealth
local M = {}

local config_mod = require("i18n-status.config")
local resources = require("i18n-status.resources")
local util = require("i18n-status.util")

local health = vim.health or require("health")

---@param message string
local function info(message)
  if health.info then
    health.info(message)
  else
    health.ok(message)
  end
end

---@param message string
local function ok(message)
  health.ok(message)
end

---@param message string
local function warn(message)
  health.warn(message)
end

---@param tbl table
---@param seen table|nil
---@return boolean
local function contains_module(tbl, seen)
  if type(tbl) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[tbl] then
    return false
  end
  seen[tbl] = true
  for k, v in pairs(tbl) do
    if v == "i18n-status.blink" or v == "i18n_status" or v == "i18n-status" then
      return true
    end
    if type(k) == "string" and (k == "i18n_status" or k == "i18n-status") then
      return true
    end
    if type(v) == "table" and contains_module(v, seen) then
      return true
    end
  end
  return false
end

---@param cfg table|nil
---@return string, string
local function blink_status(cfg)
  if type(cfg) ~= "table" then
    return "info", "blink.cmp config not accessible; verify i18n-status source manually"
  end

  local sources = cfg.sources or {}
  local providers = sources.providers or {}
  local provider = providers.i18n_status or providers["i18n-status"]
  local provider_ok = false
  if type(provider) == "table" then
    provider_ok = provider.module == "i18n-status.blink" or provider.name == "i18n-status"
  end
  if not provider_ok then
    for _, prov in pairs(providers) do
      if type(prov) == "table" and prov.module == "i18n-status.blink" then
        provider_ok = true
        break
      end
    end
  end

  local defaults = sources.default or {}
  local default_ok = false
  if type(defaults) == "table" then
    for _, name in ipairs(defaults) do
      if name == "i18n_status" or name == "i18n-status" then
        default_ok = true
        break
      end
    end
  end

  if provider_ok and default_ok then
    return "ok", "blink.cmp i18n-status source is configured"
  end
  if provider_ok and not default_ok then
    return "warn", "blink.cmp provider set but not enabled in sources.default"
  end
  if not provider_ok and default_ok then
    return "warn", "blink.cmp sources.default has i18n_status but provider is missing"
  end
  if contains_module(cfg) then
    return "info", "blink.cmp config mentions i18n-status but source activation is unclear"
  end
  return "warn", "blink.cmp i18n-status source not found in config"
end

function M.check()
  health.start("i18n-status")

  local plugin = package.loaded["i18n-status"]
  local cfg = nil
  if plugin and type(plugin.get_config) == "function" then
    cfg = plugin.get_config()
  end
  local using_defaults = false
  if not cfg then
    cfg = config_mod.setup(nil)
    using_defaults = true
  end

  local start_dir = resources.start_dir(vim.api.nvim_get_current_buf())

  health.start("Configuration")
  if using_defaults then
    info("setup() not called yet; showing defaults")
  end
  info("start_dir: " .. start_dir)
  info("primary_lang: " .. (cfg.primary_lang or ""))
  info("resource_watch.enabled: " .. tostring(cfg.resource_watch and cfg.resource_watch.enabled ~= false))
  if start_dir == "" then
    warn("start_dir is empty")
  elseif util.is_dir(start_dir) then
    ok("start_dir exists: " .. start_dir)
  else
    warn("start_dir does not exist: " .. start_dir)
  end

  health.start("Resources")
  local cache = resources.ensure_index(start_dir)
  local roots = cache.roots or {}
  if #roots == 0 then
    warn("resource root not found (locales/, public/locales/ or messages/)")
  else
    local parts = {}
    for _, entry in ipairs(roots) do
      table.insert(parts, entry.kind .. ": " .. entry.path)
    end
    ok("roots: " .. table.concat(parts, ", "))
  end
  if cache.languages and #cache.languages > 0 then
    ok("languages: " .. table.concat(cache.languages, ", "))
    local primary = cfg.primary_lang or ""
    if primary ~= "" then
      local found = false
      for _, lang in ipairs(cache.languages) do
        if lang == primary then
          found = true
          break
        end
      end
      if not found then
        warn(
          "primary_lang '"
            .. primary
            .. "' not found in detected languages; will fallback to '"
            .. cache.languages[1]
            .. "'"
        )
      end
    end
    if plugin then
      local state_mod = require("i18n-status.state")
      local project = state_mod.project_for_key(cache.key)
      if project and project.current_lang then
        info("current_lang: " .. project.current_lang)
      end
    end
  else
    warn("languages not detected")
  end
  local hint, reason, namespaces = resources.namespace_hint(start_dir)
  if namespaces and #namespaces > 0 then
    info("namespaces: " .. table.concat(namespaces, ", "))
  else
    warn("namespaces not detected")
  end
  if reason ~= "single" then
    local fallback_ns = resources.fallback_namespace(start_dir)
    warn("namespace not detected; falling back to '" .. fallback_ns .. "'")
  else
    ok("default namespace: " .. hint)
  end
  if cache.errors and #cache.errors > 0 then
    for _, entry in ipairs(cache.errors) do
      warn("resource error: " .. entry.file .. " (" .. entry.error .. ")")
    end
  else
    ok("resource errors: none")
  end

  health.start("Treesitter")
  if not vim.treesitter or type(vim.treesitter.get_parser) ~= "function" then
    warn("treesitter API not available")
  else
    -- Use get_parser() to avoid deprecated vim.treesitter.language.require_language() warnings.
    local langs = {
      { name = "javascript", note = "needed for javascript" },
      { name = "typescript", note = "needed for typescript" },
      { name = "jsx", note = "needed for javascriptreact" },
      { name = "tsx", note = "needed for typescriptreact" },
      { name = "json", note = "needed for translation JSON inline" },
      { name = "jsonc", note = "needed for translation JSON inline (comments)" },
    }
    for _, entry in ipairs(langs) do
      local lang = entry.name
      local buf = vim.api.nvim_create_buf(false, true)
      local ok_lang = pcall(vim.treesitter.get_parser, buf, lang)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      if ok_lang then
        ok("parser installed: " .. lang)
      else
        local note = entry.note and (" (" .. entry.note .. ")") or ""
        warn("parser missing: " .. lang .. note)
      end
    end
  end

  health.start("Completion (blink.cmp)")
  local ok_blink, blink = pcall(require, "blink.cmp")
  if not ok_blink then
    warn("blink.cmp not installed (completion disabled)")
  else
    ok("blink.cmp is installed")

    local ok_source, i18n_source = pcall(require, "i18n-status.blink")
    if ok_source and i18n_source.Source and type(i18n_source.Source.new) == "function" then
      local ok_new, instance = pcall(i18n_source.Source.new, {})
      if ok_new and instance then
        ok("i18n-status source instantiates correctly")
        local required_methods = { "complete", "get_trigger_characters", "is_available", "execute" }
        for _, method in ipairs(required_methods) do
          if type(instance[method]) ~= "function" then
            warn("i18n-status source missing method: " .. method)
          end
        end
      else
        warn("i18n-status source.new() fails: " .. tostring(instance))
      end
    else
      warn("i18n-status source not blink.cmp compatible")
    end

    local blink_cfg = blink.get_config and blink.get_config() or blink.config or blink.opts
    local status, message = blink_status(blink_cfg)
    if status == "ok" then
      ok(message)
    elseif status == "warn" then
      warn(message)
    else
      info(message)
    end
  end

  health.start("Doctor")
  info("doctor is not run by checkhealth; use :I18nDoctor")
end

return M
