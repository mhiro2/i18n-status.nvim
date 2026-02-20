local hardcoded = require("i18n-status.hardcoded")
local rpc = require("i18n-status.rpc")

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

describe("hardcoded rpc retry", function()
  local original_request_sync

  before_each(function()
    original_request_sync = rpc.request_sync
  end)

  after_each(function()
    rpc.request_sync = original_request_sync
  end)

  it("retries once when process exits cleanly before response", function()
    local calls = 0
    rpc.request_sync = function(_method, _params)
      calls = calls + 1
      if calls == 1 then
        return nil, "process exited (code=0)"
      end
      return {
        items = {
          {
            lnum = 0,
            col = 0,
            end_lnum = 0,
            end_col = 4,
            text = "TEXT",
            kind = "jsx_text",
          },
        },
      },
        nil
    end

    local buf = make_buf({ "TEXT" }, "typescriptreact")
    local items, err = hardcoded.extract(buf, {})

    assert.is_nil(err)
    assert.are.equal(2, calls)
    assert.are.equal(1, #items)
    assert.are.equal("TEXT", items[1].text)
  end)

  it("retries on process exit error and returns items when recovered", function()
    local calls = 0
    rpc.request_sync = function(_method, _params)
      calls = calls + 1
      if calls == 1 then
        return nil, "process exited (code=0)"
      end
      return { items = {} }, nil
    end

    local buf = make_buf({ "TEXT" }, "typescriptreact")
    local items, err = hardcoded.extract(buf, {})

    assert.is_nil(err)
    assert.are.equal(2, calls)
    assert.are.equal(0, #items)
  end)

  it("returns empty result without error after retryable failures", function()
    local calls = 0
    rpc.request_sync = function(_method, _params)
      calls = calls + 1
      return nil, "process exited (code=0)"
    end

    local buf = make_buf({ "TEXT" }, "typescriptreact")
    local items, err = hardcoded.extract(buf, {})

    assert.are.equal("process exited (code=0)", err)
    assert.are.equal(5, calls)
    assert.are.equal(0, #items)
  end)
end)
