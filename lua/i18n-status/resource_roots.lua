---@class I18nStatusResourceRoots
local M = {}

local fs = require("i18n-status.fs")
local rpc = require("i18n-status.rpc")

local uv = vim.uv

---@param kind string|nil
---@return boolean
function M.is_next_intl_kind(kind)
  return kind == "next-intl" or kind == "next_intl"
end

---@param roots I18nStatusRootInfo[]
---@param start_dir string
---@return string
function M.compute_cache_key(roots, start_dir)
  if not roots or #roots == 0 then
    return "empty:" .. (start_dir or "")
  end
  local normalized = {}
  for _, root in ipairs(roots or {}) do
    normalized[#normalized + 1] = {
      kind = root.kind,
      path = root.path,
    }
  end
  table.sort(normalized, function(a, b)
    if a.kind == b.kind then
      return a.path < b.path
    end
    return a.kind < b.kind
  end)
  return vim.json.encode(normalized)
end

---@param roots I18nStatusRootInfo[]
---@return I18nStatusRootInfo[]
function M.normalize_roots(roots)
  local normalized = {}
  for _, root in ipairs(roots or {}) do
    local root_path = fs.normalize_path(root.path) or root.path
    normalized[#normalized + 1] = {
      kind = root.kind,
      path = root_path,
    }
  end
  table.sort(normalized, function(a, b)
    if a.kind == b.kind then
      return a.path < b.path
    end
    return a.kind < b.kind
  end)
  return normalized
end

---@param root string
---@return string[]
function M.list_dirs(root)
  local dirs = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return dirs
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" then
      dirs[#dirs + 1] = name
    end
  end
  return dirs
end

---@param root string
---@return string[]
function M.list_json_files(root)
  local files = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return files
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" and name:sub(-5) == ".json" then
      files[#files + 1] = fs.path_join(root, name)
    end
  end
  return files
end

---@param roots I18nStatusRootInfo[]
---@return string[]
function M.collect_resource_files(roots)
  local files = {}
  local seen = {}

  local function add(path)
    local normalized = fs.normalize_path(path) or path
    if normalized and normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      files[#files + 1] = normalized
    end
  end

  for _, root in ipairs(roots or {}) do
    local root_path = fs.normalize_path(root.path) or root.path
    if root.kind == "i18next" then
      for _, dir in ipairs(M.list_dirs(root_path)) do
        local lang_root = fs.path_join(root_path, dir)
        for _, file in ipairs(M.list_json_files(lang_root)) do
          add(file)
        end
      end
    elseif M.is_next_intl_kind(root.kind) then
      for _, file in ipairs(M.list_json_files(root_path)) do
        add(file)
      end
      for _, dir in ipairs(M.list_dirs(root_path)) do
        local lang_root = fs.path_join(root_path, dir)
        for _, file in ipairs(M.list_json_files(lang_root)) do
          add(file)
        end
      end
    end
  end

  table.sort(files)
  return files
end

---@param roots I18nStatusRootInfo[]
---@param path string
---@return I18nStatusResourceInfo|nil
function M.resource_info_from_roots(roots, path)
  if not path or path == "" then
    return nil
  end
  local normalized = path:gsub("\\", "/")
  for _, root in ipairs(roots or {}) do
    local root_path = root.path:gsub("\\", "/")
    if root_path:sub(-1) ~= "/" then
      root_path = root_path .. "/"
    end
    if normalized:sub(1, #root_path) == root_path then
      local relative = normalized:sub(#root_path + 1)
      if root.kind == "i18next" then
        local lang, ns_file = relative:match("^([^/]+)/(.+)$")
        if lang and ns_file then
          return {
            kind = root.kind,
            root = root.path,
            lang = lang,
            namespace = ns_file:gsub("%.json$", ""),
            is_root = false,
          }
        end
      elseif M.is_next_intl_kind(root.kind) then
        local lang_only = relative:match("^([^/]+)%.json$")
        if lang_only then
          return {
            kind = root.kind,
            root = root.path,
            lang = lang_only,
            namespace = nil,
            is_root = true,
          }
        end
        local lang, ns_file = relative:match("^([^/]+)/(.+)$")
        if lang and ns_file then
          return {
            kind = root.kind,
            root = root.path,
            lang = lang,
            namespace = ns_file:gsub("%.json$", ""),
            is_root = false,
          }
        end
      end
    end
  end
  return nil
end

---@param bufnr integer|nil
---@return string
function M.start_dir(bufnr)
  local target = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(target)
  if name and name ~= "" then
    local dir = fs.dirname(name)
    while dir and dir ~= "" and dir ~= "/" and not fs.is_dir(dir) do
      local parent = fs.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
    if dir and dir ~= "" and fs.is_dir(dir) then
      return dir
    end
  end
  return vim.fn.getcwd()
end

---@param start_dir string
---@return I18nStatusRootInfo[]
function M.resolve_roots_sync(start_dir)
  local roots_result, roots_err = rpc.request_sync("resource/resolveRoots", {
    start_dir = start_dir,
  })
  if not roots_err and roots_result and roots_result.roots then
    return M.normalize_roots(roots_result.roots)
  end
  return {}
end

---@param start_dir string
---@param roots I18nStatusRootInfo[]|nil
---@return string
function M.project_root(start_dir, roots)
  if not start_dir or start_dir == "" then
    return ""
  end
  start_dir = fs.normalize_path(start_dir) or start_dir

  if not roots or #roots == 0 then
    roots = M.resolve_roots_sync(start_dir)
  end

  local git_root = fs.find_git_root(start_dir)
  if git_root then
    return git_root
  end

  local paths = { start_dir }
  for _, root in ipairs(roots or {}) do
    if root and root.path and root.path ~= "" then
      paths[#paths + 1] = root.path
    end
  end
  if #paths == 0 then
    return start_dir
  end
  if #paths == 1 then
    local dir = start_dir
    while dir and dir ~= "" and dir ~= "/" do
      if
        fs.is_dir(fs.path_join(dir, "locales"))
        or fs.is_dir(fs.path_join(dir, "messages"))
        or fs.is_dir(fs.path_join(dir, "public", "locales"))
        or fs.is_dir(fs.path_join(dir, "public", "messages"))
      then
        return dir
      end
      local parent = fs.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
    return start_dir
  end

  local common = paths[1]
  for i = 2, #paths do
    local parts1 = vim.split(common, "/", { plain = true })
    local parts2 = vim.split(paths[i], "/", { plain = true })
    local min_len = math.min(#parts1, #parts2)
    local new_common = {}
    for j = 1, min_len do
      if parts1[j] == parts2[j] then
        new_common[#new_common + 1] = parts1[j]
      else
        break
      end
    end
    common = table.concat(new_common, "/")
    if common == "" then
      return start_dir
    end
  end
  return common
end

return M
