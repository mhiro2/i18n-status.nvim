---@class I18nStatusMutationParticipant
---@field label string
---@field validate? fun(): boolean, string|nil
---@field validate_committed? fun(): boolean, string|nil
---@field validate_effective_catalog? fun(catalog: I18nStatusFrameworkCatalog): boolean, string|nil
---@field commit fun(): boolean, string|nil, boolean|nil
---@field rollback fun(): boolean, string|nil
---@field cleanup? fun(): boolean, string|nil

---@class I18nStatusMutationTransaction
local M = {}

---@param value any
---@return string
local function error_text(value)
  if value == nil then
    return "operation failed"
  end
  return tostring(value)
end

---@param participant I18nStatusMutationParticipant
---@param index integer
---@return string
local function participant_label(participant, index)
  if type(participant.label) == "string" and participant.label ~= "" then
    return participant.label
  end
  return "participant " .. index
end

---@param participant I18nStatusMutationParticipant
---@param index integer
---@param operation "validate"|"commit"|"rollback"|"cleanup"
---@return boolean
---@return string|nil
---@return boolean|nil
local function call(participant, index, operation)
  local callback = participant[operation]
  if not callback then
    return true, nil, false
  end

  local called, ok, err, mutated = pcall(callback)
  if not called then
    return false,
      participant_label(participant, index) .. " " .. operation .. " raised: " .. error_text(ok),
      operation == "commit"
  end
  if ok then
    return true, nil, operation == "commit" or mutated == true
  end
  return false,
    participant_label(participant, index) .. " " .. operation .. " failed: " .. error_text(err),
    mutated == true
end

---@param errors string[]
---@param heading string
---@param entries string[]
local function append_errors(errors, heading, entries)
  if #entries == 0 then
    return
  end
  errors[#errors + 1] = heading .. ": " .. table.concat(entries, "; ")
end

---@param participants I18nStatusMutationParticipant[]
---@return boolean
---@return string|nil
function M.run(participants)
  vim.validate({ participants = { participants, "table" } })

  local committed = {}
  local primary_error = nil
  for index, participant in ipairs(participants) do
    vim.validate({ ["participants[" .. index .. "]"] = { participant, "table" } })
    if type(participant.commit) ~= "function" then
      primary_error = participant_label(participant, index) .. " is missing commit"
      break
    end
    if type(participant.rollback) ~= "function" then
      primary_error = participant_label(participant, index) .. " is missing rollback"
      break
    end
    local ok, err = call(participant, index, "validate")
    if not ok then
      primary_error = err
      break
    end
  end

  if not primary_error then
    for index, participant in ipairs(participants) do
      local ok, err, mutated = call(participant, index, "commit")
      if mutated then
        committed[#committed + 1] = { participant = participant, index = index }
      end
      if not ok then
        primary_error = err
        break
      end
    end
  end

  local rollback_errors = {}
  if primary_error then
    for index = #committed, 1, -1 do
      local entry = committed[index]
      local ok, err = call(entry.participant, entry.index, "rollback")
      if not ok then
        rollback_errors[#rollback_errors + 1] = err
      end
    end
  end

  local cleanup_errors = {}
  for index = #participants, 1, -1 do
    local ok, err = call(participants[index], index, "cleanup")
    if not ok then
      cleanup_errors[#cleanup_errors + 1] = err
    end
  end

  if primary_error then
    local errors = { primary_error }
    append_errors(errors, "rollback errors", rollback_errors)
    append_errors(errors, "cleanup errors", cleanup_errors)
    return false, table.concat(errors, " | ")
  end

  if #cleanup_errors > 0 then
    vim.notify(
      "i18n-status mutation committed, but cleanup failed: " .. table.concat(cleanup_errors, "; "),
      vim.log.levels.ERROR
    )
  end
  return true, nil
end

return M
