if vim.g.loaded_i18n_status then
  return
end
vim.g.loaded_i18n_status = 1

local function with_module(fn)
  local mod = require("i18n-status")
  mod.ensure_setup()
  return fn(mod)
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("i18n-status-lazy", { clear = true }),
  pattern = { "javascript", "typescript", "javascriptreact", "typescriptreact", "json", "jsonc" },
  callback = function(args)
    with_module(function(mod)
      mod.attach(args.buf)
    end)
  end,
})

vim.api.nvim_create_user_command("I18nLangNext", function()
  with_module(function(mod)
    mod.lang_next()
  end)
end, {})

vim.api.nvim_create_user_command("I18nLangPrev", function()
  with_module(function(mod)
    mod.lang_prev()
  end)
end, {})

vim.api.nvim_create_user_command("I18nLang", function(args)
  with_module(function(mod)
    if not args.args or args.args == "" then
      mod.lang_next()
      return
    end
    mod.lang_set(args.args)
  end)
end, { nargs = "?" })

vim.api.nvim_create_user_command("I18nHover", function()
  with_module(function(mod)
    mod.hover()
  end)
end, {})

vim.api.nvim_create_user_command("I18nDoctor", function()
  with_module(function(mod)
    mod.doctor()
  end)
end, {})

vim.api.nvim_create_user_command("I18nRefresh", function()
  with_module(function(mod)
    mod.refresh()
  end)
end, {})

vim.api.nvim_create_user_command("I18nAddKey", function()
  with_module(function(mod)
    mod.add_key()
  end)
end, {})
