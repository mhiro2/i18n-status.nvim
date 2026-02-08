local resources = require("i18n-status.resources")

---@class I18nStatusProjectState
---@field key string
---@field primary_lang string|nil
---@field current_lang string|nil
---@field last_lang string|nil
---@field languages string[]

---@class I18nStatusState
local M = {
  default_primary = nil,
  projects = {},
  buf_project = {},
  buf_watcher_keys = {},
  inline_by_buf = {},
  resolved_by_buf = {},
  visible_range_by_buf = {},
  last_changedtick = {},
  timers = {},
}

local DEFAULT_KEY = "__default__"

---@param key string|nil
---@return I18nStatusProjectState
local function ensure_project(key)
  key = key or DEFAULT_KEY
  if not M.projects[key] then
    M.projects[key] = {
      key = key,
      primary_lang = M.default_primary,
      current_lang = M.default_primary,
      last_lang = nil,
      languages = {},
    }
  end
  return M.projects[key]
end

---@param primary string
---@param languages string[]
function M.init(primary, languages)
  M.default_primary = primary
  M.projects = {}
  M.buf_project = {}
  M.buf_watcher_keys = {}
  M.inline_by_buf = {}
  M.resolved_by_buf = {}
  M.visible_range_by_buf = {}
  M.last_changedtick = {}
  M.timers = {}
  local project = ensure_project(DEFAULT_KEY)
  project.primary_lang = primary
  project.current_lang = primary
  project.languages = languages or {}
end

---@param key string|nil
---@param languages string[]
---@return I18nStatusProjectState
function M.set_languages(key, languages)
  local project = ensure_project(key)
  project.languages = languages or {}
  if #project.languages == 0 then
    return project
  end
  local present = {}
  for _, lang in ipairs(project.languages) do
    present[lang] = true
  end
  if not project.primary_lang or not present[project.primary_lang] then
    project.primary_lang = project.languages[1]
  end
  if not project.current_lang or not present[project.current_lang] then
    project.current_lang = project.primary_lang
    project.last_lang = nil
  end
  return project
end

---@param key string|nil
---@param lang string|nil
---@return boolean
function M.has_language(key, lang)
  if not lang or lang == "" then
    return false
  end
  local project = ensure_project(key)
  for _, existing in ipairs(project.languages or {}) do
    if existing == lang then
      return true
    end
  end
  return false
end

---@param key string|nil
---@param lang string
---@param opts? { make_primary?: boolean }
---@return I18nStatusProjectState
function M.set_current(key, lang, opts)
  local project = ensure_project(key)
  if project.current_lang and project.current_lang ~= lang then
    project.last_lang = project.current_lang
  end
  project.current_lang = lang
  if opts and opts.make_primary then
    project.primary_lang = lang
  end
  return project
end

---@param key string|nil
---@return string
function M.cycle_next(key)
  local project = ensure_project(key)
  local langs = project.languages
  if #langs == 0 then
    return project.current_lang or project.primary_lang or ""
  end
  local idx = 1
  for i, lang in ipairs(langs) do
    if lang == project.current_lang then
      idx = i
      break
    end
  end
  local next_idx = idx + 1
  if next_idx > #langs then
    next_idx = 1
  end
  M.set_current(key, langs[next_idx])
  return project.current_lang
end

---@param key string|nil
---@return string
function M.cycle_prev(key)
  local project = ensure_project(key)
  if project.last_lang then
    project.current_lang, project.last_lang = project.last_lang, project.current_lang
    return project.current_lang
  end
  local langs = project.languages
  if #langs == 0 then
    return project.current_lang or project.primary_lang or ""
  end
  local idx = 1
  for i, lang in ipairs(langs) do
    if lang == project.current_lang then
      idx = i
      break
    end
  end
  local prev_idx = idx - 1
  if prev_idx < 1 then
    prev_idx = #langs
  end
  M.set_current(key, langs[prev_idx])
  return project.current_lang
end

---@param bufnr integer
---@param key string
function M.set_buf_project(bufnr, key)
  M.buf_project[bufnr] = key
end

---@param key string|nil
---@return I18nStatusProjectState
function M.project_for_key(key)
  return ensure_project(key)
end

---@param bufnr integer
---@return I18nStatusProjectState, string|nil
function M.project_for_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local key = M.buf_project[bufnr]
  if key then
    return ensure_project(key), key
  end
  local start_dir = resources.start_dir(bufnr)
  local cache = resources.ensure_index(start_dir)
  key = cache.key
  M.set_buf_project(bufnr, key)
  return M.set_languages(key, cache.languages), key
end

---@param bufnr integer
function M.clear_buf(bufnr)
  M.inline_by_buf[bufnr] = nil
  M.resolved_by_buf[bufnr] = nil
  M.visible_range_by_buf[bufnr] = nil
  M.last_changedtick[bufnr] = nil
  M.buf_project[bufnr] = nil
end

---@param new_primary string
---@param old_primary string|nil
function M.update_primary(new_primary, old_primary)
  if not new_primary or new_primary == "" then
    return
  end
  old_primary = old_primary or M.default_primary
  if M.default_primary == new_primary and old_primary == new_primary then
    return
  end
  local previous = old_primary or M.default_primary
  M.default_primary = new_primary
  for _, project in pairs(M.projects) do
    if project.primary_lang == nil or project.primary_lang == previous then
      project.primary_lang = new_primary
      if project.current_lang == previous then
        project.current_lang = new_primary
      end
    end
  end
end

return M
