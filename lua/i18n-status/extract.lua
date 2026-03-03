---@class I18nStatusExtract
local M = {}

local extract_review = require("i18n-status.extract_review")
local hardcoded = require("i18n-status.hardcoded")
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
  local keys = {}
  if not cache or not cache.index then
    return keys
  end
  for _, entries in pairs(cache.index) do
    for key, _ in pairs(entries or {}) do
      if key ~= "__error__" then
        keys[key] = true
      end
    end
  end
  return keys
end

---@param bufnr integer
---@param items I18nStatusHardcodedItem[]
---@param fallback_ns string
---@param extract_cfg I18nStatusExtractConfig
---@param existing_keys table<string, boolean>
---@return I18nStatusExtractCandidate[]
local function build_candidates(bufnr, items, fallback_ns, extract_cfg, existing_keys)
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

  for idx, item in ipairs(ordered) do
    local context = scan.translation_context_at(bufnr, item.lnum, { fallback_namespace = fallback_ns })
    local namespace = context.namespace or fallback_ns or "common"
    local segment = ascii_slug(item.text, separator) or "key"
    local base_key = string.format("%s:%s", namespace, segment)

    local proposed_key = base_key
    local status = "ready"
    if existing_keys[base_key] then
      status = "conflict_existing"
    else
      proposed_key = ensure_unique_new_key(base_key, existing_keys, generated_keys, separator)
      generated_keys[proposed_key] = true
    end

    candidates[#candidates + 1] = {
      id = idx,
      lnum = item.lnum,
      col = item.col,
      end_lnum = item.end_lnum,
      end_col = item.end_col,
      text = item.text,
      namespace = namespace,
      t_func = context.t_func or "t",
      proposed_key = proposed_key,
      new_key = proposed_key,
      mode = "new",
      selected = false,
      status = status,
    }
  end

  return candidates
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

  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  local fallback_ns = resources.fallback_namespace(start_dir)
  local extract_cfg = (cfg and cfg.extract) or {}

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

  local languages = cache and cache.languages or {}
  if #languages == 0 then
    vim.notify("i18n-status extract: no languages detected", vim.log.levels.WARN)
    return nil
  end

  local primary_lang = (cfg and cfg.primary_lang) or languages[1]
  local existing_keys = collect_existing_keys(cache)
  local candidates = build_candidates(bufnr, items, fallback_ns, extract_cfg, existing_keys)

  return extract_review.open({
    bufnr = bufnr,
    cfg = cfg,
    candidates = candidates,
    existing_keys = existing_keys,
    languages = languages,
    primary_lang = primary_lang,
    start_dir = start_dir,
  })
end

M._test = {
  ascii_slug = ascii_slug,
  collect_existing_keys = collect_existing_keys,
  build_candidates = build_candidates,
}

return M
