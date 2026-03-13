local window = require("i18n-status.window")

describe("window", function()
  it("returns the union range across visible windows for a buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 200 do
      lines[i] = ("line %03d"):format(i)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local win1 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win1, buf)

    vim.api.nvim_cmd({ cmd = "split" }, {})
    local win2 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win2, buf)

    vim.api.nvim_win_set_cursor(win1, { 1, 0 })
    vim.api.nvim_win_set_cursor(win2, { 150, 0 })

    local wins = vim.fn.win_findbuf(buf)
    local expected_top = nil
    local expected_bottom = nil
    for _, winid in ipairs(wins) do
      local win_top = vim.fn.line("w0", winid)
      local win_bottom = vim.fn.line("w$", winid)
      if expected_top == nil or win_top < expected_top then
        expected_top = win_top
      end
      if expected_bottom == nil or win_bottom > expected_bottom then
        expected_bottom = win_bottom
      end
    end

    local top, bottom = window.visible_range(buf)

    vim.api.nvim_win_close(win2, true)
    vim.api.nvim_set_current_win(win1)

    assert.are.equal(expected_top, top)
    assert.are.equal(expected_bottom, bottom)
  end)

  it("falls back to the full buffer range when hidden", function()
    local hidden = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "a", "b", "c", "d" })

    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "x" })
    vim.api.nvim_set_current_buf(other)

    local top, bottom = window.visible_range(hidden)

    assert.are.equal(1, top)
    assert.are.equal(4, bottom)
  end)
end)
