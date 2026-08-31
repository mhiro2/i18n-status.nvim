---@class I18nStatusOps
local M = {}

local fs = require("i18n-status.fs")
local json = require("i18n-status.json")
local mutation_transaction = require("i18n-status.mutation_transaction")
local project_identity = require("i18n-status.project_identity")
local resource_roots = require("i18n-status.resource_roots")
local resources = require("i18n-status.resources")
local state = require("i18n-status.state")
local core = require("i18n-status.core")
local scan = require("i18n-status.scan")

---@param kind string|nil
---@return string|nil
local function normalized_root_kind(kind)
  if resource_roots.is_next_intl_kind(kind) then
    return "next-intl"
  end
  return kind
end

---@param identity I18nStatusProjectIdentity
---@param path string
---@param lang string
---@param namespace string
---@param owner { kind: string, root: string, lang?: string, namespace?: string, is_root?: boolean }
---@return I18nStatusResourceInfo|nil
local function owned_resource_info(identity, path, lang, namespace, owner)
  local owner_kind = normalized_root_kind(owner.kind)
  local owner_root = fs.canonical_path(owner.root, nil)
  if not owner_kind or not owner_root then
    return nil
  end

  local root_matches = false
  for _, root in ipairs(identity.cache.roots or {}) do
    local canonical_root = fs.canonical_path(root.path, nil)
    if canonical_root == owner_root and normalized_root_kind(root.kind) == owner_kind then
      root_matches = true
      break
    end
  end
  if not root_matches or not fs.path_under(path, owner_root) then
    return nil
  end

  local info = resource_roots.resource_info_from_roots({
    { kind = owner_kind, path = owner_root },
  }, path)
  if not info or info.lang ~= lang or (not info.is_root and info.namespace ~= namespace) then
    return nil
  end
  if owner.lang and owner.lang ~= info.lang then
    return nil
  end
  if type(owner.is_root) == "boolean" and owner.is_root ~= info.is_root then
    return nil
  end
  if owner.is_root == false and owner.namespace ~= info.namespace then
    return nil
  end
  if owner.is_root == true and owner.namespace ~= nil then
    return nil
  end
  return info
end

---@param info I18nStatusResourceInfo
---@param namespace string
---@param key_path string
---@return string
local function resource_key_path(info, namespace, key_path)
  if not info.is_root then
    return key_path
  end
  if key_path == "" then
    return namespace
  end
  return namespace .. "." .. key_path
end

---@param tbl table
---@param key_path string
---@return any
local function get_nested(tbl, key_path)
  local parts = vim.split(key_path, ".", { plain = true })
  local cur = tbl
  for _, key in ipairs(parts) do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[key]
  end
  return cur
end

---@param tbl table
---@param key_path string
---@return boolean
local function delete_nested(tbl, key_path)
  local parts = vim.split(key_path, ".", { plain = true })
  local cur = tbl
  for i = 1, #parts - 1 do
    local key = parts[i]
    if type(cur[key]) ~= "table" then
      return false
    end
    cur = cur[key]
  end
  if cur[parts[#parts]] == nil then
    return false
  end
  cur[parts[#parts]] = nil
  return true
end

---@param input string
---@param fallback_ns string
---@return string|nil key
---@return string|nil namespace
---@return string|nil key_path
---@return boolean explicit_namespace
---@return string|nil error
local function normalize_key(input, fallback_ns)
  local key = vim.trim(input)
  local first_colon = key:find(":", 1, true)
  if first_colon and key:find(":", first_colon + 1, true) then
    return nil, nil, nil, false, "new key can only contain one ':' separator"
  end

  local explicit_ns = first_colon ~= nil
  local ns = explicit_ns and key:sub(1, first_colon - 1) or fallback_ns
  local key_path = explicit_ns and key:sub(first_colon + 1) or key
  if not ns or ns == "" then
    return nil, nil, nil, explicit_ns, "namespace is empty"
  end
  if key_path == "" or key_path:match("^%.") or key_path:match("%.$") or key_path:match("%.%.") then
    return nil, nil, nil, explicit_ns, "invalid key path"
  end
  if not ns:match("^[%w_%-%.]+$") then
    return nil, nil, nil, explicit_ns, "invalid namespace format"
  end
  if not key_path:match("^[%w_%-%.]+$") then
    return nil, nil, nil, explicit_ns, "invalid key path format"
  end

  return ns .. ":" .. key_path, ns, key_path, explicit_ns, nil
end

---@param bufnr integer
---@param old_key string
---@param new_key string
---@param new_ns string
---@param explicit_ns boolean
---@param fallback_ns string
---@param identity I18nStatusProjectIdentity
---@return table|nil plan
---@return string|nil error
local function plan_buffer_rename(bufnr, old_key, new_key, new_ns, explicit_ns, fallback_ns, identity)
  local items, snapshot = scan.extract_for_refactor(bufnr, {
    fallback_namespace = fallback_ns,
  })
  if not items then
    return nil, tostring(snapshot or "source scan failed")
  end

  local edits = {}
  for _, item in ipairs(items) do
    if item.key == old_key then
      if item.refactorable ~= true then
        return nil,
          string.format(
            "cannot safely rename computed translation reference in buffer %d at line %d",
            bufnr,
            item.lnum + 1
          )
      end
      local new_raw = new_key
      if not item.raw:find(":", 1, true) then
        if explicit_ns and item.namespace ~= new_ns then
          new_raw = new_key
        else
          new_raw = new_key:match("^[^:]+:(.+)$") or new_key
        end
      end
      local end_lnum = item.end_lnum
      if
        type(item.lnum) ~= "number"
        or type(item.col) ~= "number"
        or type(end_lnum) ~= "number"
        or type(item.end_col) ~= "number"
      then
        return nil, string.format("invalid translation reference range in buffer %d", bufnr)
      end
      local ok_old, old_chunks =
        pcall(vim.api.nvim_buf_get_text, bufnr, item.lnum, item.col, end_lnum, item.end_col, {})
      if not ok_old or type(old_chunks) ~= "table" then
        return nil, string.format("failed to read translation reference in buffer %d", bufnr)
      end
      local old_text = table.concat(old_chunks, "\n")
      local quote = old_text:sub(1, 1)
      if #old_text < 2 or (quote ~= '"' and quote ~= "'" and quote ~= "`") or old_text:sub(-1) ~= quote then
        return nil, string.format("translation reference is not a direct literal in buffer %d", bufnr)
      end
      if old_text:sub(2, -2) ~= item.raw then
        return nil, string.format("translation reference does not match scanner value in buffer %d", bufnr)
      end
      table.insert(edits, {
        lnum = item.lnum,
        col = item.col,
        end_lnum = end_lnum,
        end_col = item.end_col,
        old_text = old_text,
        new_text = vim.json.encode(new_raw),
      })
    end
  end

  table.sort(edits, function(a, b)
    if a.lnum == b.lnum then
      return a.col > b.col
    end
    return a.lnum > b.lnum
  end)

  for index = 2, #edits do
    local later = edits[index - 1]
    local earlier = edits[index]
    local overlaps = earlier.end_lnum > later.lnum or (earlier.end_lnum == later.lnum and earlier.end_col > later.col)
    if overlaps then
      return nil, string.format("overlapping translation reference ranges in buffer %d", bufnr)
    end
  end

  return {
    applied = {},
    bufnr = bufnr,
    edits = edits,
    expected_tick = snapshot.tick,
    identity = identity,
    initial_lines = snapshot.lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    initial_modified = vim.bo[bufnr].modified,
    rollback_blocked = false,
  },
    nil
end

---@param bufnr integer
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return string|nil
local function buffer_text(bufnr, start_row, start_col, end_row, end_col)
  local ok, chunks = pcall(vim.api.nvim_buf_get_text, bufnr, start_row, start_col, end_row, end_col, {})
  if not ok or type(chunks) ~= "table" then
    return nil
  end
  return table.concat(chunks, "\n")
end

---@param plan table
---@return boolean
---@return string|nil
local function validate_source_plan(plan)
  local _, identity_err = project_identity.validate(plan.bufnr, plan.identity, "rename")
  if identity_err then
    return false, identity_err
  end
  if not vim.bo[plan.bufnr].modifiable then
    return false, "source buffer is not modifiable"
  end
  if vim.api.nvim_buf_get_changedtick(plan.bufnr) ~= plan.expected_tick then
    return false, "source buffer changed before rename"
  end
  for _, edit in ipairs(plan.edits) do
    local current = buffer_text(plan.bufnr, edit.lnum, edit.col, edit.end_lnum, edit.end_col)
    if current ~= edit.old_text then
      return false, string.format("translation reference changed before rename at line %d", edit.lnum + 1)
    end
  end
  return true, nil
end

---@param plan table
---@return boolean
---@return string|nil
---@return boolean
local function commit_source_plan(plan)
  local valid, validation_err = validate_source_plan(plan)
  if not valid then
    return false, validation_err, false
  end

  for _, edit in ipairs(plan.edits) do
    local before_tick = vim.api.nvim_buf_get_changedtick(plan.bufnr)
    if before_tick ~= plan.expected_tick then
      return false, "source buffer changed while applying rename", #plan.applied > 0
    end
    local old_text = buffer_text(plan.bufnr, edit.lnum, edit.col, edit.end_lnum, edit.end_col)
    if old_text ~= edit.old_text then
      return false,
        string.format("translation reference changed while applying rename at line %d", edit.lnum + 1),
        #plan.applied > 0
    end
    local ok, set_err =
      pcall(vim.api.nvim_buf_set_text, plan.bufnr, edit.lnum, edit.col, edit.end_lnum, edit.end_col, { edit.new_text })
    local replacement_end_col = edit.col + #edit.new_text
    local current = buffer_text(plan.bufnr, edit.lnum, edit.col, edit.lnum, replacement_end_col)
    local changed = vim.api.nvim_buf_get_changedtick(plan.bufnr) ~= before_tick
    if current == edit.new_text and changed then
      plan.applied[#plan.applied + 1] = {
        edit = edit,
        end_lnum = edit.lnum,
        end_col = replacement_end_col,
      }
      plan.expected_tick = vim.api.nvim_buf_get_changedtick(plan.bufnr)
    elseif changed then
      plan.rollback_blocked = true
      plan.expected_tick = vim.api.nvim_buf_get_changedtick(plan.bufnr)
    end
    if not ok or current ~= edit.new_text then
      return false,
        string.format(
          "failed to update source buffer %d at line %d: %s",
          plan.bufnr,
          edit.lnum + 1,
          tostring(set_err or "replacement mismatch")
        ),
        #plan.applied > 0 or changed
    end
  end
  return true, nil, #plan.applied > 0
end

---@param plan table
---@return boolean
---@return string|nil
local function rollback_source_plan(plan)
  local stable, stability_err = project_identity.validate_buffer(plan.bufnr, plan.identity, "rename rollback")
  if not stable then
    return false, stability_err
  end
  if vim.api.nvim_buf_get_changedtick(plan.bufnr) ~= plan.expected_tick then
    return false, "source buffer changed after rename; preserving concurrent edits"
  end
  if plan.rollback_blocked then
    return false, "source mutation did not match the planned replacement; preserving concurrent edits"
  end

  for index = #plan.applied, 1, -1 do
    if vim.api.nvim_buf_get_changedtick(plan.bufnr) ~= plan.expected_tick then
      return false, "source buffer changed during rollback; preserving concurrent edits"
    end
    local applied = plan.applied[index]
    local edit = applied.edit
    local current = buffer_text(plan.bufnr, edit.lnum, edit.col, applied.end_lnum, applied.end_col)
    if current ~= edit.new_text then
      return false, "source replacement changed after rename; preserving concurrent edits"
    end
    local ok, restore_err = pcall(
      vim.api.nvim_buf_set_text,
      plan.bufnr,
      edit.lnum,
      edit.col,
      applied.end_lnum,
      applied.end_col,
      vim.split(edit.old_text, "\n", { plain = true })
    )
    if not ok then
      return false, "failed to restore source buffer: " .. tostring(restore_err)
    end
    plan.expected_tick = vim.api.nvim_buf_get_changedtick(plan.bufnr)
  end

  local current_lines = vim.api.nvim_buf_get_lines(plan.bufnr, 0, -1, false)
  if not plan.initial_modified and vim.deep_equal(current_lines, plan.initial_lines) then
    vim.bo[plan.bufnr].modified = false
  end
  return true, nil
end

---@param plan table
---@return I18nStatusMutationParticipant
local function source_participant(plan)
  return {
    label = "source " .. plan.identity.name,
    validate = function()
      return validate_source_plan(plan)
    end,
    commit = function()
      return commit_source_plan(plan)
    end,
    rollback = function()
      return rollback_source_plan(plan)
    end,
  }
end

---@param cache table|nil
---@return string[]
local function active_languages(cache)
  local langs = {}
  if cache and cache.languages then
    for _, lang in ipairs(cache.languages) do
      table.insert(langs, lang)
    end
  end
  return langs
end

---@param entries table<string, I18nStatusResourceItem>|nil
---@param old_key string
---@param new_key string
---@return boolean
local function target_key_conflicts(entries, old_key, new_key)
  local descendant_prefix = new_key .. "."
  for key, _ in pairs(entries or {}) do
    if
      key ~= old_key
      and (
        key == new_key
        or key:sub(1, #descendant_prefix) == descendant_prefix
        or new_key:sub(1, #key + 1) == key .. "."
      )
    then
      return true
    end
  end
  return false
end

---@param opts { item: I18nStatusResolved, source_buf?: integer, new_key: string, config: I18nStatusConfig }
---@return boolean, string?
function M.rename(opts)
  if not opts or not opts.item or not opts.new_key or not opts.config then
    return false, "invalid arguments"
  end

  local item = opts.item
  local source_buf = opts.source_buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(source_buf) then
    return false, "source buffer is invalid"
  end
  local target_identity, identity_err = project_identity.resolve(source_buf)
  if not target_identity then
    return false, identity_err or "failed to resolve source project"
  end

  -- Prevent renaming missing keys
  if item.status == "×" then
    return false, "Primary language definition not found"
  end

  local fallback_ns = item.namespace or resources.fallback_namespace_for_buf(source_buf)
  local old_key = item.key
  local new_key_input = vim.trim(opts.new_key)
  if new_key_input == "" then
    return false, "new key is empty"
  end

  local new_key, new_ns, new_path, explicit_ns, normalize_err = normalize_key(new_key_input, fallback_ns)
  if not new_key or not new_ns or not new_path then
    return false, normalize_err or "invalid new key"
  end
  if new_key == old_key then
    return true
  end

  local old_ns = old_key:match("^(.-):") or fallback_ns
  local old_path = old_key:match("^[^:]+:(.+)$") or ""
  local cache = target_identity.cache
  local base_dir = target_identity.root
  local langs = active_languages(cache)
  if #langs == 0 then
    return false, "no languages detected"
  end

  local buffer_plans = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if project_identity.is_source_buffer(buf) then
      local candidate_name = fs.canonical_path(vim.api.nvim_buf_get_name(buf), nil)
      if candidate_name and fs.path_under(candidate_name, target_identity.root) then
        local candidate_identity, candidate_err = project_identity.resolve(buf)
        if not candidate_identity then
          return false,
            string.format("failed to resolve project for source buffer %d: %s", buf, candidate_err or "unknown")
        end
        if project_identity.same_project(candidate_identity, target_identity) then
          local fb = resources.fallback_namespace_for_buf(buf)
          local plan, plan_err = plan_buffer_rename(buf, old_key, new_key, new_ns, explicit_ns, fb, candidate_identity)
          if not plan then
            return false, plan_err or "failed to plan source rename"
          end
          if #plan.edits > 0 then
            table.insert(buffer_plans, plan)
          end
        end
      end
    end
  end
  table.sort(buffer_plans, function(a, b)
    if a.identity.name == b.identity.name then
      return a.bufnr < b.bufnr
    end
    return a.identity.name < b.identity.name
  end)

  local file_cache = {}

  local function file_state(path)
    if not file_cache[path] then
      local data, style = resources.read_json_table(path)
      if not data then
        return nil, (style and style.error) or "unknown"
      end
      file_cache[path] = { data = data, style = style, dirty = false }
    end
    return file_cache[path]
  end

  ---@param path string
  ---@param lang string
  ---@return string|nil
  ---@return string|nil
  local function sanitize_resource_path(path, lang)
    local sanitized_path, sanitize_err = fs.sanitize_path(path, base_dir)
    if not sanitized_path then
      return nil,
        string.format("resource path for language '%s' is outside project root: %s", lang, sanitize_err or "unknown")
    end
    return sanitized_path, nil
  end

  local found_definition = false
  for _, lang in ipairs(langs) do
    local info = item.hover and item.hover.values and item.hover.values[lang]
    local lang_index = cache.index and cache.index[lang]
    if target_key_conflicts(lang_index, old_key, new_key) then
      return false, "target key already exists (" .. lang .. ")"
    end
    local indexed_entry = lang_index and lang_index[old_key]
    local indexed_file = indexed_entry and indexed_entry.file
    if not indexed_file then
      if info and info.file then
        local _, hover_file_err = sanitize_resource_path(info.file, lang)
        if hover_file_err then
          return false, hover_file_err
        end
        return false, string.format("resource location for language '%s' changed; refresh before renaming", lang)
      end
      if info and not info.missing then
        return false, string.format("resource definition for language '%s' changed; refresh before renaming", lang)
      end
    else
      local old_file, old_file_err = sanitize_resource_path(indexed_file, lang)
      if not old_file then
        return false, old_file_err
      end
      if not cache.files or cache.files[old_file] == nil then
        return false, string.format("resource index for language '%s' changed; refresh before renaming", lang)
      end
      local owner = cache.file_meta and cache.file_meta[old_file]
      if type(owner) ~= "table" then
        return false, string.format("resource ownership for language '%s' is unavailable", lang)
      end
      local old_resource_info = owned_resource_info(target_identity, old_file, lang, old_ns, owner)
      if not old_resource_info then
        return false, string.format("resource path for language '%s' does not belong to the target project", lang)
      end

      if info and info.file then
        local hover_file, hover_file_err = sanitize_resource_path(info.file, lang)
        if not hover_file then
          return false, hover_file_err
        end
        if hover_file ~= old_file then
          return false, string.format("resource location for language '%s' changed; refresh before renaming", lang)
        end
      elseif info and not info.missing then
        return false, string.format("resource location for language '%s' changed; refresh before renaming", lang)
      end

      local new_file_raw = old_resource_info.is_root and old_file
        or fs.path_join(old_resource_info.root, lang, new_ns .. ".json")
      local new_file, new_file_err = sanitize_resource_path(new_file_raw, lang)
      if not new_file then
        return false, new_file_err
      end
      local new_resource_info = owned_resource_info(target_identity, new_file, lang, new_ns, {
        kind = old_resource_info.kind,
        root = old_resource_info.root,
      })
      if not new_resource_info then
        return false,
          string.format("target resource path for language '%s' does not belong to the target project", lang)
      end
      local same_file = old_file == new_file

      local dir_ok, dir_err = fs.ensure_dir_within(fs.dirname(new_file), base_dir)
      if not dir_ok then
        return false,
          string.format("failed to prepare resource directory for language '%s': %s", lang, dir_err or "unknown")
      end

      local old_state, old_err = file_state(old_file)
      if not old_state then
        return false,
          string.format(
            "Failed to parse JSON file '%s': %s. "
              .. "The file may contain syntax errors. Please validate the JSON syntax.",
            old_file,
            old_err
          )
      end
      local new_state = old_state
      if not same_file then
        local state_new, new_err = file_state(new_file)
        if not state_new then
          return false,
            string.format(
              "Failed to parse JSON file '%s': %s. "
                .. "The file may contain syntax errors. Please validate the JSON syntax.",
              new_file,
              new_err
            )
        end
        new_state = state_new
      end

      local old_path_in_file = resource_key_path(old_resource_info, old_ns, old_path)
      local new_path_in_file = resource_key_path(new_resource_info, new_ns, new_path)
      if
        same_file
        and (
          old_path_in_file:sub(1, #new_path_in_file + 1) == new_path_in_file .. "."
          or new_path_in_file:sub(1, #old_path_in_file + 1) == old_path_in_file .. "."
        )
      then
        return false, "cannot rename a translation key to or from its own descendant"
      end
      local old_value = get_nested(old_state.data, old_path_in_file)
      if old_value == nil then
        return false, string.format("resource definition for language '%s' changed; refresh before renaming", lang)
      end
      if json.is_object(old_value) then
        return false, string.format("resource definition for language '%s' is no longer a translation leaf", lang)
      end
      found_definition = true

      local existing = get_nested(new_state.data, new_path_in_file)
      if existing ~= nil then
        return false, "target key already exists (" .. lang .. ")"
      end
      local set_ok, set_err = json.set_nested(new_state.data, new_path_in_file, old_value)
      if not set_ok then
        return false, string.format("%s (%s)", set_err or "failed to set key", lang)
      end
      new_state.dirty = true

      if same_file then
        delete_nested(new_state.data, old_path_in_file)
      else
        delete_nested(old_state.data, old_path_in_file)
        old_state.dirty = true
      end
    end
  end

  if not found_definition then
    return false, "translation key is not defined in the target project"
  end

  local dirty_paths = {}
  for path, entry in pairs(file_cache) do
    if entry.dirty then
      dirty_paths[#dirty_paths + 1] = path
    end
  end
  table.sort(dirty_paths)

  local resource_entries = {}

  ---@return string[]
  local function discard_prepared_resources()
    local cleanup_errors = {}
    for index = #resource_entries, 1, -1 do
      local prepared = resource_entries[index]
      local called, discarded, discard_err = pcall(resources.discard_json_write, prepared.plan)
      if not called then
        cleanup_errors[#cleanup_errors + 1] = prepared.path .. ": " .. tostring(discarded)
      elseif not discarded then
        cleanup_errors[#cleanup_errors + 1] = prepared.path .. ": " .. tostring(discard_err or "unknown")
      end
    end
    return cleanup_errors
  end

  ---@param message string
  ---@return string
  local function preparation_failure(message)
    local cleanup_errors = discard_prepared_resources()
    if #cleanup_errors > 0 then
      return message .. "; cleanup failed: " .. table.concat(cleanup_errors, "; ")
    end
    return message
  end

  for _, path in ipairs(dirty_paths) do
    local entry = file_cache[path]
    local dir_ok, dir_err = fs.ensure_dir_within(fs.dirname(path), base_dir)
    if not dir_ok then
      return false,
        preparation_failure(
          string.format("failed to prepare resource directory for %s: %s", path, dir_err or "unknown")
        )
    end
    local called, plan, prepare_err = pcall(resources.prepare_json_write, path, entry.data, entry.style, {
      base_dir = base_dir,
    })
    if not called then
      prepare_err = "prepare raised: " .. tostring(plan)
      plan = nil
    end
    if not plan then
      local message = string.format("failed to prepare %s: %s", path, prepare_err or "unknown")
      return false, preparation_failure(message)
    end
    resource_entries[#resource_entries + 1] = {
      data = entry.data,
      path = path,
      plan = plan,
      style = entry.style,
    }
  end

  local participants = {}
  for _, plan in ipairs(buffer_plans) do
    participants[#participants + 1] = source_participant(plan)
  end
  for _, entry in ipairs(resource_entries) do
    local resource_entry = entry
    participants[#participants + 1] = {
      label = "resource " .. resource_entry.path,
      validate = function()
        return resources.validate_json_write(resource_entry.path, resource_entry.data, resource_entry.style, {
          base_dir = base_dir,
        })
      end,
      commit = function()
        local committed, commit_err = resources.commit_json_write(resource_entry.plan)
        return committed, commit_err, resource_entry.plan.atomic.committed_ok == true
      end,
      rollback = function()
        local called, rolled_back, rollback_err = pcall(resources.rollback_json_write, resource_entry.plan)
        if called and rolled_back then
          return true, nil
        end
        local protect_called, protected, protect_err = pcall(resources.protect_json_write, resource_entry.plan)
        local message = called and (rollback_err or "resource rollback failed")
          or ("resource rollback raised: " .. tostring(rolled_back))
        if not protect_called then
          message = message .. "; recovery protection raised: " .. tostring(protected)
        elseif not protected then
          message = message .. "; failed to protect recovery files: " .. tostring(protect_err or "unknown")
        end
        return false, message
      end,
      cleanup = function()
        return resources.discard_json_write(resource_entry.plan)
      end,
    }
  end

  local renamed, rename_err = mutation_transaction.run(participants)
  if not renamed then
    return false, rename_err or "rename transaction failed"
  end

  state.set_languages(cache.key, cache.languages)
  state.set_buf_project(source_buf, cache.key)
  for _, plan in ipairs(buffer_plans) do
    state.set_buf_project(plan.bufnr, cache.key)
    local refreshed, refresh_err = pcall(core.refresh_now, plan.bufnr, opts.config)
    if not refreshed then
      vim.notify(
        string.format("i18n-status: rename committed but buffer %d refresh failed: %s", plan.bufnr, refresh_err),
        vim.log.levels.ERROR
      )
    end
  end

  return true
end

return M
