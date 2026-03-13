local util = require("i18n-status.util")

describe("util", function()
  it("deep merges nested tables without mutating inputs", function()
    local base = {
      inline = {
        enabled = true,
        hl = {
          text = "Comment",
        },
      },
    }
    local extra = {
      inline = {
        hl = {
          same = "I18nStatusSame",
        },
      },
    }

    local merged = util.tbl_deep_merge(base, extra)

    assert.are.same({
      inline = {
        enabled = true,
        hl = {
          text = "Comment",
          same = "I18nStatusSame",
        },
      },
    }, merged)
    assert.are.same({
      inline = {
        enabled = true,
        hl = {
          text = "Comment",
        },
      },
    }, base)
    assert.are.same({
      inline = {
        hl = {
          same = "I18nStatusSame",
        },
      },
    }, extra)
  end)
end)
