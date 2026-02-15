---@class I18nStatusReviewActions
local M = {}

local core = require("i18n-status.core")
local resources = require("i18n-status.resources")
local state = require("i18n-status.state")
local util = require("i18n-status.util")
local ops = require("i18n-status.ops")
local key_write = require("i18n-status.key_write")

---@class I18nStatusReviewActionDeps
---@field refresh_doctor_async fun(ctx: I18nStatusReviewCtx, opts?: { full?: boolean })
---@field close_review fun(ctx: I18nStatusReviewCtx)
---@field create_float_win fun(buf: integer, width: integer, height: integer, row: integer, col: integer, border: string, focusable: boolean|nil, title: string|nil, title_pos: string|nil): integer
---@field mode_overview string|nil

local function build_edit_prompt(key, lang, label)
  local lines = {}
  if label and label ~= "" then
    table.insert(lines, label)
  end
  table.insert(lines, "Key: " .. key)
  table.insert(lines, "Locale: " .. lang)
  table.insert(lines, "")
  table.insert(lines, "New value: ")
  return table.concat(lines, "\n")
end

---@param namespace string Namespace
---@param key_path string Key path within namespace
---@param translations table<string, string> Language to value mapping
---@param root string Project root directory
---@param languages string[] List of languages
---@param full_key string Full key name for notification
---@return integer success_count
---@return string[] failed_langs
local function write_translations_to_files(namespace, key_path, translations, root, languages, full_key)
  local success_count, failed_langs = key_write.write_translations(namespace, key_path, translations, root, languages)

  if success_count == #languages then
    vim.notify("Successfully added key: " .. full_key, vim.log.levels.INFO)
  elseif success_count > 0 then
    vim.notify(
      string.format(
        "Partially added: %d/%d languages (%s failed)",
        success_count,
        #languages,
        table.concat(failed_langs, ", ")
      ),
      vim.log.levels.WARN
    )
  else
    vim.notify("Failed to add key", vim.log.levels.ERROR)
  end

  return success_count, failed_langs
end

---@param full_key string Full key name to display in prompts
---@param languages string[] List of languages
---@param on_complete fun(translations: table<string, string>) Callback when all translations collected
local function collect_translations(full_key, languages, on_complete)
  local translations = {}
  local current_index = 1

  local function prompt_next()
    if current_index > #languages then
      on_complete(translations)
      return
    end

    local lang = languages[current_index]
    local prompt = string.format("Add key: %s\nLocale: %s\n\nValue: ", full_key, lang)

    vim.ui.input({ prompt = prompt, default = "" }, function(input)
      if input == nil then
        vim.notify("i18n-status: add key cancelled", vim.log.levels.INFO)
        return
      end
      translations[lang] = input
      current_index = current_index + 1
      prompt_next()
    end)
  end

  prompt_next()
end

---@param key string Key name to validate
---@return boolean valid Whether the key is valid
---@return string|nil error_msg Error message if invalid
local function validate_key_name(key)
  if not key or vim.trim(key) == "" then
    return false, "Key name cannot be empty"
  end

  local colon_pos = key:find(":")
  local second_colon = colon_pos and key:find(":", colon_pos + 1)
  if second_colon then
    return false, "Key name can only contain one ':' separator"
  end

  local namespace = colon_pos and key:sub(1, colon_pos - 1)
  local key_path = colon_pos and key:sub(colon_pos + 1) or key

  if namespace then
    if namespace == "" then
      return false, "Namespace cannot be empty"
    end
    if not namespace:match("^[%w_%-%.]+$") then
      return false, "Namespace can only contain alphanumeric characters, '_', '-', and '.'"
    end
  end

  if not key_path or key_path == "" then
    return false, "Key path cannot be empty"
  end

  if key_path:match("^%.") or key_path:match("%.$") then
    return false, "Key path cannot start or end with a dot"
  end

  if key_path:match("%.%.") then
    return false, "Key path cannot contain consecutive dots"
  end

  if not key_path:match("^[%w_%-%.]+$") then
    return false, "Key path can only contain alphanumeric characters, '_', '-', and '.'"
  end

  return true, nil
end

---@param cache table Resource cache
---@param full_key string Full key name
---@return boolean
local function key_exists_in_cache(cache, full_key)
  if not cache or not cache.index then
    return false
  end
  for _, entries in pairs(cache.index) do
    if entries[full_key] then
      return true
    end
  end
  return false
end

---@param translations table<string, string> Language to value mapping
---@param languages string[] List of languages
---@return boolean valid
local function validate_translations_non_empty(translations, languages)
  for _, lang in ipairs(languages) do
    if not translations[lang] or vim.trim(translations[lang]) == "" then
      vim.notify("All language values must be provided (empty values not allowed)", vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---@param ctx I18nStatusReviewCtx
---@return string
local function review_base_dir(ctx)
  local start_dir = ctx.start_dir or resources.start_dir(ctx.source_buf or vim.api.nvim_get_current_buf())
  local roots = ctx.cache and ctx.cache.roots or nil
  local base_dir = resources.project_root(start_dir, roots)
  if base_dir == "" then
    return start_dir
  end
  return base_dir
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
---@param lang string
local function edit_lang(deps, ctx, lang)
  local item = ctx.detail_item
  if not item then
    return
  end

  local info = item.hover and item.hover.values and item.hover.values[lang]
  local current = info and info.value or ""
  local prompt = build_edit_prompt(item.key, lang, "Edit locale: " .. lang)

  vim.ui.input({ prompt = prompt, default = current }, function(input)
    if input == nil then
      return
    end

    local root = resources.start_dir(ctx.source_buf or vim.api.nvim_get_current_buf())
    local namespace = item.key:match("^(.-):") or resources.fallback_namespace(root)
    local key_path = item.key:match("^[^:]+:(.+)$") or ""
    local path = (info and info.file) or resources.namespace_path(root, lang, namespace)

    if not path then
      vim.notify("i18n-status review: resource path not found (" .. lang .. ")", vim.log.levels.WARN)
      return
    end

    local base_dir = review_base_dir(ctx)
    local sanitized_path, err = util.sanitize_path(path, base_dir)
    if err then
      vim.notify("i18n-status review: invalid file path (" .. err .. ")", vim.log.levels.WARN)
      return
    end

    util.ensure_dir(util.dirname(sanitized_path))
    local data, style = resources.read_json_table(sanitized_path)
    if not data then
      vim.notify("i18n-status review: failed to read json (" .. (style.error or "unknown") .. ")", vim.log.levels.WARN)
      return
    end

    local path_in_file = resources.key_path_for_file(namespace, key_path, root, lang, sanitized_path)
    util.set_nested(data, path_in_file, input)
    resources.write_json_table(sanitized_path, data, style)

    -- Keep user config snapshot from doctor invocation; never rebuild defaults here.
    if ctx.config then
      core.refresh_all(ctx.config)
    end

    if ctx.is_doctor_review then
      deps.refresh_doctor_async(ctx)
    end
  end)
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
local function edit_focus(deps, ctx)
  local focus_lang = ctx.display_lang or ctx.primary_lang
  if not focus_lang or focus_lang == "" then
    return
  end
  edit_lang(deps, ctx, focus_lang)
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
local function edit_locale_select(deps, ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  local languages = ctx.cache and ctx.cache.languages or {}
  if not languages or #languages == 0 then
    vim.notify("i18n-status review: no languages available", vim.log.levels.WARN)
    return
  end

  local function format_lang(lang)
    local info = item.hover and item.hover.values and item.hover.values[lang]
    local status = ""
    if info then
      if info.missing then
        status = " [missing]"
      elseif info.value and info.value ~= "" then
        local preview = info.value:sub(1, 30)
        if #info.value > 30 then
          preview = preview .. "..."
        end
        status = " - " .. preview
      end
    end
    return lang .. status
  end

  local function is_builtin_ui_select()
    local ok, info = pcall(debug.getinfo, vim.ui.select, "S")
    if not ok or not info or not info.source then
      return false
    end
    return info.source:match("vim/ui.lua") ~= nil
  end

  local function create_float_win(buf, width, height, row, col, border, focusable, title, title_pos)
    if deps.create_float_win then
      return deps.create_float_win(buf, width, height, row, col, border, focusable, title, title_pos)
    end
    return vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = border,
      style = "minimal",
      focusable = focusable ~= false,
      title = title,
      title_pos = title_pos,
    })
  end

  local function select_single_key()
    local lines = { "Select locale to edit:" }
    for i, lang in ipairs(languages) do
      lines[#lines + 1] = string.format("%d: %s", i, format_lang(lang))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Type number (1-%d) to edit (q cancels)", #languages)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = "i18n-status-review"
    vim.b[buf].i18n_status_review = true
    vim.b[buf].lsp_enabled = false
    vim.b[buf].treesitter_enabled = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local max_width = 0
    for _, line in ipairs(lines) do
      local width = vim.fn.strdisplaywidth(line)
      if width > max_width then
        max_width = width
      end
    end

    local padding = 2
    local border = (ctx.config and ctx.config.doctor and ctx.config.doctor.float and ctx.config.doctor.float.border)
      or "rounded"
    local win_width = math.min(max_width + padding, vim.o.columns - 4)
    local win_height = math.min(#lines, vim.o.lines - 4)
    local row = math.floor((vim.o.lines - win_height) / 2)
    local col = math.floor((vim.o.columns - win_width) / 2)

    local prev_win = vim.api.nvim_get_current_win()
    local win = create_float_win(buf, win_width, win_height, row, col, border, true, "I18nDoctor - Edit", "center")
    vim.api.nvim_set_current_win(win)

    local function close_float()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
    end

    local function accept(index)
      close_float()
      edit_lang(deps, ctx, languages[index])
    end

    for i = 1, #languages do
      vim.keymap.set("n", tostring(i), function()
        accept(i)
      end, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "q", close_float, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "Q", close_float, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close_float, { buffer = buf, nowait = true, silent = true })
  end

  if is_builtin_ui_select() and #languages <= 9 then
    select_single_key()
    return
  end

  local add_blank_line = is_builtin_ui_select()
  local last_lang = languages[#languages]

  vim.ui.select(languages, {
    prompt = "Select locale to edit:",
    format_item = function(lang)
      local label = format_lang(lang)
      if add_blank_line and lang == last_lang then
        label = label .. "\n"
      end
      return label
    end,
  }, function(selected_lang)
    if not selected_lang then
      return
    end
    edit_lang(deps, ctx, selected_lang)
  end)
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
local function rename_item(deps, ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  local source_buf = ctx.source_buf or vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = "Rename i18n key", default = item.key }, function(input)
    if not input or vim.trim(input) == "" or input == item.key then
      return
    end
    local ok, err = ops.rename({
      item = item,
      source_buf = source_buf,
      new_key = input,
      config = ctx.config,
    })
    if not ok then
      if err then
        vim.notify("i18n-status review: " .. err, vim.log.levels.WARN)
      end
      return
    end
    if ctx.is_doctor_review then
      deps.refresh_doctor_async(ctx, { full = true })
    end
  end)
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
local function add_key(deps, ctx)
  local item = ctx.detail_item
  if not item then
    return
  end
  if item.status ~= "×" then
    vim.notify("Key already exists in primary language", vim.log.levels.WARN)
    return
  end

  local languages = ctx.cache and ctx.cache.languages or {}
  if #languages == 0 then
    vim.notify("No languages available", vim.log.levels.WARN)
    return
  end

  local root = resources.start_dir(ctx.source_buf or vim.api.nvim_get_current_buf())
  local namespace = item.key:match("^(.-):") or resources.fallback_namespace(root)
  local key_path = item.key:match("^[^:]+:(.+)$") or ""

  collect_translations(item.key, languages, function(translations)
    write_translations_to_files(namespace, key_path, translations, root, languages, item.key)

    if ctx.config then
      core.refresh_all(ctx.config)
    end
    if ctx.is_doctor_review then
      deps.refresh_doctor_async(ctx)
    end
  end)
end

---@param deps I18nStatusReviewActionDeps
---@param ctx I18nStatusReviewCtx
local function jump_to_definition(deps, ctx)
  local item = ctx.detail_item
  if not item then
    return
  end

  local mode_overview = deps.mode_overview or "overview"
  if ctx.is_doctor_review and ctx.mode == mode_overview then
    local function pick_info(lang)
      return item.hover and item.hover.values and item.hover.values[lang]
    end

    local info = nil
    if ctx.display_lang and ctx.display_lang ~= "" then
      info = pick_info(ctx.display_lang)
    end
    if not info or not info.file then
      if ctx.primary_lang and ctx.primary_lang ~= "" then
        info = pick_info(ctx.primary_lang)
      end
    end
    if (not info or not info.file) and item.hover and item.hover.values then
      for _, v in pairs(item.hover.values) do
        if v and v.file then
          info = v
          break
        end
      end
    end
    if not info or not info.file then
      vim.notify("i18n-status review: definition file not found", vim.log.levels.WARN)
      return
    end

    local base_dir = review_base_dir(ctx)
    local sanitized_path, err = util.sanitize_path(info.file, base_dir)
    if err then
      vim.notify("i18n-status review: invalid file path (" .. err .. ")", vim.log.levels.WARN)
      return
    end

    deps.close_review(ctx)
    vim.api.nvim_cmd({ cmd = "edit", args = { sanitized_path } }, {})
    return
  end

  local project = ctx.project_key and state.project_for_key(ctx.project_key)
  local focus_lang = (project and project.current_lang)
    or (project and project.primary_lang)
    or (ctx.config and ctx.config.primary_lang)
  if not focus_lang or focus_lang == "" then
    return
  end

  local info = item.hover and item.hover.values and item.hover.values[focus_lang]
  if not info or not info.file then
    vim.notify("i18n-status review: definition file not found", vim.log.levels.WARN)
    return
  end

  local base_dir = review_base_dir(ctx)
  local sanitized_path, err = util.sanitize_path(info.file, base_dir)
  if err then
    vim.notify("i18n-status review: invalid file path (" .. err .. ")", vim.log.levels.WARN)
    return
  end

  deps.close_review(ctx)
  vim.api.nvim_cmd({ cmd = "edit", args = { sanitized_path } }, {})
end

---@param deps I18nStatusReviewActionDeps
---@return {edit_focus: fun(ctx: I18nStatusReviewCtx), edit_locale_select: fun(ctx: I18nStatusReviewCtx), rename_item: fun(ctx: I18nStatusReviewCtx), add_key: fun(ctx: I18nStatusReviewCtx), jump_to_definition: fun(ctx: I18nStatusReviewCtx)}
function M.new(deps)
  vim.validate({
    deps = { deps, "table" },
    refresh_doctor_async = { deps.refresh_doctor_async, "function" },
    close_review = { deps.close_review, "function" },
  })

  return {
    edit_focus = function(ctx)
      edit_focus(deps, ctx)
    end,
    edit_locale_select = function(ctx)
      edit_locale_select(deps, ctx)
    end,
    rename_item = function(ctx)
      rename_item(deps, ctx)
    end,
    add_key = function(ctx)
      add_key(deps, ctx)
    end,
    jump_to_definition = function(ctx)
      jump_to_definition(deps, ctx)
    end,
  }
end

---@param cfg I18nStatusConfig Config
function M.add_key_command(cfg)
  if not cfg then
    vim.notify("i18n-status: not configured", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local root = resources.start_dir(bufnr)
  local cache = resources.ensure_index(root)
  local languages = cache and cache.languages or {}

  if #languages == 0 then
    vim.notify("No languages available", vim.log.levels.WARN)
    return
  end

  local fallback_ns = resources.fallback_namespace(root)
  local prompt_msg = string.format("Add key (namespace omitted → %s): ", fallback_ns)

  vim.ui.input({ prompt = prompt_msg }, function(key_input)
    if not key_input then
      vim.notify("i18n-status: add key cancelled", vim.log.levels.INFO)
      return
    end

    local key = vim.trim(key_input)
    local valid, err_msg = validate_key_name(key)
    if not valid then
      vim.notify(err_msg, vim.log.levels.ERROR)
      return
    end

    local full_key = key:match(":") and key or (fallback_ns .. ":" .. key)
    local namespace = full_key:match("^(.-):")
    local key_path = full_key:match("^[^:]+:(.+)$") or ""

    local function do_add_key()
      collect_translations(full_key, languages, function(translations)
        if not validate_translations_non_empty(translations, languages) then
          return
        end
        write_translations_to_files(namespace, key_path, translations, root, languages, full_key)
        core.refresh_all(cfg)
      end)
    end

    if key_exists_in_cache(cache, full_key) then
      local confirm_msg = string.format("Key already exists: %s\nOverwrite in all languages? (y/N)", full_key)
      vim.ui.input({ prompt = confirm_msg }, function(confirm)
        if not confirm or confirm:lower() ~= "y" then
          vim.notify("i18n-status: add key cancelled", vim.log.levels.INFO)
          return
        end
        do_add_key()
      end)
    else
      do_add_key()
    end
  end)
end

return M
