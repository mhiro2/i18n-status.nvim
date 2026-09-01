---@class I18nStatusExtract
local M = {}

local extract_review = require("i18n-status.extract_review")
local hardcoded = require("i18n-status.hardcoded")
local project_identity = require("i18n-status.project_identity")
local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")
local scan = require("i18n-status.scan")

---@param value string
---@param separator string
---@return string|nil
local function ascii_slug(value, separator)
  local normalized = (value or ""):gsub("%$", "")
  for i = 1, #normalized do
    if normalized:byte(i) > 127 then
      return nil
    end
  end

  local parts = {}
  local lowered = normalized:lower()
  for token in lowered:gmatch("[a-z0-9]+") do
    parts[#parts + 1] = token
  end
  if #parts == 0 then
    return nil
  end

  return table.concat(parts, separator)
end

---@param full_key string
---@param existing_keys table<string, boolean>
---@param generated_keys table<string, boolean>
---@param separator string
---@return string
local function ensure_unique_new_key(full_key, existing_keys, generated_keys, separator)
  if not existing_keys[full_key] and not generated_keys[full_key] then
    return full_key
  end

  local namespace = full_key:match("^(.-):")
  local key_path = full_key:match("^[^:]+:(.+)$")
  if not namespace or not key_path then
    return full_key
  end

  local resolved_separator = separator ~= "" and separator or "-"
  local n = 0
  while true do
    local candidate = string.format("%s:%s%s%d", namespace, key_path, resolved_separator, n)
    if not existing_keys[candidate] and not generated_keys[candidate] then
      return candidate
    end
    n = n + 1
  end
end

---@param cache I18nStatusCache|nil
---@return table<string, boolean>
local function collect_existing_keys(cache)
  return resource_catalog.collect_existing_keys(cache)
end

---@param bufnr integer
---@param items I18nStatusHardcodedItem[]
---@param fallback_ns string
---@param extract_cfg I18nStatusExtractConfig
---@param catalogs table<string, I18nStatusFrameworkCatalog>
---@return I18nStatusExtractCandidate[]
---@return integer rejected_count
local function build_candidates(bufnr, items, fallback_ns, extract_cfg, catalogs)
  local ordered = vim.deepcopy(items)
  table.sort(ordered, function(a, b)
    if a.lnum == b.lnum then
      return a.col < b.col
    end
    return a.lnum < b.lnum
  end)

  local separator = (extract_cfg and extract_cfg.key_separator) or "-"
  local generated_keys = {}
  local candidates = {}
  local rejected_count = 0

  for idx, item in ipairs(ordered) do
    local context = scan.translation_context_at(bufnr, item.lnum, {
      fallback_namespace = fallback_ns,
      col = item.col,
    })
    local t_func = type(context.t_func) == "string" and context.t_func ~= "" and context.t_func or nil
    local binding_id = type(context.binding_id) == "string" and context.binding_id ~= "" and context.binding_id or nil
    local catalog = catalogs[context.framework]
    local supported_context = (
      context.hook == "useTranslation"
      and context.framework == "i18next"
      and context.source_key_policy == "canonical"
      and (context.namespace_resolution == "absent" or context.namespace_resolution == "static")
    )
      or (
        (context.hook == "useTranslations" or context.hook == "getTranslations")
        and context.framework == "next_intl"
        and context.source_key_policy == "namespace_relative"
        and context.namespace_resolution == "static"
      )
    if
      context.ambiguous
      or context.shadowed
      or not supported_context
      or not context.found_hook
      or not t_func
      or not binding_id
      or not context.extract_safe
      or not catalog
      or #catalog.languages == 0
    then
      rejected_count = rejected_count + 1
    else
      local namespace = context.namespace or catalog.fallback_namespace or fallback_ns or "common"
      if context.namespace_resolution == "absent" then
        namespace = catalog.fallback_namespace or namespace
      end
      local existing_keys = catalog.existing_keys
      generated_keys[context.framework] = generated_keys[context.framework] or {}
      local framework_generated_keys = generated_keys[context.framework]
      local segment = ascii_slug(item.text, separator) or "key"
      local base_key = string.format("%s:%s", namespace, segment)

      local proposed_key = base_key
      local status = "ready"
      if resource_catalog.target_conflict(catalog, base_key, catalog.languages) then
        status = "conflict_existing"
      else
        proposed_key = ensure_unique_new_key(base_key, existing_keys, framework_generated_keys, separator)
        framework_generated_keys[proposed_key] = true
      end

      candidates[#candidates + 1] = {
        id = idx,
        lnum = item.lnum,
        col = item.col,
        end_lnum = item.end_lnum,
        end_col = item.end_col,
        text = item.text,
        source_text = item.source_text,
        kind = item.kind,
        replacement_context = item.replacement_context,
        namespace = namespace,
        t_func = t_func,
        binding_id = binding_id,
        hook = context.hook,
        framework = context.framework,
        languages = vim.deepcopy(catalog.languages),
        primary_lang = catalog.primary_lang,
        source_key_policy = context.source_key_policy,
        namespace_resolution = context.namespace_resolution,
        extract_safe = context.extract_safe,
        proposed_key = proposed_key,
        new_key = proposed_key,
        mode = "new",
        selected = false,
        status = status,
      }
    end
  end

  return candidates, rejected_count
end

---@param languages string[]
---@param configured_primary string|nil
---@return string
---@return boolean used_fallback
local function effective_primary(languages, configured_primary)
  if type(configured_primary) == "string" and configured_primary ~= "" then
    for _, lang in ipairs(languages) do
      if lang == configured_primary then
        return configured_primary, false
      end
    end
  end
  return languages[1], true
end

---@param bufnr integer
---@param cfg I18nStatusConfig
---@param opts? { range?: { start_line?: integer, end_line?: integer } }
---@return I18nStatusExtractReviewCtx|nil
function M.run(bufnr, cfg, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local identity, identity_err = project_identity.resolve(bufnr)
  if not identity then
    vim.notify(
      "i18n-status extract: " .. tostring(identity_err or "failed to resolve source project"),
      vim.log.levels.WARN
    )
    return nil
  end
  local start_dir = identity.start_dir
  local cache = identity.cache
  local source_tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local fallback_ns = resources.fallback_namespace(start_dir)
  local extract_cfg = (cfg and cfg.extract) or {}

  local configured_primary = cfg and cfg.primary_lang or nil
  local catalogs = {}
  local catalog_errors = {}
  local detected_language_count = 0
  for _, framework in ipairs({ "i18next", "next_intl" }) do
    local catalog, catalog_err = resource_catalog.build(start_dir, framework, cache)
    if catalog and #catalog.errors == 0 and #catalog.languages > 0 then
      catalog.fallback_namespace = resource_catalog.fallback_namespace(catalog)
      catalog.primary_lang, catalog.primary_fallback = effective_primary(catalog.languages, configured_primary)
      catalogs[framework] = catalog
      detected_language_count = detected_language_count + #catalog.languages
    elseif catalog and #catalog.errors > 0 then
      catalog_errors[framework] = "resource files contain errors"
    elseif catalog_err then
      catalog_errors[framework] = catalog_err
    end
  end

  local items, hardcoded_err = hardcoded.extract(bufnr, {
    range = opts.range,
    min_length = extract_cfg.min_length,
    exclude_components = extract_cfg.exclude_components,
  })
  if hardcoded_err then
    vim.notify("i18n-status extract: failed to scan hardcoded text (" .. hardcoded_err .. ")", vim.log.levels.WARN)
    return nil
  end
  if #items == 0 then
    vim.notify("i18n-status extract: no hardcoded text found", vim.log.levels.INFO)
    return nil
  end

  if detected_language_count == 0 then
    local reasons = {}
    for _, framework in ipairs({ "i18next", "next_intl" }) do
      if catalog_errors[framework] then
        reasons[#reasons + 1] = framework .. ": " .. catalog_errors[framework]
      end
    end
    local detail = #reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or ""
    vim.notify("i18n-status extract: no languages detected" .. detail, vim.log.levels.WARN)
    return nil
  end

  local candidates, rejected_count = build_candidates(bufnr, items, fallback_ns, extract_cfg, catalogs)
  if #candidates == 0 then
    vim.notify(
      "i18n-status extract: no candidates have a supported, unambiguous translation function in scope",
      vim.log.levels.WARN
    )
    return nil
  end
  if rejected_count > 0 then
    vim.notify(
      string.format(
        "i18n-status extract: skipped %d candidate(s) without a supported, unambiguous translation function in scope",
        rejected_count
      ),
      vim.log.levels.WARN
    )
  end

  local _, validation_err = project_identity.validate(bufnr, identity, "extract review setup")
  if validation_err or vim.api.nvim_buf_get_changedtick(bufnr) ~= source_tick then
    vim.notify("i18n-status extract: source changed while building the review; run Extract again", vim.log.levels.WARN)
    return nil
  end

  local used_frameworks = {}
  for _, candidate in ipairs(candidates) do
    used_frameworks[candidate.framework] = true
  end
  for framework, _ in pairs(used_frameworks) do
    local catalog = catalogs[framework]
    if catalog.primary_fallback and configured_primary and configured_primary ~= "" then
      vim.notify(
        string.format(
          "i18n-status extract: primary language '%s' is not detected for %s; using '%s'",
          configured_primary,
          framework,
          catalog.primary_lang
        ),
        vim.log.levels.WARN
      )
    end
  end

  local primary_catalog = catalogs[candidates[1].framework]

  return extract_review.open({
    bufnr = bufnr,
    cfg = cfg,
    candidates = candidates,
    framework_catalogs = catalogs,
    languages = primary_catalog.languages,
    primary_lang = primary_catalog.primary_lang,
    source_identity = identity,
    source_tick = source_tick,
    start_dir = start_dir,
  })
end

M._test = {
  ascii_slug = ascii_slug,
  collect_existing_keys = collect_existing_keys,
  build_candidates = build_candidates,
  effective_primary = effective_primary,
}

return M
