---@class I18nStatusResourceIo
local M = {
  reader = nil,
}

local util = require("i18n-status.util")

local uv = vim.uv
local FILE_PERMISSION_RW = 420 -- 0644 (rw-r--r--)

---@param path string
---@return string|nil
local function read_file(path)
  if M.reader then
    return M.reader(path)
  end
  return util.read_file(path)
end

---@param path string
---@return table|nil
---@return string|nil
function M.read_json(path)
  local content = read_file(path)
  if not content then
    return nil, "read failed"
  end
  local decoded, err = util.json_decode(content)
  if not decoded then
    return nil, err
  end
  return decoded, nil
end

---@param path string
---@return table|nil
---@return table
function M.read_json_table(path)
  if not util.file_exists(path) then
    return {}, { indent = "  ", newline = true }
  end
  local content = read_file(path)
  if not content then
    return {}, { indent = "  ", newline = true }
  end
  local decoded, err = util.json_decode(content)
  local style = {
    indent = util.detect_indent(content),
    newline = content:sub(-1) == "\n",
  }
  if not decoded then
    style.error = err
    return nil, style
  end
  if type(decoded) ~= "table" then
    return {}, style
  end
  return decoded, style
end

---@param path string
---@param stage string
---@param err string|nil
local function notify_write_failure(path, stage, err)
  vim.schedule(function()
    vim.notify(
      string.format("i18n-status: failed to write json file (%s, %s): %s", path, stage, err or "unknown"),
      vim.log.levels.WARN
    )
  end)
end

---@class I18nStatusResourceWriteOpts
---@field mark_dirty fun(path: string)|nil

---@param path string
---@param data table
---@param style table|nil
---@param opts I18nStatusResourceWriteOpts|nil
function M.write_json_table(path, data, style, opts)
  local indent = (style and style.indent) or "  "
  local newline = style and style.newline
  local encoded = util.json_encode_pretty(data, indent)
  if newline then
    encoded = encoded .. "\n"
  end

  local tmp_path = path .. ".tmp." .. uv.getpid()
  local fd, open_err = uv.fs_open(tmp_path, "w", FILE_PERMISSION_RW)
  if not fd then
    notify_write_failure(path, "fs_open", open_err)
    return
  end

  local function cleanup_tmp()
    pcall(uv.fs_unlink, tmp_path)
  end

  local function close_fd()
    return uv.fs_close(fd)
  end

  local written, write_err = uv.fs_write(fd, encoded, 0)
  if type(written) ~= "number" or written ~= #encoded then
    local _, close_err = close_fd()
    cleanup_tmp()
    notify_write_failure(path, "fs_write", write_err or close_err or "short write")
    return
  end

  local fsync_ok, fsync_err = uv.fs_fsync(fd)
  if not fsync_ok then
    local _, close_err = close_fd()
    cleanup_tmp()
    notify_write_failure(path, "fs_fsync", fsync_err or close_err)
    return
  end

  local close_ok, close_err = close_fd()
  if not close_ok then
    cleanup_tmp()
    notify_write_failure(path, "fs_close", close_err)
    return
  end

  local ok, err = uv.fs_rename(tmp_path, path)
  if ok then
    if opts and opts.mark_dirty then
      opts.mark_dirty(path)
    end
    return
  end

  local err_msg = tostring(err or "")
  local is_exists = err_msg:lower():find("eexist") or err_msg:lower():find("exists")
  if is_exists then
    pcall(uv.fs_unlink, path)
    ok, err = uv.fs_rename(tmp_path, path)
    if ok then
      if opts and opts.mark_dirty then
        opts.mark_dirty(path)
      end
      return
    end
  end

  cleanup_tmp()
  notify_write_failure(path, "fs_rename", err)
end

---@param reader fun(path: string): string|nil
function M.set_reader(reader)
  M.reader = reader
end

return M
