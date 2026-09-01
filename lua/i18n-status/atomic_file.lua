---@class I18nStatusAtomicFile
local M = {}

local bit = require("bit")
local fs = require("i18n-status.fs")

local uv = vim.uv
local DEFAULT_MODE = 420 -- 0644
local PRIVATE_DIRECTORY_MODE = 448 -- 0700
local MAX_TEMP_ATTEMPTS = 32
local ENOENT = 2
local EEXIST = 17

---@class I18nStatusFileRevision
---@field exists boolean
---@field content string|nil
---@field dev integer|nil
---@field ino integer|nil
---@field mode integer|nil
---@field size integer|nil
---@field mtime_sec integer|nil
---@field mtime_nsec integer|nil
---@field parent_dev integer|nil
---@field parent_ino integer|nil

---@class I18nStatusAtomicFilePlan
---@field target string
---@field base_path string
---@field base_dev integer
---@field base_ino integer
---@field parent_path string
---@field parent_components string[]
---@field parent_fd integer
---@field parent_dev integer
---@field parent_ino integer
---@field target_name string
---@field stage string|nil
---@field stage_name string|nil
---@field artifacts table<string, "discard"|"protect">
---@field artifact_revisions table<string, I18nStatusFileRevision>
---@field expected I18nStatusFileRevision
---@field intended I18nStatusFileRevision
---@field committed I18nStatusFileRevision|nil
---@field committed_ok boolean
---@field closed boolean

local ffi = nil
local platform = nil
local open_flags = nil
local remove_directory_flag = nil
do
  local ffi_ok, ffi_runtime = pcall(require, "ffi")
  local jit_ok, jit_runtime = pcall(require, "jit")
  if ffi_ok and jit_ok and (jit_runtime.os == "OSX" or jit_runtime.os == "Linux") then
    local base_cdef_ok = pcall(
      ffi_runtime.cdef,
      [[
      int openat(int dirfd, const char *pathname, int flags, ...);
      int unlinkat(int dirfd, const char *pathname, int flags);
    ]]
    )
    local rename_cdef_ok = false
    local candidate_platform = nil
    local candidate_flags = nil
    if jit_runtime.os == "OSX" then
      rename_cdef_ok = pcall(
        ffi_runtime.cdef,
        [[
        int renameatx_np(int fromfd, const char *from, int tofd,
                         const char *to, unsigned int flags);
        int mkdirat(int dirfd, const char *pathname, unsigned short mode);
      ]]
      )
      candidate_platform = "macOS"
      remove_directory_flag = 0x0080
      candidate_flags = {
        write_create_exclusive = bit.bor(0x0001, 0x0200, 0x0800, 0x0100, 0x1000000),
        readonly_nofollow = bit.bor(0x0000, 0x0004, 0x0100, 0x1000000),
        directory_nofollow = bit.bor(0x0000, 0x0100, 0x00100000, 0x1000000),
      }
    else
      rename_cdef_ok = pcall(
        ffi_runtime.cdef,
        [[
        int renameat2(int olddirfd, const char *oldpath, int newdirfd,
                      const char *newpath, unsigned int flags);
        int mkdirat(int dirfd, const char *pathname, unsigned int mode);
      ]]
      )
      candidate_platform = "Linux"
      remove_directory_flag = 0x0200
      candidate_flags = {
        write_create_exclusive = bit.bor(0x0001, 0x0040, 0x0080, 0x20000, 0x80000),
        readonly_nofollow = bit.bor(0x0000, 0x0800, 0x20000, 0x80000),
        directory_nofollow = bit.bor(0x0000, 0x10000, 0x20000, 0x80000),
      }
    end
    local symbols_ok = base_cdef_ok
      and rename_cdef_ok
      and pcall(function()
        local _ = ffi_runtime.C.openat
        _ = ffi_runtime.C.unlinkat
        _ = ffi_runtime.C.mkdirat
        _ = candidate_platform == "macOS" and ffi_runtime.C.renameatx_np or ffi_runtime.C.renameat2
      end)
    if symbols_ok then
      ffi = ffi_runtime
      platform = candidate_platform
      open_flags = candidate_flags
    end
  end
end

local function capability_error()
  return "atomic resource mutations require LuaJIT and openat/mkdirat/unlinkat plus renameat2 (Linux) or renameatx_np (macOS)"
end

---@return boolean
---@return string|nil
function M.supported()
  if ffi and platform then
    return true, nil
  end
  return false, capability_error()
end

---@param stat table
---@return integer
local function permission_mode(stat)
  local mode = tonumber(stat.mode) or DEFAULT_MODE
  return bit.band(mode, 511)
end

---@param left table
---@param right table
---@return boolean
local function stats_equal(left, right)
  local left_mtime = left.mtime or {}
  local right_mtime = right.mtime or {}
  return left.type == right.type
    and left.dev == right.dev
    and left.ino == right.ino
    and left.mode == right.mode
    and left.size == right.size
    and left_mtime.sec == right_mtime.sec
    and left_mtime.nsec == right_mtime.nsec
end

---@param left table|nil
---@param right table|nil
---@return boolean
local function same_file_identity(left, right)
  return left ~= nil
    and right ~= nil
    and left.type == "file"
    and right.type == "file"
    and left.dev == right.dev
    and left.ino == right.ino
end

---@param stat table
---@param content string
---@param parent_stat table|nil
---@return I18nStatusFileRevision
local function file_revision(stat, content, parent_stat)
  local mtime = stat.mtime or {}
  return {
    exists = true,
    content = content,
    dev = stat.dev,
    ino = stat.ino,
    mode = permission_mode(stat),
    size = stat.size,
    mtime_sec = mtime.sec,
    mtime_nsec = mtime.nsec,
    parent_dev = parent_stat and parent_stat.dev or nil,
    parent_ino = parent_stat and parent_stat.ino or nil,
  }
end

---@param parent_fd integer
---@param name string
---@param flags integer
---@param mode integer
---@return integer|nil
---@return string|nil
---@return integer|nil
local function open_at(parent_fd, name, flags, mode)
  if not ffi then
    return nil, capability_error(), nil
  end
  local ok, result = pcall(function()
    return ffi.C.openat(parent_fd, name, flags, ffi.new("unsigned int", mode))
  end)
  if not ok then
    return nil, "openat is unavailable", nil
  end
  if result < 0 then
    local errno = ffi.errno()
    return nil, "openat failed with errno " .. tostring(errno), errno
  end
  return tonumber(result), nil, nil
end

---@param parent_fd integer
---@param source string
---@param destination string
---@return boolean
---@return string|nil
---@return integer|nil
local function exchange_at(parent_fd, source, destination)
  if not ffi or not platform then
    return false, capability_error(), nil
  end
  local ok, result = pcall(function()
    if platform == "macOS" then
      return ffi.C.renameatx_np(parent_fd, source, parent_fd, destination, 0x00000002)
    end
    return ffi.C.renameat2(parent_fd, source, parent_fd, destination, 0x00000002)
  end)
  if not ok then
    return false, "atomic file exchange is unavailable", nil
  end
  if result ~= 0 then
    local errno = ffi.errno()
    return false, "atomic file exchange failed with errno " .. tostring(errno), errno
  end
  return true, nil, nil
end

---@param parent_fd integer
---@param source string
---@param destination string
---@return boolean
---@return string|nil
---@return integer|nil
local function move_no_replace_between(source_fd, source, destination_fd, destination)
  if not ffi or not platform then
    return false, capability_error(), nil
  end
  local ok, result = pcall(function()
    if platform == "macOS" then
      return ffi.C.renameatx_np(source_fd, source, destination_fd, destination, 0x00000004)
    end
    return ffi.C.renameat2(source_fd, source, destination_fd, destination, 0x00000001)
  end)
  if not ok then
    return false, "atomic no-replace move is unavailable", nil
  end
  if result ~= 0 then
    local errno = ffi.errno()
    return false, "atomic no-replace move failed with errno " .. tostring(errno), errno
  end
  return true, nil, nil
end

---@param parent_fd integer
---@param source string
---@param destination string
---@return boolean
---@return string|nil
---@return integer|nil
local function move_no_replace_at(parent_fd, source, destination)
  return move_no_replace_between(parent_fd, source, parent_fd, destination)
end

---@param parent_fd integer
---@param name string
---@param mode integer
---@return boolean
---@return string|nil
---@return integer|nil
local function mkdir_at(parent_fd, name, mode)
  if not ffi or not platform then
    return false, capability_error(), nil
  end
  local ok, result = pcall(function()
    if platform == "macOS" then
      return ffi.C.mkdirat(parent_fd, name, ffi.new("unsigned short", mode))
    end
    return ffi.C.mkdirat(parent_fd, name, ffi.new("unsigned int", mode))
  end)
  if not ok then
    return false, "mkdirat is unavailable", nil
  end
  if result ~= 0 then
    local errno = ffi.errno()
    return false, "mkdirat failed with errno " .. tostring(errno), errno
  end
  return true, nil, nil
end

---@param parent_fd integer
---@param name string
---@return boolean
---@return string|nil
---@return integer|nil
local function unlink_at(parent_fd, name)
  if not ffi then
    return false, capability_error(), nil
  end
  local ok, result = pcall(function()
    return ffi.C.unlinkat(parent_fd, name, 0)
  end)
  if not ok then
    return false, "unlinkat is unavailable", nil
  end
  if result ~= 0 then
    local errno = ffi.errno()
    return false, "unlinkat failed with errno " .. tostring(errno), errno
  end
  return true, nil, nil
end

---@param parent_fd integer
---@param name string
---@return boolean
---@return string|nil
---@return integer|nil
local function remove_directory_at(parent_fd, name)
  if not ffi or not remove_directory_flag then
    return false, capability_error(), nil
  end
  local ok, result = pcall(function()
    return ffi.C.unlinkat(parent_fd, name, remove_directory_flag)
  end)
  if not ok then
    return false, "directory unlinkat is unavailable", nil
  end
  if result ~= 0 then
    local errno = ffi.errno()
    return false, "directory unlinkat failed with errno " .. tostring(errno), errno
  end
  return true, nil, nil
end

---@param fd integer
---@param content string
---@return boolean
---@return string|nil
local function write_all(fd, content)
  local offset = 0
  while offset < #content do
    local written, write_err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if type(written) ~= "number" or written <= 0 then
      return false, write_err or "short write"
    end
    offset = offset + written
  end
  return true, nil
end

---@param fd integer
---@param parent_stat table|nil
---@return I18nStatusFileRevision|nil
---@return string|nil
local function read_open_file(fd, parent_stat)
  local before, stat_err = uv.fs_fstat(fd)
  if not before then
    return nil, "fs_fstat: " .. tostring(stat_err or "unknown")
  end
  if before.type ~= "file" then
    return nil, "resource path is not a regular file"
  end
  local chunks = {}
  local offset = 0
  while offset < before.size do
    local read, read_err = uv.fs_read(fd, before.size - offset, offset)
    if read == nil then
      return nil, "fs_read: " .. tostring(read_err or "unknown")
    end
    if #read == 0 then
      return nil, "fs_read: short read"
    end
    chunks[#chunks + 1] = read
    offset = offset + #read
  end
  local content = table.concat(chunks)
  local after, after_err = uv.fs_fstat(fd)
  if not after then
    return nil, "fs_fstat: " .. tostring(after_err or "unknown")
  end
  if not stats_equal(before, after) then
    return nil, "resource changed while it was being read"
  end
  return file_revision(after, content, parent_stat), nil
end

---@param parent_fd integer
---@param parent_stat table
---@param name string
---@return I18nStatusFileRevision|nil
---@return string|nil
local function read_revision_at(parent_fd, parent_stat, name)
  local fd, open_err, errno = open_at(parent_fd, name, open_flags.readonly_nofollow, 0)
  if not fd then
    if errno == ENOENT then
      return {
        exists = false,
        content = nil,
        parent_dev = parent_stat.dev,
        parent_ino = parent_stat.ino,
      },
        nil
    end
    return nil, "failed to open resource file: " .. tostring(open_err or "unknown")
  end
  local revision, read_err = read_open_file(fd, parent_stat)
  local closed, close_err = uv.fs_close(fd)
  if not revision then
    return nil, read_err
  end
  if not closed then
    return nil, "fs_close: " .. tostring(close_err or "unknown")
  end
  return revision, nil
end

---@param path string
---@return integer|nil
---@return table|nil
---@return string|nil
local function open_parent(path)
  local fd, open_err = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, nil, "failed to open resource directory: " .. tostring(open_err or "unknown")
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat or stat.type ~= "directory" then
    uv.fs_close(fd)
    return nil, nil, stat_err or "resource parent is not a directory"
  end
  return fd, stat, nil
end

---@param target string
---@param base string
---@return boolean
local function is_within_base(target, base)
  local normalized_target = target:gsub("\\", "/")
  local normalized_base = base:gsub("\\", "/"):gsub("/+$", "")
  return normalized_target == normalized_base
    or normalized_target:sub(1, #normalized_base + 1) == normalized_base .. "/"
end

---@param parent_path string
---@param base_path string
---@return string[]|nil
local function relative_components(parent_path, base_path)
  local normalized_parent = parent_path:gsub("\\", "/"):gsub("/+$", "")
  local normalized_base = base_path:gsub("\\", "/"):gsub("/+$", "")
  if not is_within_base(normalized_parent, normalized_base) then
    return nil
  end
  if normalized_parent == normalized_base then
    return {}
  end
  local relative = normalized_parent:sub(#normalized_base + 2)
  local components = {}
  for component in relative:gmatch("[^/]+") do
    if component == "." or component == ".." or component == "" then
      return nil
    end
    components[#components + 1] = component
  end
  return components
end

---@param base_path string
---@param components string[]
---@return integer|nil
---@return table|nil
---@return table|nil
---@return string|nil
local function open_parent_beneath(base_path, components)
  local current_fd, current_stat, base_err = open_parent(base_path)
  if not current_fd then
    return nil, nil, nil, base_err
  end
  local base_stat = current_stat
  for _, component in ipairs(components) do
    local next_fd, open_err = open_at(current_fd, component, open_flags.directory_nofollow, 0)
    if not next_fd then
      uv.fs_close(current_fd)
      return nil, nil, nil, "failed to open resource path component: " .. tostring(open_err or "unknown")
    end
    local next_stat, stat_err = uv.fs_fstat(next_fd)
    uv.fs_close(current_fd)
    if not next_stat or next_stat.type ~= "directory" then
      uv.fs_close(next_fd)
      return nil, nil, nil, stat_err or "resource path component is not a directory"
    end
    current_fd = next_fd
    current_stat = next_stat
  end
  return current_fd, current_stat, base_stat, nil
end

---@param path string
---@return I18nStatusFileRevision|nil
---@return string|nil
local function read_revision_legacy(path)
  local before, stat_err = uv.fs_lstat(path)
  if not before then
    if type(stat_err) == "string" and stat_err:find("ENOENT", 1, true) then
      return { exists = false, content = nil }, nil
    end
    return nil, "failed to inspect resource file: " .. tostring(stat_err or "unknown")
  end
  if before.type ~= "file" then
    return nil, "resource path is not a regular file"
  end
  local content = fs.read_file(path)
  if content == nil then
    return nil, "failed to read existing file"
  end
  local after, after_err = uv.fs_lstat(path)
  if not after or not stats_equal(before, after) then
    return nil, "resource changed while it was being read: " .. tostring(after_err or "unknown")
  end
  return file_revision(after, content, nil), nil
end

---@param path string
---@return I18nStatusFileRevision|nil
---@return string|nil
function M.read_revision(path)
  if not ffi then
    return read_revision_legacy(path)
  end
  local canonical, canonical_err = fs.canonical_path(path)
  if not canonical then
    return nil, canonical_err
  end
  local parent_path = fs.dirname(canonical)
  local parent_fd, parent_stat, parent_err = open_parent(parent_path)
  if not parent_fd then
    return nil, parent_err
  end
  local revision, revision_err = read_revision_at(parent_fd, parent_stat, vim.fs.basename(canonical))
  local closed, close_err = uv.fs_close(parent_fd)
  if not closed and revision then
    return nil, "failed to close resource directory: " .. tostring(close_err or "unknown")
  end
  return revision, revision_err
end

---@param expected I18nStatusFileRevision
---@param actual I18nStatusFileRevision
---@return boolean
function M.revisions_equal(expected, actual)
  if expected.exists ~= actual.exists or expected.content ~= actual.content then
    return false
  end
  if expected.parent_dev ~= nil and expected.parent_dev ~= actual.parent_dev then
    return false
  end
  if expected.parent_ino ~= nil and expected.parent_ino ~= actual.parent_ino then
    return false
  end
  if not expected.exists then
    return true
  end
  return expected.dev == actual.dev
    and expected.ino == actual.ino
    and expected.mode == actual.mode
    and expected.size == actual.size
    and expected.mtime_sec == actual.mtime_sec
    and expected.mtime_nsec == actual.mtime_nsec
end

---@param label string
---@param attempt integer
---@return string
local function temp_name(label, attempt)
  return string.format(".i18n-status-%s-%s-%s-%d", label, uv.getpid(), uv.hrtime(), attempt)
end

---@param target string
---@param base_dir string
---@param expected I18nStatusFileRevision
---@return table|nil
---@return string|nil
local function pin_parent(target, base_dir, expected)
  local supported, support_err = M.supported()
  if not supported then
    return nil, support_err
  end
  local parent_path = fs.dirname(target):gsub("\\", "/"):gsub("/+$", "")
  local target_name = vim.fs.basename(target)
  if not target_name or target_name == "" or target_name == "." or target_name == ".." then
    return nil, "invalid resource filename"
  end
  local real_base = uv.fs_realpath(base_dir)
  if not real_base then
    return nil, "project root does not exist"
  end
  real_base = real_base:gsub("\\", "/"):gsub("/+$", "")
  local components = relative_components(parent_path, real_base)
  if not components then
    return nil, "resource parent changed or escaped the project root"
  end
  local parent_fd, parent_stat, base_stat, parent_err = open_parent_beneath(real_base, components)
  if not parent_fd then
    return nil, parent_err
  end
  if expected.parent_dev ~= nil and expected.parent_dev ~= parent_stat.dev then
    uv.fs_close(parent_fd)
    return nil, "resource parent changed since it was read"
  end
  if expected.parent_ino ~= nil and expected.parent_ino ~= parent_stat.ino then
    uv.fs_close(parent_fd)
    return nil, "resource parent changed since it was read"
  end
  return {
    base_path = real_base,
    base_dev = base_stat.dev,
    base_ino = base_stat.ino,
    parent_path = parent_path,
    parent_components = components,
    parent_fd = parent_fd,
    parent_dev = parent_stat.dev,
    parent_ino = parent_stat.ino,
    parent_stat = parent_stat,
    target_name = target_name,
  },
    nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
local function verify_parent(plan)
  local fd, stat, base_stat, open_err = open_parent_beneath(plan.base_path, plan.parent_components)
  if not fd then
    return false, open_err
  end
  local closed, close_err = uv.fs_close(fd)
  if not closed then
    return false, "failed to close verified resource directory: " .. tostring(close_err or "unknown")
  end
  if
    base_stat.dev ~= plan.base_dev
    or base_stat.ino ~= plan.base_ino
    or stat.dev ~= plan.parent_dev
    or stat.ino ~= plan.parent_ino
  then
    return false, "resource parent changed since the write was prepared"
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
local function sync_parent(plan)
  local synced, sync_err = uv.fs_fsync(plan.parent_fd)
  if not synced then
    return false, "failed to sync resource directory: " .. tostring(sync_err or "unknown")
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@param name string|nil
local function set_stage(plan, name)
  plan.stage_name = name
  plan.stage = name and fs.path_join(plan.parent_path, name) or nil
end

---@param plan I18nStatusAtomicFilePlan
---@param name string
---@return string
local function artifact_path(plan, name)
  return fs.path_join(plan.parent_path, name)
end

---@param plan I18nStatusAtomicFilePlan
---@return string[]
local function protected_paths(plan)
  local paths = {}
  for name, kind in pairs(plan.artifacts) do
    if kind == "protect" then
      paths[#paths + 1] = artifact_path(plan, name)
    end
  end
  table.sort(paths)
  return paths
end

---@param plan I18nStatusAtomicFilePlan
---@param name string
---@param kind "discard"|"protect"
---@param revision I18nStatusFileRevision|nil
local function track_artifact(plan, name, kind, revision)
  plan.artifacts[name] = kind
  plan.artifact_revisions[name] = revision
end

---@param plan I18nStatusAtomicFilePlan
---@param name string
local function forget_artifact(plan, name)
  plan.artifacts[name] = nil
  plan.artifact_revisions[name] = nil
  if plan.stage_name == name then
    set_stage(plan, nil)
  end
end

---@param plan I18nStatusAtomicFilePlan
---@param base_message string
---@return string
local function recovery_message(plan, base_message)
  local paths = protected_paths(plan)
  if #paths == 0 then
    return base_message
  end
  return base_message .. "; recovery files: " .. table.concat(paths, ", ")
end

---@param parent_fd integer
---@param source string
---@param label string
---@return string|nil
---@return string|nil
---@return integer|nil
local function move_to_unique_at(parent_fd, source, label)
  local last_err = nil
  local last_errno = nil
  for attempt = 1, MAX_TEMP_ATTEMPTS do
    local candidate = temp_name(label, attempt)
    local moved, move_err, errno = move_no_replace_at(parent_fd, source, candidate)
    if moved then
      return candidate, nil
    end
    last_err = move_err
    last_errno = errno
    if errno ~= EEXIST then
      break
    end
  end
  return nil, last_err or "failed to reserve a recovery path", last_errno
end

---@param plan I18nStatusAtomicFilePlan
---@param source string
---@param label string
---@return string|nil
---@return string|nil
---@return integer|nil
local function move_to_unique(plan, source, label)
  return move_to_unique_at(plan.parent_fd, source, label)
end

---@param parent_fd integer
---@return integer|nil
---@return string|nil
---@return string|nil
local function create_private_cleanup(parent_fd)
  local last_err = nil
  for attempt = 1, MAX_TEMP_ATTEMPTS do
    local name = temp_name("cleanup", attempt)
    local created, create_err, errno = mkdir_at(parent_fd, name, PRIVATE_DIRECTORY_MODE)
    if created then
      local fd, open_err = open_at(parent_fd, name, open_flags.directory_nofollow, 0)
      if not fd then
        local _, remove_err = remove_directory_at(parent_fd, name)
        return nil,
          nil,
          "failed to open private cleanup directory: "
            .. tostring(open_err or "unknown")
            .. (remove_err and "; " .. remove_err or "")
      end
      local stat, stat_err = uv.fs_fstat(fd)
      local chmod_ok, chmod_err = uv.fs_fchmod(fd, PRIVATE_DIRECTORY_MODE)
      if not stat or stat.type ~= "directory" or not chmod_ok then
        local _, close_err = uv.fs_close(fd)
        local _, remove_err = remove_directory_at(parent_fd, name)
        return nil,
          nil,
          tostring(stat_err or chmod_err or "private cleanup path is not a directory")
            .. (close_err and "; fs_close: " .. close_err or "")
            .. (remove_err and "; " .. remove_err or "")
      end
      return fd, name, nil
    end
    last_err = create_err
    if errno ~= EEXIST then
      break
    end
  end
  return nil, nil, last_err or "failed to create private cleanup directory"
end

---@param parent_fd integer
---@param cleanup_fd integer
---@param cleanup_name string
---@param remove boolean
---@return boolean
---@return string|nil
local function close_private_cleanup(parent_fd, cleanup_fd, cleanup_name, remove)
  local errors = {}
  local closed, close_err = uv.fs_close(cleanup_fd)
  if not closed then
    errors[#errors + 1] = "fs_close: " .. tostring(close_err or "unknown")
  end
  if remove then
    local removed, remove_err, errno = remove_directory_at(parent_fd, cleanup_name)
    if not removed and errno ~= ENOENT then
      errors[#errors + 1] = remove_err or "failed to remove private cleanup directory"
    end
  end
  if #errors > 0 then
    return false, table.concat(errors, "; ")
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@param source string
---@param destination string
---@param expected I18nStatusFileRevision
---@return boolean
---@return string|nil
---@return I18nStatusFileRevision|nil
---@return integer|nil
local function move_verified_no_replace(plan, source, destination, expected)
  local moved, move_err, errno = move_no_replace_at(plan.parent_fd, source, destination)
  if not moved then
    return false, move_err, nil, errno
  end
  if plan.artifacts[source] then
    forget_artifact(plan, source)
  end

  local actual, read_err = read_revision_at(plan.parent_fd, {
    dev = plan.parent_dev,
    ino = plan.parent_ino,
  }, destination)
  if actual and M.revisions_equal(expected, actual) then
    return true, nil, actual, nil
  end

  if destination ~= plan.target_name then
    track_artifact(plan, destination, "protect", actual)
  end
  local reason = read_err or "moved file identity changed before installation could be verified"
  if destination == plan.target_name then
    reason = reason .. "; canonical target was left in place"
  end
  return false, reason, actual, nil
end

---@param plan I18nStatusAtomicFilePlan
---@param name string
---@return boolean
---@return string|nil
local function remove_artifact(plan, name)
  local expected = plan.artifact_revisions[name]
  if not expected then
    plan.artifacts[name] = "protect"
    return false, recovery_message(plan, "artifact identity is unknown")
  end

  local cleanup_fd, cleanup_name, cleanup_err = create_private_cleanup(plan.parent_fd)
  if not cleanup_fd or not cleanup_name then
    plan.artifacts[name] = "protect"
    return false, recovery_message(plan, cleanup_err or "failed to create private cleanup directory")
  end
  local entry_name = "artifact"
  local recovery_name = cleanup_name .. "/" .. entry_name
  local moved, move_err, errno = move_no_replace_between(plan.parent_fd, name, cleanup_fd, entry_name)
  if not moved then
    local _, close_err = close_private_cleanup(plan.parent_fd, cleanup_fd, cleanup_name, true)
    if errno == ENOENT then
      forget_artifact(plan, name)
      if close_err then
        return false, close_err
      end
      return true, nil
    end
    plan.artifacts[name] = "protect"
    local reason = move_err or "failed to isolate artifact for cleanup"
    if close_err then
      reason = reason .. "; " .. close_err
    end
    return false, recovery_message(plan, reason)
  end
  forget_artifact(plan, name)
  track_artifact(plan, recovery_name, "protect", nil)

  local actual_fd, open_err = open_at(cleanup_fd, entry_name, open_flags.readonly_nofollow, 0)
  if not actual_fd then
    local _, close_err = close_private_cleanup(plan.parent_fd, cleanup_fd, cleanup_name, false)
    local reason = "failed to open artifact for cleanup: " .. tostring(open_err or "unknown")
    if close_err then
      reason = reason .. "; " .. close_err
    end
    return false, recovery_message(plan, reason)
  end
  local actual, read_err = read_open_file(actual_fd, {
    dev = plan.parent_dev,
    ino = plan.parent_ino,
  })
  if not actual or not M.revisions_equal(expected, actual) then
    local _, close_err = uv.fs_close(actual_fd)
    local _, cleanup_close_err = close_private_cleanup(plan.parent_fd, cleanup_fd, cleanup_name, false)
    plan.artifact_revisions[recovery_name] = actual
    local reason = read_err or "artifact changed before cleanup"
    if close_err then
      reason = reason .. "; fs_close: " .. tostring(close_err)
    end
    if cleanup_close_err then
      reason = reason .. "; " .. cleanup_close_err
    end
    return false, recovery_message(plan, reason)
  end

  track_artifact(plan, recovery_name, "discard", actual)
  local removed, remove_err, remove_errno = unlink_at(cleanup_fd, entry_name)
  local closed, close_err = uv.fs_close(actual_fd)
  if removed or remove_errno == ENOENT then
    forget_artifact(plan, recovery_name)
    local cleanup_closed, cleanup_close_err = close_private_cleanup(plan.parent_fd, cleanup_fd, cleanup_name, true)
    if closed and cleanup_closed then
      return true, nil
    end
    return false, "failed to close removed artifact: " .. tostring(close_err or cleanup_close_err or "unknown")
  end

  track_artifact(plan, recovery_name, "protect", actual)
  local _, cleanup_close_err = close_private_cleanup(plan.parent_fd, cleanup_fd, cleanup_name, false)
  local reason = remove_err or "failed to remove isolated artifact"
  if not closed then
    reason = reason .. "; fs_close: " .. tostring(close_err or "unknown")
  end
  if cleanup_close_err then
    reason = reason .. "; " .. cleanup_close_err
  end
  return false, recovery_message(plan, reason)
end

---@param plan I18nStatusAtomicFilePlan
---@param prior_revision I18nStatusFileRevision
---@param new_revision I18nStatusFileRevision
---@param new_revision_discardable boolean
---@param displaced I18nStatusFileRevision|nil
---@param installed I18nStatusFileRevision|nil
---@param reason string
---@return boolean
---@return string
local function recover_failed_exchange(
  plan,
  prior_revision,
  new_revision,
  new_revision_discardable,
  displaced,
  installed,
  reason
)
  local stage_name = assert(plan.stage_name)
  track_artifact(plan, stage_name, "protect", displaced)

  if not installed or not M.revisions_equal(new_revision, installed) then
    reason = reason .. "; canonical target was left unchanged because it no longer matched the planned revision"
  elseif not displaced or M.revisions_equal(prior_revision, displaced) then
    reason = reason .. "; exchanged revisions could not be classified safely"
  else
    local swapped_back, swap_err = exchange_at(plan.parent_fd, stage_name, plan.target_name)
    if not swapped_back then
      reason = reason .. "; failed to restore the concurrent target: " .. tostring(swap_err or "unknown")
    else
      local restored, restored_err = read_revision_at(plan.parent_fd, {
        dev = plan.parent_dev,
        ino = plan.parent_ino,
      }, plan.target_name)
      local preserved, preserved_err = read_revision_at(plan.parent_fd, {
        dev = plan.parent_dev,
        ino = plan.parent_ino,
      }, stage_name)
      if not restored or not M.revisions_equal(displaced, restored) then
        reason = reason
          .. "; restored target changed during recovery: "
          .. tostring(restored_err or "revision mismatch")
      end
      if not preserved or not M.revisions_equal(installed, preserved) then
        reason = reason
          .. "; recovery artifact changed during recovery: "
          .. tostring(preserved_err or "revision mismatch")
        track_artifact(plan, stage_name, "protect", preserved)
      elseif new_revision_discardable then
        track_artifact(plan, stage_name, "discard", preserved)
        local removed, remove_err = remove_artifact(plan, stage_name)
        if not removed then
          reason = reason .. "; failed to remove plugin staging data: " .. tostring(remove_err)
        end
      else
        track_artifact(plan, stage_name, "protect", preserved)
      end
    end
  end

  local _, sync_err = sync_parent(plan)
  if sync_err then
    reason = reason .. "; " .. sync_err
  end
  return false, recovery_message(plan, reason)
end

---@param parent_fd integer
---@param parent_path string
---@param stage_name string|nil
---@param stage_stat table|nil
---@param primary_error string
---@return string
local function cleanup_uncommitted(parent_fd, parent_path, stage_name, stage_stat, primary_error)
  local errors = {}
  if stage_name then
    local cleanup_fd, cleanup_name, cleanup_err = create_private_cleanup(parent_fd)
    if not cleanup_fd or not cleanup_name then
      errors[#errors + 1] = tostring(cleanup_err or "failed to create private cleanup directory")
        .. "; recovery file: "
        .. fs.path_join(parent_path, stage_name)
    else
      local entry_name = "artifact"
      local recovery_path = fs.path_join(parent_path, cleanup_name .. "/" .. entry_name)
      local moved, move_err, errno = move_no_replace_between(parent_fd, stage_name, cleanup_fd, entry_name)
      if not moved then
        local _, close_err = close_private_cleanup(parent_fd, cleanup_fd, cleanup_name, true)
        if errno ~= ENOENT then
          errors[#errors + 1] = tostring(move_err or "failed to isolate staging file")
            .. "; recovery file: "
            .. fs.path_join(parent_path, stage_name)
        end
        if close_err then
          errors[#errors + 1] = close_err
        end
      else
        local synced, sync_err = uv.fs_fsync(parent_fd)
        if not synced then
          errors[#errors + 1] = "failed to sync resource directory: " .. tostring(sync_err or "unknown")
        end

        local actual_fd, open_err = open_at(cleanup_fd, entry_name, open_flags.readonly_nofollow, 0)
        local actual_stat = nil
        if actual_fd then
          local stat_err
          actual_stat, stat_err = uv.fs_fstat(actual_fd)
          if not actual_stat then
            open_err = "fs_fstat: " .. tostring(stat_err or "unknown")
          end
        end

        local removed = false
        if same_file_identity(stage_stat, actual_stat) then
          local remove_err = nil
          local remove_errno = nil
          removed, remove_err, remove_errno = unlink_at(cleanup_fd, entry_name)
          if not removed and remove_errno == ENOENT then
            removed = true
          elseif not removed then
            errors[#errors + 1] = tostring(remove_err or "failed to remove isolated staging file")
              .. "; recovery file: "
              .. recovery_path
          end
        else
          errors[#errors + 1] = (open_err or "staging file identity changed during cleanup")
            .. "; recovery file: "
            .. recovery_path
        end
        if actual_fd then
          local closed, close_err = uv.fs_close(actual_fd)
          if not closed then
            errors[#errors + 1] = "fs_close: " .. tostring(close_err or "unknown")
          end
        end
        local _, cleanup_close_err = close_private_cleanup(parent_fd, cleanup_fd, cleanup_name, removed)
        if cleanup_close_err then
          errors[#errors + 1] = cleanup_close_err
        end

        local cleanup_synced, cleanup_sync_err = uv.fs_fsync(parent_fd)
        if not cleanup_synced then
          errors[#errors + 1] = "failed to sync resource directory: " .. tostring(cleanup_sync_err or "unknown")
        end
      end
    end
  end
  local closed, close_err = uv.fs_close(parent_fd)
  if not closed then
    errors[#errors + 1] = "failed to close resource directory: " .. tostring(close_err or "unknown")
  end
  if #errors == 0 then
    return primary_error
  end
  return primary_error .. "; cleanup failed: " .. table.concat(errors, "; ")
end

---@param target string
---@param content string
---@param expected I18nStatusFileRevision
---@param base_dir string
---@return I18nStatusAtomicFilePlan|nil
---@return string|nil
function M.stage(target, content, expected, base_dir)
  local pinned, pin_err = pin_parent(target, base_dir, expected)
  if not pinned then
    return nil, pin_err
  end
  local current, current_err = read_revision_at(pinned.parent_fd, pinned.parent_stat, pinned.target_name)
  if not current or not M.revisions_equal(expected, current) then
    return nil,
      cleanup_uncommitted(
        pinned.parent_fd,
        pinned.parent_path,
        nil,
        nil,
        current_err or "resource changed on disk since it was read"
      )
  end

  local mode = expected.exists and expected.mode or DEFAULT_MODE
  local stage_name = nil
  local fd = nil
  local open_err = nil
  for attempt = 1, MAX_TEMP_ATTEMPTS do
    local candidate = temp_name("stage", attempt)
    local errno
    fd, open_err, errno = open_at(pinned.parent_fd, candidate, open_flags.write_create_exclusive, mode or DEFAULT_MODE)
    if fd then
      stage_name = candidate
      break
    end
    if errno ~= EEXIST then
      break
    end
  end
  if not fd or not stage_name then
    return nil,
      cleanup_uncommitted(
        pinned.parent_fd,
        pinned.parent_path,
        nil,
        nil,
        open_err or "failed to create an exclusive staging file"
      )
  end

  local stage_stat, stage_stat_err = uv.fs_fstat(fd)
  if not stage_stat then
    local _, close_err = uv.fs_close(fd)
    local message = "fs_fstat: " .. tostring(stage_stat_err or "unknown")
    if close_err then
      message = message .. "; fs_close: " .. tostring(close_err)
    end
    return nil, cleanup_uncommitted(pinned.parent_fd, pinned.parent_path, stage_name, nil, message)
  end

  if expected.exists then
    local chmod_ok, chmod_err = uv.fs_fchmod(fd, mode or DEFAULT_MODE)
    if not chmod_ok then
      local _, close_err = uv.fs_close(fd)
      local message = "fs_fchmod: " .. tostring(chmod_err or "unknown")
      if close_err then
        message = message .. "; fs_close: " .. tostring(close_err)
      end
      return nil, cleanup_uncommitted(pinned.parent_fd, pinned.parent_path, stage_name, stage_stat, message)
    end
  end

  local write_ok, write_err = write_all(fd, content)
  if not write_ok then
    local _, close_err = uv.fs_close(fd)
    local message = "fs_write: " .. tostring(write_err or "unknown")
    if close_err then
      message = message .. "; fs_close: " .. tostring(close_err)
    end
    return nil, cleanup_uncommitted(pinned.parent_fd, pinned.parent_path, stage_name, stage_stat, message)
  end
  local sync_ok, sync_err = uv.fs_fsync(fd)
  if not sync_ok then
    local _, close_err = uv.fs_close(fd)
    local message = "fs_fsync: " .. tostring(sync_err or "unknown")
    if close_err then
      message = message .. "; fs_close: " .. tostring(close_err)
    end
    return nil, cleanup_uncommitted(pinned.parent_fd, pinned.parent_path, stage_name, stage_stat, message)
  end
  local close_ok, close_err = uv.fs_close(fd)
  if not close_ok then
    return nil,
      cleanup_uncommitted(
        pinned.parent_fd,
        pinned.parent_path,
        stage_name,
        stage_stat,
        "fs_close: " .. tostring(close_err or "unknown")
      )
  end

  local intended, intended_err = read_revision_at(pinned.parent_fd, pinned.parent_stat, stage_name)
  if not intended then
    return nil,
      cleanup_uncommitted(
        pinned.parent_fd,
        pinned.parent_path,
        stage_name,
        stage_stat,
        intended_err or "failed to read staging file"
      )
  end

  local plan = {
    target = target,
    base_path = pinned.base_path,
    base_dev = pinned.base_dev,
    base_ino = pinned.base_ino,
    parent_path = pinned.parent_path,
    parent_components = pinned.parent_components,
    parent_fd = pinned.parent_fd,
    parent_dev = pinned.parent_dev,
    parent_ino = pinned.parent_ino,
    target_name = pinned.target_name,
    stage = nil,
    stage_name = nil,
    artifacts = { [stage_name] = "discard" },
    artifact_revisions = { [stage_name] = intended },
    expected = expected,
    intended = intended,
    committed = nil,
    committed_ok = false,
    closed = false,
  }
  set_stage(plan, stage_name)
  return plan, nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
function M.commit(plan)
  if plan.closed or plan.committed_ok or not plan.stage_name then
    return false, "invalid atomic write plan"
  end
  local parent_valid, parent_err = verify_parent(plan)
  if not parent_valid then
    return false, parent_err
  end
  local staged, staged_err = read_revision_at(plan.parent_fd, {
    dev = plan.parent_dev,
    ino = plan.parent_ino,
  }, plan.stage_name)
  if not staged or not M.revisions_equal(plan.intended, staged) then
    track_artifact(plan, plan.stage_name, "protect", staged)
    return false, recovery_message(plan, staged_err or "staging file changed before commit")
  end

  if not plan.expected.exists then
    local moved, move_err, installed, errno =
      move_verified_no_replace(plan, plan.stage_name, plan.target_name, plan.intended)
    if not moved then
      local reason = errno == EEXIST and "resource changed on disk since it was read" or move_err
      return false, recovery_message(plan, reason or "resource changed during atomic creation")
    end
    plan.committed = installed
  else
    local swapped, swap_err = exchange_at(plan.parent_fd, plan.stage_name, plan.target_name)
    if not swapped then
      return false, swap_err
    end
    local displaced, displaced_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, plan.stage_name)
    local installed, installed_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, plan.target_name)
    if
      not displaced
      or not installed
      or not M.revisions_equal(plan.expected, displaced)
      or not M.revisions_equal(plan.intended, installed)
    then
      return recover_failed_exchange(
        plan,
        plan.expected,
        plan.intended,
        true,
        displaced,
        installed,
        displaced_err or installed_err or "resource changed during atomic exchange"
      )
    end
    track_artifact(plan, plan.stage_name, "discard", displaced)
    plan.committed = installed
  end

  plan.committed_ok = true
  local synced, sync_err = sync_parent(plan)
  if not synced then
    return false, sync_err
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
function M.rollback(plan)
  if plan.closed or not plan.committed_ok or not plan.committed then
    return false, "atomic write was not committed"
  end
  local parent_valid, parent_err = verify_parent(plan)
  if not parent_valid then
    return false, parent_err
  end

  if plan.expected.exists then
    if not plan.stage_name then
      return false, "original resource recovery file is missing"
    end
    local recovery, recovery_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, plan.stage_name)
    if not recovery or not M.revisions_equal(plan.expected, recovery) then
      track_artifact(plan, plan.stage_name, "protect", recovery)
      return false, recovery_message(plan, recovery_err or "original resource recovery file changed")
    end
    local swapped, swap_err = exchange_at(plan.parent_fd, plan.stage_name, plan.target_name)
    if not swapped then
      return false, swap_err
    end
    local displaced, displaced_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, plan.stage_name)
    local restored, restored_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, plan.target_name)
    if
      not displaced
      or not restored
      or not M.revisions_equal(plan.committed, displaced)
      or not M.revisions_equal(plan.expected, restored)
    then
      return recover_failed_exchange(
        plan,
        plan.committed,
        plan.expected,
        false,
        displaced,
        restored,
        displaced_err or restored_err or "resource changed during rollback"
      )
    end
    track_artifact(plan, plan.stage_name, "discard", displaced)
  else
    local quarantine, quarantine_err = move_to_unique(plan, plan.target_name, "rollback")
    if not quarantine then
      local current = read_revision_at(plan.parent_fd, {
        dev = plan.parent_dev,
        ino = plan.parent_ino,
      }, plan.target_name)
      if current and not current.exists then
        plan.committed_ok = false
        return true, nil
      end
      return false, quarantine_err
    end
    track_artifact(plan, quarantine, "protect", nil)
    local displaced, displaced_err = read_revision_at(plan.parent_fd, {
      dev = plan.parent_dev,
      ino = plan.parent_ino,
    }, quarantine)
    if not displaced or not M.revisions_equal(plan.committed, displaced) then
      local restore_err = nil
      if displaced then
        plan.artifact_revisions[quarantine] = displaced
        local _
        _, restore_err = move_verified_no_replace(plan, quarantine, plan.target_name, displaced)
      end
      return false,
        recovery_message(
          plan,
          displaced_err
            or ("resource changed after it was written; restoration failed: " .. tostring(restore_err or "unknown"))
        )
    end
    track_artifact(plan, quarantine, "discard", displaced)
    local removed, remove_err = remove_artifact(plan, quarantine)
    if not removed then
      return false, remove_err
    end
  end

  plan.committed_ok = false
  local synced, sync_err = sync_parent(plan)
  if not synced then
    return false, sync_err
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
function M.protect(plan)
  if plan.closed then
    return false, "atomic write plan is already closed"
  end
  for name, kind in pairs(plan.artifacts) do
    if kind == "discard" then
      plan.artifacts[name] = "protect"
    end
  end
  return true, nil
end

---@param plan I18nStatusAtomicFilePlan
---@return boolean
---@return string|nil
function M.discard(plan)
  if plan.closed then
    return true, nil
  end
  local errors = {}
  local names = {}
  for name, kind in pairs(plan.artifacts) do
    if kind == "discard" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local removed, remove_err = remove_artifact(plan, name)
    if not removed then
      errors[#errors + 1] = string.format("%s: %s", artifact_path(plan, name), remove_err or "unknown")
    end
  end
  local _, sync_err = sync_parent(plan)
  if sync_err then
    errors[#errors + 1] = sync_err
  end
  local protected = protected_paths(plan)
  if #protected > 0 then
    errors[#errors + 1] = "protected recovery files: " .. table.concat(protected, ", ")
  end
  local closed, close_err = uv.fs_close(plan.parent_fd)
  plan.closed = true
  if not closed then
    errors[#errors + 1] = "failed to close resource directory: " .. tostring(close_err or "unknown")
  end
  if #errors > 0 then
    return false, table.concat(errors, "; ")
  end
  return true, nil
end

return M
