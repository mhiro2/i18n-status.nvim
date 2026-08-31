---@class I18nStatusProjectIdentityService
local M = {}

local filetypes = require("i18n-status.filetypes")
local fs = require("i18n-status.fs")
local resources = require("i18n-status.resources")

---@class I18nStatusProjectIdentity
---@field cache I18nStatusCache
---@field cache_key string
---@field filetype string
---@field name string
---@field root string
---@field start_dir string

---@param bufnr integer
---@return boolean
function M.is_source_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    return false
  end
  return filetypes.is_source_filetype(vim.bo[bufnr].filetype)
end

---@param bufnr integer
---@param expected I18nStatusProjectIdentity
---@param operation string
---@return boolean
---@return string|nil
function M.validate_buffer(bufnr, expected, operation)
  if not M.is_source_buffer(bufnr) then
    return false, "source buffer is unavailable"
  end
  local name, name_err = fs.canonical_path(vim.api.nvim_buf_get_name(bufnr), nil)
  if not name then
    return false, "failed to resolve source buffer path: " .. tostring(name_err or "unknown")
  end
  local suffix = operation ~= "" and (" during " .. operation) or ""
  if name ~= expected.name then
    return false, "source buffer name changed" .. suffix
  end
  if vim.bo[bufnr].filetype ~= expected.filetype then
    return false, "source buffer filetype changed" .. suffix
  end
  return true, nil
end

---@param bufnr integer
---@return I18nStatusProjectIdentity|nil
---@return string|nil
function M.resolve(bufnr)
  if not M.is_source_buffer(bufnr) then
    return nil, "buffer is not a loaded, named source file"
  end

  local filetype = vim.bo[bufnr].filetype
  local name, name_err = fs.canonical_path(vim.api.nvim_buf_get_name(bufnr), nil)
  if not name then
    return nil, "failed to resolve source buffer path: " .. tostring(name_err or "unknown")
  end
  local start_dir = fs.dirname(name)
  local cache = resources.ensure_index(start_dir, { exact = true })
  if type(cache) ~= "table" or type(cache.key) ~= "string" or cache.key == "" then
    return nil, "failed to resolve resource cache identity"
  end

  local root = resources.project_root(start_dir, cache.roots)
  local canonical_root, root_err = fs.canonical_path(root, nil)
  if not canonical_root then
    return nil, "failed to resolve project root: " .. tostring(root_err or "unknown")
  end
  if not fs.path_under(name, canonical_root) then
    return nil, "source buffer is outside its resolved project root"
  end

  local stable, stability_err = M.validate_buffer(bufnr, {
    filetype = filetype,
    name = name,
  }, "project resolution")
  if not stable then
    return nil, stability_err
  end

  return {
    cache = cache,
    cache_key = cache.key,
    filetype = filetype,
    name = name,
    root = canonical_root,
    start_dir = start_dir,
  },
    nil
end

---@param identity I18nStatusProjectIdentity
---@param expected I18nStatusProjectIdentity
---@return boolean
function M.same_project(identity, expected)
  return identity.cache_key == expected.cache_key and identity.root == expected.root
end

---@param bufnr integer
---@param expected I18nStatusProjectIdentity
---@param operation string
---@return I18nStatusProjectIdentity|nil
---@return string|nil
function M.validate(bufnr, expected, operation)
  local stable, stability_err = M.validate_buffer(bufnr, expected, operation)
  if not stable then
    return nil, stability_err
  end
  local current, current_err = M.resolve(bufnr)
  if not current then
    return nil, current_err
  end
  stable, stability_err = M.validate_buffer(bufnr, expected, operation)
  if not stable then
    return nil, stability_err
  end
  local suffix = operation ~= "" and (" during " .. operation) or ""
  if not M.same_project(current, expected) then
    return nil, "source buffer project changed" .. suffix
  end
  return current, nil
end

return M
