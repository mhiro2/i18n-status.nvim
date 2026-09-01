---@class I18nStatusExtractReviewApply
local M = {}

local core = require("i18n-status.core")
local extract_candidate = require("i18n-status.extract_candidate")
local hardcoded = require("i18n-status.hardcoded")
local key_write = require("i18n-status.key_write")
local mutation_transaction = require("i18n-status.mutation_transaction")
local project_identity = require("i18n-status.project_identity")
local resource_catalog = require("i18n-status.resource_catalog")
local scan = require("i18n-status.scan")
local text = require("i18n-status.text")

local split_key = text.split_i18n_key
local BACK_TO_FRONT_FIELDS = { "srow", "scol", "erow", "ecol", "index" }

---@class I18nStatusExtractApplyDeps
---@field candidate_range fun(ctx: I18nStatusExtractReviewCtx, candidate: I18nStatusExtractCandidate): integer|nil, integer|nil, integer|nil, integer|nil
---@field candidate_source_text fun(ctx: I18nStatusExtractReviewCtx, candidate: I18nStatusExtractCandidate): string|nil
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
---@param catalog I18nStatusFrameworkCatalog|nil
---@param fallback_existing_keys table<string, boolean>|nil
---@return string|nil
local function refresh_candidate_status(candidate, catalog, fallback_existing_keys)
  if candidate.stale then
    candidate.status = "error"
    candidate.error = candidate.error or "source changed since the review opened"
    return nil
  end

  if candidate.apply_error then
    candidate.status = "error"
    candidate.error = candidate.apply_error
    return candidate.proposed_key
  end

  local normalized, err = M.normalize_key_input(candidate.proposed_key, candidate.namespace)
  if not normalized then
    candidate.status = "invalid_key"
    candidate.error = err
    return nil
  end

  candidate.proposed_key = normalized
  local existing_keys = (catalog and catalog.existing_keys) or fallback_existing_keys or {}
  local _, replacement_err = extract_candidate.replacement(candidate)
  if replacement_err then
    candidate.status = "error"
    candidate.error = replacement_err
    return normalized
  end
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

  if
    (catalog and resource_catalog.target_conflict(catalog, normalized, candidate.languages))
    or (not catalog and existing_keys[normalized])
  then
    candidate.status = "conflict_existing"
    candidate.error = nil
    return normalized
  end

  candidate.status = "ready"
  candidate.error = nil
  return normalized
end

---@param candidates I18nStatusExtractCandidate[]
---@param catalogs table<string, I18nStatusFrameworkCatalog>|nil
---@param fallback_existing_keys table<string, boolean>|nil
function M.refresh_candidate_statuses(candidates, catalogs, fallback_existing_keys)
  local ready_new = {}
  for _, candidate in ipairs(candidates) do
    local catalog = catalogs and catalogs[candidate.framework]
    local normalized = refresh_candidate_status(candidate, catalog, fallback_existing_keys)
    if normalized and candidate.mode == "new" and candidate.status == "ready" then
      local framework = candidate.framework or "default"
      ready_new[framework] = ready_new[framework] or {}
      ready_new[framework][#ready_new[framework] + 1] = candidate
    end
  end

  for _, framework_candidates in pairs(ready_new) do
    for left_index = 1, #framework_candidates - 1 do
      local left = framework_candidates[left_index]
      for right_index = left_index + 1, #framework_candidates do
        local right = framework_candidates[right_index]
        local left_key = left.proposed_key
        local right_key = right.proposed_key
        if
          left_key == right_key
          or left_key:sub(1, #right_key + 1) == right_key .. "."
          or right_key:sub(1, #left_key + 1) == left_key .. "."
        then
          local reason = left_key == right_key and "duplicate candidate key" or "overlapping candidate key"
          left.status = "conflict_existing"
          left.error = reason
          right.status = "conflict_existing"
          right.error = reason
        end
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
  M.refresh_candidate_statuses(ctx.candidates, ctx.framework_catalogs, ctx.existing_keys)
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

---@param candidate I18nStatusExtractCandidate
---@param reason string
local function mark_stale(candidate, reason)
  candidate.stale = true
  candidate.status = "error"
  candidate.error = reason
end

---@param left integer|nil
---@param right integer|nil
---@return boolean
local function same_position(left, right)
  return type(left) == "number" and left == right
end

---@param plan table
---@return boolean
---@return string|nil
local function validate_source_snapshot(plan)
  local ctx = plan.ctx
  local candidate = plan.candidate
  local identity_valid, identity_err = project_identity.validate_buffer(ctx.source_buf, ctx.source_identity, "extract")
  if not identity_valid then
    return false, identity_err
  end
  if not vim.api.nvim_buf_is_valid(ctx.source_buf) or not vim.api.nvim_buf_is_loaded(ctx.source_buf) then
    return false, "source buffer is unavailable"
  end
  if not vim.bo[ctx.source_buf].modifiable then
    return false, "source buffer is not modifiable"
  end
  if vim.api.nvim_buf_get_changedtick(ctx.source_buf) ~= plan.expected_tick then
    return false, "source buffer changed before extraction"
  end

  local srow, scol, erow, ecol = plan.deps.candidate_range(ctx, candidate)
  if
    not same_position(srow, plan.srow)
    or not same_position(scol, plan.scol)
    or not same_position(erow, plan.erow)
    or not same_position(ecol, plan.ecol)
  then
    return false, "source range changed before extraction"
  end
  if plan.deps.candidate_source_text(ctx, candidate) ~= candidate.source_text then
    return false, "source text changed before extraction"
  end
  return true, nil
end

---@param plan table
---@return boolean
---@return string|nil
local function validate_source_plan(plan)
  local ctx = plan.ctx
  local candidate = plan.candidate
  local _, identity_err = project_identity.validate(ctx.source_buf, ctx.source_identity, "extract")
  if identity_err then
    return false, identity_err
  end
  local snapshot_valid, snapshot_err = validate_source_snapshot(plan)
  if not snapshot_valid then
    return false, snapshot_err
  end

  local hardcoded_items, hardcoded_err = hardcoded.extract(ctx.source_buf, {
    min_length = ctx.cfg.extract.min_length,
    exclude_components = ctx.cfg.extract.exclude_components,
  })
  if hardcoded_err then
    return false, "failed to revalidate source syntax: " .. hardcoded_err
  end
  local matched_item = false
  for _, item in ipairs(hardcoded_items) do
    if
      item.lnum == plan.srow
      and item.col == plan.scol
      and item.end_lnum == plan.erow
      and item.end_col == plan.ecol
      and item.source_text == candidate.source_text
      and item.text == candidate.text
      and item.kind == candidate.kind
      and item.replacement_context == candidate.replacement_context
    then
      matched_item = true
      break
    end
  end
  if not matched_item then
    return false, "source syntax changed since the review opened"
  end

  local current_context = scan.translation_context_at(ctx.source_buf, plan.srow, {
    fallback_namespace = candidate.namespace,
    col = plan.scol,
    callee = candidate.t_func,
    member_call = false,
  })
  if
    not current_context.found_hook
    or current_context.ambiguous
    or current_context.shadowed
    or current_context.t_func ~= candidate.t_func
    or current_context.binding_id ~= candidate.binding_id
    or current_context.namespace ~= candidate.namespace
    or current_context.hook ~= candidate.hook
    or current_context.framework ~= candidate.framework
    or current_context.source_key_policy ~= candidate.source_key_policy
    or current_context.namespace_resolution ~= candidate.namespace_resolution
    or current_context.extract_safe ~= candidate.extract_safe
  then
    return false, "translation context changed since the review opened"
  end

  if vim.api.nvim_buf_get_changedtick(ctx.source_buf) ~= plan.expected_tick then
    return false, "source buffer changed while validating extraction"
  end
  local identity_stable, stability_err =
    project_identity.validate_buffer(ctx.source_buf, ctx.source_identity, "extract validation")
  if not identity_stable then
    return false, stability_err
  end
  local srow, scol, erow, ecol = plan.deps.candidate_range(ctx, candidate)
  if
    not same_position(srow, plan.srow)
    or not same_position(scol, plan.scol)
    or not same_position(erow, plan.erow)
    or not same_position(ecol, plan.ecol)
    or plan.deps.candidate_source_text(ctx, candidate) ~= candidate.source_text
  then
    return false, "source range changed while validating extraction"
  end
  return true, nil
end

---@param bufnr integer
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return string|nil
local function buffer_text(bufnr, start_row, start_col, end_row, end_col)
  local ok, chunks = pcall(vim.api.nvim_buf_get_text, bufnr, start_row, start_col, end_row, end_col, {})
  if not ok then
    return nil
  end
  return table.concat(chunks, "\n")
end

---@param plan table
---@return I18nStatusMutationParticipant
local function source_participant(plan)
  return {
    label = "source " .. plan.ctx.source_identity.name,
    validate = function()
      return validate_source_plan(plan)
    end,
    commit = function()
      local valid, validation_err = validate_source_snapshot(plan)
      if not valid then
        return false, validation_err, false
      end
      if plan.resource_guard then
        local resources_valid, resource_err = plan.resource_guard()
        if not resources_valid then
          return false, "resource files changed before source update: " .. tostring(resource_err or "unknown"), false
        end
      end
      valid, validation_err = validate_source_snapshot(plan)
      if not valid then
        return false, validation_err, false
      end
      local before_tick = vim.api.nvim_buf_get_changedtick(plan.ctx.source_buf)
      local ok, replace_err = pcall(
        vim.api.nvim_buf_set_text,
        plan.ctx.source_buf,
        plan.srow,
        plan.scol,
        plan.erow,
        plan.ecol,
        vim.split(plan.replacement, "\n", { plain = true })
      )
      local replacement_erow, replacement_ecol = replacement_end_position(plan.replacement, plan.srow, plan.scol)
      local current = buffer_text(plan.ctx.source_buf, plan.srow, plan.scol, replacement_erow, replacement_ecol)
      local changed = vim.api.nvim_buf_get_changedtick(plan.ctx.source_buf) ~= before_tick
      if changed and current == plan.replacement then
        plan.applied = true
        plan.replacement_erow = replacement_erow
        plan.replacement_ecol = replacement_ecol
        plan.expected_tick = vim.api.nvim_buf_get_changedtick(plan.ctx.source_buf)
      elseif changed then
        plan.rollback_blocked = true
        plan.expected_tick = vim.api.nvim_buf_get_changedtick(plan.ctx.source_buf)
      end
      if not ok or current ~= plan.replacement then
        return false, "failed to update source buffer: " .. tostring(replace_err or "replacement mismatch"), changed
      end
      return true, nil, true
    end,
    rollback = function()
      local _, identity_err =
        project_identity.validate(plan.ctx.source_buf, plan.ctx.source_identity, "extract rollback")
      if identity_err then
        return false, identity_err
      end
      if vim.api.nvim_buf_get_changedtick(plan.ctx.source_buf) ~= plan.expected_tick then
        return false, "source buffer changed after extraction; preserving concurrent edits"
      end
      if plan.rollback_blocked then
        return false, "source mutation did not match the planned replacement; preserving concurrent edits"
      end
      if not plan.applied then
        return true, nil
      end
      local current =
        buffer_text(plan.ctx.source_buf, plan.srow, plan.scol, plan.replacement_erow, plan.replacement_ecol)
      if current ~= plan.replacement then
        return false, "source replacement changed after extraction; preserving concurrent edits"
      end
      local restored, restore_err = pcall(
        vim.api.nvim_buf_set_text,
        plan.ctx.source_buf,
        plan.srow,
        plan.scol,
        plan.replacement_erow,
        plan.replacement_ecol,
        vim.split(plan.candidate.source_text, "\n", { plain = true })
      )
      if not restored then
        return false, "failed to restore source buffer: " .. tostring(restore_err)
      end
      if
        not plan.initial_modified
        and vim.deep_equal(plan.initial_lines, vim.api.nvim_buf_get_lines(plan.ctx.source_buf, 0, -1, false))
      then
        vim.bo[plan.ctx.source_buf].modified = false
      end
      return true, nil
    end,
  }
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@param deps I18nStatusExtractApplyDeps
---@return table|nil
---@return string|nil
local function build_source_plan(ctx, candidate, deps)
  local srow, scol, erow, ecol = deps.candidate_range(ctx, candidate)
  if not srow then
    return nil, "source range is unavailable"
  end
  local replacement, replacement_err = extract_candidate.replacement(candidate)
  if not replacement then
    return nil, replacement_err or "failed to build source replacement"
  end
  local plan = {
    applied = false,
    candidate = candidate,
    ctx = ctx,
    deps = deps,
    ecol = ecol,
    erow = erow,
    expected_tick = vim.api.nvim_buf_get_changedtick(ctx.source_buf),
    initial_lines = vim.api.nvim_buf_get_lines(ctx.source_buf, 0, -1, false),
    initial_modified = vim.bo[ctx.source_buf].modified,
    replacement = replacement,
    rollback_blocked = false,
    scol = scol,
    srow = srow,
  }
  local valid, validation_err = validate_source_plan(plan)
  if not valid then
    return nil, validation_err
  end
  return plan, nil
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@param expected_catalog I18nStatusFrameworkCatalog
---@param operation string
---@param error_prefix string
---@return I18nStatusFrameworkCatalog|nil
---@return string|nil
local function validate_framework_catalog(ctx, candidate, expected_catalog, operation, error_prefix)
  local identity, identity_err = project_identity.validate(ctx.source_buf, ctx.source_identity, operation)
  if not identity then
    return nil, identity_err
  end
  local current_catalog, catalog_err = resource_catalog.build(ctx.start_dir, candidate.framework, identity.cache)
  if not current_catalog then
    return nil, error_prefix .. ": " .. tostring(catalog_err or "not found")
  end
  if #current_catalog.errors > 0 then
    return nil, error_prefix .. ": resource catalog contains errors"
  end
  if not resource_catalog.same_roots(current_catalog.roots, expected_catalog.roots) then
    return nil, error_prefix .. ": resource roots changed"
  end
  if not resource_catalog.same_languages(current_catalog.languages, candidate.languages) then
    return nil, error_prefix .. ": resource languages changed"
  end
  return current_catalog, nil
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidate I18nStatusExtractCandidate
---@param deps I18nStatusExtractApplyDeps
---@return boolean
local function apply_candidate(ctx, candidate, deps)
  local namespace, key_path = split_key(candidate.proposed_key)
  if not namespace or not key_path then
    return false
  end
  local plan, plan_err = build_source_plan(ctx, candidate, deps)
  if not plan then
    mark_stale(candidate, plan_err or "source changed since the review opened")
    return false
  end

  local participants = {}
  local catalog = ctx.framework_catalogs[candidate.framework]
  if not catalog then
    candidate.apply_error = "resource framework catalog is unavailable"
    candidate.status = "error"
    candidate.error = candidate.apply_error
    return false
  end
  if candidate.mode == "new" then
    local translations = {}
    for _, lang in ipairs(candidate.languages) do
      translations[lang] = lang == candidate.primary_lang and candidate.text or ""
    end
    local resource_changes, _, _, prepare_err =
      key_write.prepare_translations(namespace, key_path, translations, ctx.start_dir, candidate.languages, {
        create_only = true,
        expected_languages = candidate.languages,
        framework = candidate.framework,
      })
    if not resource_changes then
      candidate.apply_error = "failed to prepare resource files: " .. tostring(prepare_err or "unknown")
      candidate.status = "error"
      candidate.error = candidate.apply_error
      return false
    end
    plan.resource_guard = function()
      local committed, committed_err = resource_changes.validate_committed()
      if not committed then
        return false, committed_err
      end
      local current_catalog, catalog_err = validate_framework_catalog(
        ctx,
        candidate,
        catalog,
        "extract resource validation",
        "resource catalog changed since the review opened"
      )
      if not current_catalog then
        return false, catalog_err
      end
      if type(resource_changes.validate_effective_catalog) ~= "function" then
        return false, "effective resource catalog validation is unavailable"
      end
      local effective, effective_err = resource_changes.validate_effective_catalog(current_catalog)
      if not effective then
        return false, effective_err
      end
      return resource_changes.validate_committed()
    end
    participants[#participants + 1] = resource_changes
  else
    plan.resource_guard = function()
      local current_catalog, catalog_err = validate_framework_catalog(
        ctx,
        candidate,
        catalog,
        "extract reuse",
        "reuse target changed since the review opened"
      )
      if not current_catalog then
        return false, catalog_err
      end
      if not current_catalog.existing_keys[candidate.proposed_key] then
        return false, "reuse target changed since the review opened: not found"
      end
      return true, nil
    end
  end

  participants[#participants + 1] = source_participant(plan)
  local applied, apply_err = mutation_transaction.run(participants)
  if not applied then
    candidate.apply_error = apply_err or "extraction transaction failed"
    candidate.status = "error"
    candidate.error = candidate.apply_error
    vim.notify("i18n-status extract: " .. candidate.error, vim.log.levels.ERROR)
    return false
  end

  catalog.existing_keys[candidate.proposed_key] = true
  if candidate.mode == "new" then
    for _, language in ipairs(candidate.languages) do
      catalog.index[language] = catalog.index[language] or {}
      catalog.index[language][candidate.proposed_key] = {
        priority = 0,
        value = language == candidate.primary_lang and candidate.text or "",
      }
    end
  end
  ctx.existing_keys[candidate.proposed_key] = true
  candidate.apply_error = nil
  candidate.error = nil
  if candidate.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, ctx.source_buf, ctx.track_namespace, candidate.mark_id)
    candidate.mark_id = nil
  end
  return true
end

---@param ctx I18nStatusExtractReviewCtx
---@param candidates I18nStatusExtractCandidate[]
---@param deps I18nStatusExtractApplyDeps
---@return I18nStatusExtractCandidate[]
local function candidates_back_to_front(ctx, candidates, deps)
  local positioned = {}
  for index, candidate in ipairs(candidates) do
    local srow, scol, erow, ecol = deps.candidate_range(ctx, candidate)
    positioned[#positioned + 1] = {
      candidate = candidate,
      srow = srow or -1,
      scol = scol or -1,
      erow = erow or -1,
      ecol = ecol or -1,
      index = index,
    }
  end
  table.sort(positioned, function(a, b)
    for _, field in ipairs(BACK_TO_FRONT_FIELDS) do
      if a[field] ~= b[field] then
        return a[field] > b[field]
      end
    end
    return false
  end)

  local ordered = {}
  for _, entry in ipairs(positioned) do
    ordered[#ordered + 1] = entry.candidate
  end
  return ordered
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
  applicable = candidates_back_to_front(ctx, applicable, deps)

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
