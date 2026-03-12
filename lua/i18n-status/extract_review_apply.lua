---@class I18nStatusExtractReviewApply
local M = {}

local core = require("i18n-status.core")
local key_write = require("i18n-status.key_write")
local util = require("i18n-status.util")

local split_key = util.split_i18n_key

---@class I18nStatusExtractApplyDeps
---@field candidate_range fun(ctx: I18nStatusExtractReviewCtx, candidate: I18nStatusExtractCandidate): integer|nil, integer|nil, integer|nil, integer|nil
---@field candidate_text fun(ctx: I18nStatusExtractReviewCtx, candidate: I18nStatusExtractCandidate): string
---@field close_review fun(ctx: I18nStatusExtractReviewCtx, cancelled: boolean)
---@field refresh_views fun(ctx: I18nStatusExtractReviewCtx, preferred_candidate_id: integer|nil)

---@param key string
---@param default_ns string
---@return string|nil
---@return string|nil
function M.normalize_key_input(key, default_ns)
  if type(key) ~= "string" or vim.trim(key) == "" then
    return nil, "empty key"
  end

  local trimmed = vim.trim(key)
  local colon_pos = trimmed:find(":")
  local second_colon = colon_pos and trimmed:find(":", colon_pos + 1)
  if second_colon then
    return nil, "key can only contain one ':' separator"
  end

  local full_key = trimmed
  if not colon_pos then
    if not default_ns or default_ns == "" then
      return nil, "namespace is required"
    end
    full_key = default_ns .. ":" .. trimmed
  end

  local namespace, key_path = split_key(full_key)
  if not namespace or not key_path then
    return nil, "invalid key format"
  end
  if key_path:match("^%.") or key_path:match("%.$") or key_path:match("%.%.") then
    return nil, "invalid key path"
  end
  if not namespace:match("^[%w_%-%.]+$") then
    return nil, "invalid namespace format"
  end
  if not key_path:match("^[%w_%-%.]+$") then
    return nil, "invalid key path format"
  end
  return full_key, nil
end

---@param candidate I18nStatusExtractCandidate
---@param existing_keys table<string, boolean>
---@return string|nil
local function refresh_candidate_status(candidate, existing_keys)
  local normalized, err = M.normalize_key_input(candidate.proposed_key, candidate.namespace)
  if not normalized then
    candidate.status = "invalid_key"
    candidate.error = err
    return nil
  end

  candidate.proposed_key = normalized
  if candidate.mode == "reuse" then
    if existing_keys[normalized] then
      candidate.status = "ready"
      candidate.error = nil
      return normalized
    end
    candidate.status = "error"
    candidate.error = "reuse target does not exist"
    return normalized
  end

  if existing_keys[normalized] then
    candidate.status = "conflict_existing"
    candidate.error = nil
    return normalized
  end

  candidate.status = "ready"
  candidate.error = nil
  return normalized
end

---@param candidates I18nStatusExtractCandidate[]
---@param existing_keys table<string, boolean>
function M.refresh_candidate_statuses(candidates, existing_keys)
  local new_key_owner = {}
  for _, candidate in ipairs(candidates) do
    local normalized = refresh_candidate_status(candidate, existing_keys)
    if normalized and candidate.mode == "new" and candidate.status == "ready" then
      local owner = new_key_owner[normalized]
      if owner then
        candidate.status = "conflict_existing"
        candidate.error = "duplicate candidate key"
        if owner.status == "ready" then
          owner.status = "conflict_existing"
          owner.error = "duplicate candidate key"
        end
      else
        new_key_owner[normalized] = candidate
      end
    end
  end
end

---@param summary I18nStatusExtractApplySummary
---@return string
function M.build_apply_message(summary)
  return string.format(
    "i18n-status extract: applied=%d skipped=%d failed=%d",
    summary.applied,
    summary.skipped,
    summary.failed
  )
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidates I18nStatusExtractCandidate[]
---@return I18nStatusExtractCandidate[]
---@return integer
function M.applicable_candidates(ctx, candidates)
  ctx.statuses_dirty = true
  M.refresh_candidate_statuses(ctx.candidates, ctx.existing_keys)
  ctx.statuses_dirty = false

  local applicable = {}
  local skipped = 0
  for _, candidate in ipairs(candidates) do
    if candidate.selected and candidate.status == "ready" then
      applicable[#applicable + 1] = candidate
    elseif candidate.selected then
      skipped = skipped + 1
    end
  end
  return applicable, skipped
end

---@param replacement string
---@param row integer
---@param col integer
---@return integer
---@return integer
local function replacement_end_position(replacement, row, col)
  local lines = vim.split(replacement, "\n", { plain = true })
  if #lines == 1 then
    return row, col + #lines[1]
  end
  return row + #lines - 1, #lines[#lines]
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@param deps I18nStatusExtractApplyDeps
---@return boolean
local function apply_candidate(ctx, candidate, deps)
  local srow, scol, erow, ecol = deps.candidate_range(ctx, candidate)
  if not srow then
    return false
  end

  local namespace, key_path = split_key(candidate.proposed_key)
  if not namespace or not key_path then
    return false
  end

  local source_text = deps.candidate_text(ctx, candidate)
  candidate.text = source_text
  local replacement = string.format('{%s("%s")}', candidate.t_func or "t", candidate.proposed_key)
  local replaced, replace_err =
    pcall(vim.api.nvim_buf_set_text, ctx.source_buf, srow, scol, erow, ecol, { replacement })
  if not replaced then
    candidate.error = "failed to update source buffer (" .. tostring(replace_err) .. ")"
    return false
  end

  if candidate.mode == "new" then
    local translations = {}
    for _, lang in ipairs(ctx.languages) do
      translations[lang] = lang == ctx.primary_lang and source_text or ""
    end
    local success_count, failed_langs =
      key_write.write_translations(namespace, key_path, translations, ctx.start_dir, ctx.languages)
    if success_count == 0 then
      local rollback_lines = vim.split(source_text, "\n", { plain = true })
      local rollback_erow, rollback_ecol = replacement_end_position(replacement, srow, scol)
      local rollback_ok, rollback_err =
        pcall(vim.api.nvim_buf_set_text, ctx.source_buf, srow, scol, rollback_erow, rollback_ecol, rollback_lines)
      if not rollback_ok then
        candidate.error = "failed to rollback source buffer (" .. tostring(rollback_err) .. ")"
        vim.notify("i18n-status extract: " .. candidate.error, vim.log.levels.ERROR)
        return false
      end
      if type(failed_langs) == "table" and #failed_langs > 0 then
        candidate.error = "failed to write resource files (" .. table.concat(failed_langs, ", ") .. ")"
      else
        candidate.error = "failed to write resource files"
      end
      return false
    end
  end

  ctx.existing_keys[candidate.proposed_key] = true
  candidate.error = nil
  if candidate.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, ctx.source_buf, ctx.track_namespace, candidate.mark_id)
    candidate.mark_id = nil
  end
  return true
end

---@param ctx I18nStatusExtractReviewCtx
---@param targets I18nStatusExtractCandidate[]
---@param deps I18nStatusExtractApplyDeps
function M.apply_targets(ctx, targets, deps)
  if #targets == 0 then
    vim.notify("i18n-status extract: no candidates selected", vim.log.levels.INFO)
    return
  end

  local preferred = ctx.current_candidate and ctx.current_candidate(ctx)
  local preferred_id = preferred and preferred.id or nil
  local summary = {
    applied = 0,
    skipped = 0,
    failed = 0,
  }

  local applicable, skipped = M.applicable_candidates(ctx, targets)
  summary.skipped = skipped

  local applied_ids = {}
  for _, candidate in ipairs(applicable) do
    if apply_candidate(ctx, candidate, deps) then
      summary.applied = summary.applied + 1
      applied_ids[candidate.id] = true
    else
      summary.failed = summary.failed + 1
    end
  end

  if summary.applied > 0 then
    local remaining = {}
    for _, candidate in ipairs(ctx.candidates) do
      if not applied_ids[candidate.id] then
        remaining[#remaining + 1] = candidate
      end
    end
    ctx.candidates = remaining
    core.refresh(ctx.source_buf, ctx.cfg, 0, { force = true })
    core.refresh_all(ctx.cfg)
  end

  ctx.status_message =
    string.format("last apply: applied=%d skipped=%d failed=%d", summary.applied, summary.skipped, summary.failed)
  vim.notify(M.build_apply_message(summary), summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

  if #ctx.candidates == 0 then
    deps.close_review(ctx, false)
    return
  end
  deps.refresh_views(ctx, preferred_id)
end

---@param ctx I18nStatusExtractReviewCtx
---@param deps I18nStatusExtractApplyDeps
function M.apply_selected(ctx, deps)
  local targets = {}
  for _, candidate in ipairs(ctx.candidates) do
    if candidate.selected then
      targets[#targets + 1] = candidate
    end
  end
  if #targets == 0 then
    vim.notify("i18n-status extract: no selected candidates", vim.log.levels.INFO)
    return
  end
  M.apply_targets(ctx, targets, deps)
end

return M
