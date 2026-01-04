---@type string
local root = vim.fn.getcwd()
---@type string
local plenary = os.getenv("PLENARY_PATH") or (root .. "/deps/plenary.nvim")
---@type string
local treesitter = os.getenv("TREESITTER_PATH") or (root .. "/deps/nvim-treesitter")
---@type string
local treesitter_install_dir = os.getenv("TREESITTER_INSTALL_DIR") or (root .. "/deps/treesitter")

-- Disable ShaDa file to prevent test warnings
vim.opt.shadafile = "NONE"

vim.opt.runtimepath = vim.env.VIMRUNTIME
vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(plenary)
if vim.fn.isdirectory(treesitter) == 1 then
  vim.opt.runtimepath:append(treesitter)
end
if vim.fn.isdirectory(treesitter_install_dir) == 1 then
  vim.opt.runtimepath:append(treesitter_install_dir)
end
vim.opt.packpath = vim.opt.runtimepath:get()

vim.g.mapleader = " "

vim.api.nvim_cmd({ cmd = "runtime", args = { "plugin/plenary.vim" } }, {})
if vim.fn.isdirectory(treesitter) == 1 then
  vim.api.nvim_cmd({ cmd = "runtime", args = { "plugin/nvim-treesitter.lua" } }, {})
  local install_dir = os.getenv("TREESITTER_INSTALL_DIR")
  if install_dir and install_dir ~= "" then
    require("nvim-treesitter.config").setup({ install_dir = install_dir })
  end
end
