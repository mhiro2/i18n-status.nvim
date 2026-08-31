---@class I18nStatusKeyWrite
local M = {}

local fs = require("i18n-status.fs")
local json = require("i18n-status.json")
local mutation_transaction = require("i18n-status.mutation_transaction")
local resource_catalog = require("i18n-status.resource_catalog")
local resources = require("i18n-status.resources")

---@class I18nStatusKeyWriteEntry
---@field lang string
---@field path string
---@field data table
---@field style table
---@field base_dir string
---@field plan I18nStatusResourceWritePlan|nil

---@class I18nStatusKeyWriteOpts
---@field create_only? boolean
---@field framework? 'i18next'|'next_intl'
---@field expected_languages? string[]

---@param languages string[]
---@return string[]
local function copy_languages(languages)
  return vim.deepcopy(languages or {})
end

---@param data table
---@param key_path string
---@return 'absent'|'leaf'|'branch'|'ancestor'
local function nested_target_state(data, key_path)
  local current = data
  local parts = vim.split(key_path, ".", { plain = true })
  for index, key in ipairs(parts) do
    if not json.is_object(current) then
      return "ancestor"
    end
    local value = current[key]
    if index == #parts then
      if value == nil then
        return "absent"
      end
      return type(value) == "table" and "branch" or "leaf"
    end
    if value == nil then
      return "absent"
    end
    current = value
  end
  return "absent"
end

---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param base_dir string
---@param lang string
---@param opts I18nStatusKeyWriteOpts
---@param root_list I18nStatusRootInfo[]
---@return I18nStatusKeyWriteEntry|nil
---@return string|nil
local function prepare_entry(namespace, key_path, translations, start_dir, base_dir, lang, opts, root_list)
  local path = resources.namespace_path(start_dir, lang, namespace, opts.framework, root_list)
  if not path then
    return nil, "resource path not found"
  end

  local sanitized_path, sanitize_err = fs.sanitize_path(path, base_dir)
  if not sanitized_path then
    return nil, sanitize_err or "unsafe resource path"
  end

  local dir_ok, dir_err = fs.ensure_dir_within(fs.dirname(sanitized_path), base_dir)
  if not dir_ok then
    return nil, dir_err or "failed to prepare resource directory"
  end

  local data, style = resources.read_json_table(sanitized_path)
  if not data then
    return nil, (style and style.error) or "failed to read resource file"
  end

  local path_in_file = resources.key_path_for_file(namespace, key_path, start_dir, lang, sanitized_path, root_list)
  local target_state = nested_target_state(data, path_in_file)
  if target_state == "ancestor" then
    return nil, "target key conflicts with an existing ancestor"
  end
  if target_state == "branch" then
    return nil, "target key has existing descendants"
  end
  if opts.create_only and target_state == "leaf" then
    return nil, "target key already exists"
  end
  local set_ok, set_err = json.set_nested(data, path_in_file, translations[lang] or "")
  if not set_ok then
    return nil, set_err or "failed to set translation"
  end
  return {
    lang = lang,
    path = sanitized_path,
    data = data,
    style = style,
    base_dir = base_dir,
    plan = nil,
  },
    nil
end

---@param entries I18nStatusKeyWriteEntry[]
---@return boolean
---@return string|nil
local function discard_entries(entries)
  local errors = {}
  for index = #entries, 1, -1 do
    local entry = entries[index]
    if entry.plan then
      local called, discarded, discard_err = pcall(resources.discard_json_write, entry.plan)
      if not called then
        errors[#errors + 1] = string.format("%s (%s): discard raised: %s", entry.lang, entry.path, tostring(discarded))
      elseif not discarded then
        errors[#errors + 1] = string.format("%s (%s): %s", entry.lang, entry.path, discard_err or "unknown")
      end
    end
  end
  if #errors > 0 then
    return false, table.concat(errors, "; ")
  end
  return true, nil
end

---@param entry I18nStatusKeyWriteEntry
---@return string|nil
local function protect_entry(entry)
  local called, protected, protect_err = pcall(resources.protect_json_write, entry.plan)
  if not called then
    return string.format("%s (%s): recovery protection raised: %s", entry.lang, entry.path, tostring(protected))
  end
  if not protected then
    return string.format("%s (%s): %s", entry.lang, entry.path, protect_err or "recovery protection failed")
  end
  return nil
end

---@param entries I18nStatusKeyWriteEntry[]
---@param label string
---@return I18nStatusMutationParticipant
local function resource_participant(entries, label)
  local committed = {}
  local function validate_entries()
    for _, entry in ipairs(entries) do
      local valid, validation_err = resources.validate_json_write(entry.path, entry.data, entry.style, {
        base_dir = entry.base_dir,
      })
      if not valid then
        return false, string.format("%s (%s): %s", entry.lang, entry.path, validation_err or "unknown")
      end
    end
    return true, nil
  end

  return {
    label = label,
    validate = validate_entries,
    validate_committed = function()
      for _, entry in ipairs(entries) do
        if not entry.plan.atomic.committed_ok or not entry.plan.atomic.committed then
          return false, string.format("%s (%s): resource commit is unavailable", entry.lang, entry.path)
        end
      end
      return validate_entries()
    end,
    commit = function()
      for _, entry in ipairs(entries) do
        local called, committed_ok, commit_err = pcall(resources.commit_json_write, entry.plan)
        if entry.plan.atomic.committed_ok then
          committed[#committed + 1] = entry
        end
        if not called then
          return false,
            string.format("%s (%s): commit raised: %s", entry.lang, entry.path, tostring(committed_ok)),
            #committed > 0
        elseif not committed_ok then
          return false, string.format("%s (%s): %s", entry.lang, entry.path, commit_err or "unknown"), #committed > 0
        end
      end
      return true, nil, #committed > 0
    end,
    rollback = function()
      local errors = {}
      for index = #committed, 1, -1 do
        local entry = committed[index]
        local called, rolled_back, rollback_err = pcall(resources.rollback_json_write, entry.plan)
        if not called then
          errors[#errors + 1] =
            string.format("%s (%s): rollback raised: %s", entry.lang, entry.path, tostring(rolled_back))
        elseif not rolled_back then
          errors[#errors + 1] = string.format("%s (%s): %s", entry.lang, entry.path, rollback_err or "unknown")
        end
        if not called or not rolled_back then
          local protect_err = protect_entry(entry)
          if protect_err then
            errors[#errors + 1] = protect_err
          end
        end
      end
      if #errors > 0 then
        return false, table.concat(errors, "; ")
      end
      return true, nil
    end,
    cleanup = function()
      return discard_entries(entries)
    end,
  }
end

---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param languages string[]
---@param opts? I18nStatusKeyWriteOpts
---@return I18nStatusMutationParticipant|nil participant
---@return integer entry_count
---@return string[] failed_langs
---@return string|nil err
function M.prepare_translations(namespace, key_path, translations, start_dir, languages, opts)
  opts = opts or {}
  if #languages == 0 then
    return nil, 0, {}, "no resource languages"
  end

  local cache = resources.ensure_index(start_dir, { exact = true })
  local root_list = (cache and cache.roots) or {}
  if opts.framework then
    local catalog, catalog_err = resource_catalog.build(start_dir, opts.framework, cache)
    if not catalog then
      return nil, 0, copy_languages(languages), catalog_err
    end
    if #catalog.errors > 0 then
      return nil, 0, copy_languages(languages), "framework resource catalog contains errors"
    end
    root_list = catalog.roots
    if opts.expected_languages and not resource_catalog.same_languages(catalog.languages, opts.expected_languages) then
      return nil, 0, copy_languages(languages), "resource languages changed since the review opened"
    end
    if opts.create_only then
      local full_key = namespace .. ":" .. key_path
      local conflicting_language = resource_catalog.target_conflict(catalog, full_key, languages)
      if conflicting_language then
        return nil, 0, copy_languages(languages), "target key already exists (" .. conflicting_language .. ")"
      end
    end
  end

  local base_dir = resources.project_root(start_dir, cache and cache.roots or nil)
  if not base_dir or base_dir == "" then
    base_dir = start_dir
  end

  local entries = {}
  local failed_langs = {}
  local errors = {}
  for _, lang in ipairs(languages) do
    local entry, entry_err =
      prepare_entry(namespace, key_path, translations, start_dir, base_dir, lang, opts, root_list)
    if entry then
      entries[#entries + 1] = entry
    else
      failed_langs[#failed_langs + 1] = lang
      errors[#errors + 1] = string.format("%s: %s", lang, entry_err or "unknown")
    end
  end
  if #failed_langs > 0 then
    return nil, 0, failed_langs, table.concat(errors, "; ")
  end

  local prepared = {}
  for _, entry in ipairs(entries) do
    local plan, plan_err = resources.prepare_json_write(entry.path, entry.data, entry.style, {
      base_dir = entry.base_dir,
    })
    if not plan then
      local cleanup_ok, cleanup_err = discard_entries(prepared)
      local message = string.format("%s: %s", entry.lang, plan_err or "unknown")
      if not cleanup_ok then
        message = message .. "; cleanup failed: " .. tostring(cleanup_err)
      end
      return nil, 0, copy_languages(languages), message
    end
    entry.plan = plan
    prepared[#prepared + 1] = entry
  end

  return resource_participant(entries, "resources " .. namespace .. ":" .. key_path), #entries, {}, nil
end

---Write a single translation value to a language file.
---@param namespace string
---@param key_path string
---@param lang string
---@param value string
---@param start_dir string
---@return boolean
function M.write_single_translation(namespace, key_path, lang, value, start_dir)
  local success_count = M.write_translations(namespace, key_path, { [lang] = value }, start_dir, { lang })
  return success_count == 1
end

---Write translation values to all language files.
---@param namespace string
---@param key_path string
---@param translations table<string, string>
---@param start_dir string
---@param languages string[]
---@param opts? I18nStatusKeyWriteOpts
---@return integer success_count
---@return string[] failed_langs
---@return string|nil err
function M.write_translations(namespace, key_path, translations, start_dir, languages, opts)
  local participant, entry_count, failed_langs, prepare_err =
    M.prepare_translations(namespace, key_path, translations, start_dir, languages, opts)
  if not participant then
    return 0, failed_langs, prepare_err
  end

  local committed, transaction_err = mutation_transaction.run({ participant })
  if not committed then
    return 0, copy_languages(languages), transaction_err
  end
  return entry_count, {}, transaction_err
end

return M
