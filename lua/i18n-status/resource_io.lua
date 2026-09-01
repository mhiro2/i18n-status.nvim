---@class I18nStatusResourceIo
local M = {}

local atomic_file = require("i18n-status.atomic_file")
local fs = require("i18n-status.fs")
local json = require("i18n-status.json")

---@param path string
---@param err string|nil
local function notify_write_failure(path, err)
  vim.schedule(function()
    vim.notify(
      string.format("i18n-status: failed to write json file (%s): %s", path, err or "unknown"),
      vim.log.levels.WARN
    )
  end)
end

---@class I18nStatusResourceWriteOpts
---@field mark_dirty fun(path: string)|nil
---@field base_dir string

---@class I18nStatusResourceWritePlan
---@field atomic I18nStatusAtomicFilePlan
---@field content string
---@field opts I18nStatusResourceWriteOpts
---@field style I18nStatusJsonStyle

---@param path string
---@return string
local function normalized_path(path)
  return fs.canonical_path(path) or fs.normalize_path(path) or path:gsub("\\", "/")
end

---@param path string
---@return integer[]
local function loaded_buffers(path)
  local target = normalized_path(path)
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and normalized_path(name) == target then
        buffers[#buffers + 1] = bufnr
      end
    end
  end
  return buffers
end

---@param path string
---@return integer|nil
---@return string|nil
local function validate_loaded_buffers(path)
  for _, bufnr in ipairs(loaded_buffers(path)) do
    if vim.bo[bufnr].modified then
      return nil, string.format("resource buffer %d has unsaved changes", bufnr)
    end
    if not vim.bo[bufnr].modifiable then
      return nil, string.format("resource buffer %d is not modifiable", bufnr)
    end
  end
  return 1, nil
end

---@param content string|nil
---@return string[]
local function buffer_lines(content)
  if not content or content == "" then
    return { "" }
  end
  local lines = vim.split(content, "\n", { plain = true })
  if content:sub(-1) == "\n" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

---@param path string
---@param content string|nil
---@return boolean
---@return string|nil
local function sync_loaded_buffers(path, content)
  local valid, validation_err = validate_loaded_buffers(path)
  if not valid then
    return false, validation_err
  end
  for _, bufnr in ipairs(loaded_buffers(path)) do
    local ok, sync_err = pcall(function()
      if content ~= nil then
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent noautocmd keepalt keepjumps edit!")
        end)
      else
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(nil))
        vim.bo[bufnr].endofline = false
        vim.bo[bufnr].modified = false
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent! noautocmd checktime")
        end)
      end
    end)
    if not ok then
      return false, string.format("failed to synchronize resource buffer %d: %s", bufnr, sync_err)
    end
  end
  return true, nil
end

---@param path string
---@param style I18nStatusJsonStyle
---@param opts I18nStatusResourceWriteOpts
---@return string|nil
---@return string|nil
local function validate_write_target(path, style, opts)
  local safe_path, sanitize_err = fs.sanitize_path(path, opts.base_dir)
  if not safe_path then
    return nil, "unsafe resource path: " .. (sanitize_err or "unknown")
  end
  if safe_path ~= style.path then
    return nil, "resource path changed since it was read"
  end

  local buffers_valid, buffer_err = validate_loaded_buffers(safe_path)
  if not buffers_valid then
    return nil, buffer_err
  end

  local current, revision_err = atomic_file.read_revision(safe_path)
  if not current then
    return nil, revision_err
  end
  if not atomic_file.revisions_equal(style.revision, current) then
    return nil, "resource changed on disk since it was read"
  end
  return safe_path, nil
end

---@param path string
---@return table|nil
---@return string|nil
function M.read_json(path)
  local content = fs.read_file(path)
  if content == nil then
    return nil, "read failed"
  end
  return json.json_decode(content)
end

---@param path string
---@return table|nil
---@return I18nStatusJsonStyle
function M.read_json_table(path)
  local revision, revision_err = atomic_file.read_revision(path)
  local style = {
    indent = "  ",
    newline = true,
    path = normalized_path(path),
    revision = revision,
  }
  if not revision then
    style.error = revision_err
    return nil, style
  end
  if not revision.exists then
    return vim.empty_dict(), style
  end

  local content = revision.content or ""
  local decoded, decode_err = json.json_decode(content)
  style.indent = json.detect_indent(content)
  style.newline = content:sub(-1) == "\n"
  if decoded == nil then
    style.error = decode_err
    return nil, style
  end
  if not json.is_object(decoded) then
    style.error = "JSON root must be an object"
    return nil, style
  end
  return decoded, style
end

---@param path string
---@param data table
---@param style I18nStatusJsonStyle|nil
---@param opts I18nStatusResourceWriteOpts|nil
---@return boolean
---@return string|nil
function M.validate_json_write(path, data, style, opts)
  if not json.is_object(data) then
    return false, "JSON root must be an object"
  end
  if type(style) ~= "table" or type(style.path) ~= "string" or type(style.revision) ~= "table" then
    return false, "resource revision is required"
  end
  if type(opts) ~= "table" or type(opts.base_dir) ~= "string" or opts.base_dir == "" then
    return false, "resource base directory is required"
  end
  local safe_path, validation_err = validate_write_target(path, style, opts)
  return safe_path ~= nil, validation_err
end

---@param path string
---@param data table
---@param style I18nStatusJsonStyle|nil
---@param opts I18nStatusResourceWriteOpts|nil
---@return I18nStatusResourceWritePlan|nil
---@return string|nil
function M.prepare_json_write(path, data, style, opts)
  local valid, validation_err = M.validate_json_write(path, data, style, opts)
  if not valid then
    return nil, validation_err
  end

  local encoded = json.json_encode_pretty(data, style.indent or "  ")
  if style.newline then
    encoded = encoded .. "\n"
  end
  local atomic, stage_err = atomic_file.stage(style.path, encoded, style.revision, opts.base_dir)
  if not atomic then
    return nil, stage_err
  end
  return {
    atomic = atomic,
    content = encoded,
    opts = opts,
    style = style,
  }, nil
end

---@param plan I18nStatusResourceWritePlan
---@return boolean
---@return string|nil
function M.commit_json_write(plan)
  local safe_path, validation_err = validate_write_target(plan.atomic.target, plan.style, plan.opts)
  if not safe_path then
    return false, validation_err
  end

  local committed, commit_err = atomic_file.commit(plan.atomic)
  if not committed then
    return false, commit_err
  end
  plan.style.path = safe_path
  plan.style.revision = plan.atomic.committed

  local synced, sync_err = sync_loaded_buffers(safe_path, plan.content)
  if not synced then
    return false, sync_err
  end
  if plan.opts.mark_dirty then
    plan.opts.mark_dirty(safe_path)
  end
  return true, nil
end

---@param plan I18nStatusResourceWritePlan
---@return boolean
---@return string|nil
function M.rollback_json_write(plan)
  local called, rolled_back, rollback_err = pcall(atomic_file.rollback, plan.atomic)
  if not called then
    local protected, protect_err = atomic_file.protect(plan.atomic)
    local message = "atomic rollback raised: " .. tostring(rolled_back)
    if not protected then
      message = message .. "; failed to protect recovery files: " .. tostring(protect_err or "unknown")
    end
    return false, message
  end
  if not rolled_back then
    local protected, protect_err = atomic_file.protect(plan.atomic)
    if not protected then
      rollback_err = string.format(
        "%s; failed to protect recovery files: %s",
        rollback_err or "atomic rollback failed",
        protect_err or "unknown"
      )
    end
    return false, rollback_err
  end
  plan.style.revision = plan.atomic.expected

  local content = plan.atomic.expected.exists and plan.atomic.expected.content or nil
  local synced, sync_err = sync_loaded_buffers(plan.atomic.target, content)
  if not synced then
    return false, sync_err
  end
  if plan.opts.mark_dirty then
    plan.opts.mark_dirty(plan.atomic.target)
  end
  return true, nil
end

---@param plan I18nStatusResourceWritePlan
---@return boolean
---@return string|nil
function M.discard_json_write(plan)
  return atomic_file.discard(plan.atomic)
end

---@param plan I18nStatusResourceWritePlan
---@return boolean
---@return string|nil
function M.protect_json_write(plan)
  return atomic_file.protect(plan.atomic)
end

---@param path string
---@param data table
---@param style I18nStatusJsonStyle|nil
---@param opts I18nStatusResourceWriteOpts|nil
---@return boolean
---@return string|nil
function M.write_json_table(path, data, style, opts)
  local plan, prepare_err = M.prepare_json_write(path, data, style, opts)
  if not plan then
    notify_write_failure(path, prepare_err)
    return false, prepare_err
  end

  local committed, commit_err = M.commit_json_write(plan)
  if not committed and plan.atomic.committed_ok then
    local rolled_back, rollback_err = M.rollback_json_write(plan)
    if not rolled_back then
      commit_err = string.format("%s; rollback failed: %s", commit_err or "commit failed", rollback_err or "unknown")
    end
  end
  local discarded, discard_err = M.discard_json_write(plan)
  if not discarded then
    commit_err = commit_err and (commit_err .. "; cleanup failed: " .. discard_err)
      or ("cleanup failed: " .. tostring(discard_err or "unknown"))
  end
  if not committed or not discarded then
    notify_write_failure(path, commit_err)
  end
  return committed, commit_err
end

return M
