---@class TestHelpers
local M = {}

local uv = vim.uv or vim.loop

---@return string
function M.tmpdir()
  local dir = vim.fn.tempname()
  uv.fs_mkdir(dir, 448)
  return dir
end

---@param path string
---@param content string
function M.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = uv.fs_open(path, "w", 420)
  assert(fd, "failed to open file")
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
end

---@param dir string
---@param fn fun()
function M.with_cwd(dir, fn)
  local cwd = vim.fn.getcwd()
  vim.fn.chdir(dir)
  local ok, err = pcall(fn)
  vim.fn.chdir(cwd)
  if not ok then
    error(err)
  end
end

---@param path string
---@return string
function M.read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  assert(fd, "failed to open file")
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

return M
