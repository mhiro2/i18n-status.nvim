---@class I18nStatusCoreIdentity
---@field name string
---@field version string

---@class I18nStatusCoreInitializeResult
---@field core I18nStatusCoreIdentity
---@field protocol_version integer

local module_source = debug.getinfo(1, "S").source
if module_source:sub(1, 1) == "@" then
  module_source = module_source:sub(2)
end
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(module_source)))
local manifest_path = vim.fs.joinpath(plugin_root, "core-contract.json")
local manifest_lines = vim.fn.readfile(manifest_path)
local manifest = vim.json.decode(table.concat(manifest_lines, "\n"))

if
  type(manifest) ~= "table"
  or manifest.schema_version ~= 1
  or type(manifest.client_name) ~= "string"
  or type(manifest.core_name) ~= "string"
  or type(manifest.version) ~= "string"
  or type(manifest.protocol_version) ~= "number"
  or manifest.protocol_version % 1 ~= 0
then
  error("i18n-status: invalid core-contract.json")
end

local M = {
  client_name = manifest.client_name,
  core_name = manifest.core_name,
  version = manifest.version,
  protocol_version = manifest.protocol_version,
  manifest_path = manifest_path,
}

---@return table
function M.initialize_params()
  return {
    client = {
      name = M.client_name,
      version = M.version,
    },
    protocol_version = M.protocol_version,
  }
end

---@param result any
---@return string|nil
function M.validate_initialize_result(result)
  if type(result) ~= "table" or type(result.core) ~= "table" then
    return "core initialize response is missing identity"
  end
  if result.core.name ~= M.core_name then
    return string.format("core name mismatch: expected %s, got %s", M.core_name, tostring(result.core.name))
  end
  if result.core.version ~= M.version then
    return string.format("core version mismatch: expected %s, got %s", M.version, tostring(result.core.version))
  end
  if result.protocol_version ~= M.protocol_version then
    return string.format(
      "core protocol mismatch: expected %d, got %s",
      M.protocol_version,
      tostring(result.protocol_version)
    )
  end
  return nil
end

return M
