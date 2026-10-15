local init = require("i18n-status")
local render = require("i18n-status.render")
local helpers = require("tests.helpers")

---@param buf integer
---@return integer[]
local function marked_rows(buf)
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.namespace(), 0, -1, {})) do
    rows[#rows + 1] = mark[2]
  end
  table.sort(rows)
  return rows
end

describe("visible-only inline refresh", function()
  it("renders lines that scroll into view", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"k":"値"}')

    helpers.with_cwd(root, function()
      local lines = {}
      for index = 1, 40 do
        lines[index] = 't("k")'
      end
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_buf_set_name(buf, root .. "/src/long.ts")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_height(0, 5)

      init.setup({
        primary_lang = "ja",
        resource_watch = { enabled = false },
        inline = { visible_only = true, debounce_ms = 1 },
      })
      init.attach(buf)
      assert.are.same({ 0, 1, 2, 3, 4 }, marked_rows(buf))

      vim.api.nvim_win_set_cursor(0, { 30, 0 })
      vim.cmd("normal! zt")
      -- Headless Neovim does not redraw, so emit the event a UI would trigger after scrolling.
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(vim.api.nvim_get_current_win()) })

      assert.is_true(vim.wait(2000, function()
        return vim.tbl_contains(marked_rows(buf), 29)
      end, 10))
      assert.is_false(vim.tbl_contains(marked_rows(buf), 0))
    end)
  end)

  it("keeps the rendered range when scrolling back before another range finishes", function()
    local root = helpers.tmpdir()
    helpers.write_file(root .. "/locales/ja/common.json", '{"k":"値"}')

    helpers.with_cwd(root, function()
      local lines = {}
      for index = 1, 40 do
        lines[index] = 't("k")'
      end
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "typescript"
      vim.api.nvim_buf_set_name(buf, root .. "/src/back.ts")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_height(0, 5)

      init.setup({
        primary_lang = "ja",
        resource_watch = { enabled = false },
        inline = { visible_only = true, debounce_ms = 1 },
      })
      init.attach(buf)
      assert.are.same({ 0, 1, 2, 3, 4 }, marked_rows(buf))

      local scan = require("i18n-status.scan")
      local original_extract_async = scan.extract_async
      local delayed = {}
      scan.extract_async = function(bufnr, opts, cb)
        original_extract_async(bufnr, opts, function(items)
          delayed[#delayed + 1] = function()
            cb(items)
          end
        end)
      end
      local core = require("i18n-status.core")
      local win = vim.api.nvim_get_current_win()

      local ok, err = pcall(function()
        -- Scroll away and let that refresh start, then scroll back to the rendered range.
        vim.api.nvim_win_set_cursor(win, { 30, 0 })
        vim.cmd("normal! zt")
        core.refresh(buf, init.get_config(), 1)
        assert.is_true(vim.wait(2000, function()
          return #delayed == 1
        end, 10))
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        vim.cmd("normal! zt")
        vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
        delayed[1]()
        vim.wait(100)
        assert.are.same({ 0, 1, 2, 3, 4 }, marked_rows(buf))
      end)
      scan.extract_async = original_extract_async
      assert(ok, err)
    end)
  end)
end)
