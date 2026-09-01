local transaction = require("i18n-status.mutation_transaction")
local stub = require("luassert.stub")

describe("mutation transaction", function()
  local stubs = {}

  local function add_stub(tbl, method, impl)
    local value = stub(tbl, method, impl)
    stubs[#stubs + 1] = value
    return value
  end

  after_each(function()
    for _, value in ipairs(stubs) do
      value:revert()
    end
    stubs = {}
  end)

  it("validates every participant before committing in order", function()
    local calls = {}
    local function participant(label)
      return {
        label = label,
        validate = function()
          calls[#calls + 1] = "validate " .. label
          return true
        end,
        commit = function()
          calls[#calls + 1] = "commit " .. label
          return true
        end,
        rollback = function()
          calls[#calls + 1] = "rollback " .. label
          return true
        end,
        cleanup = function()
          calls[#calls + 1] = "cleanup " .. label
          return true
        end,
      }
    end

    local ok, err = transaction.run({ participant("one"), participant("two") })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.same({
      "validate one",
      "validate two",
      "commit one",
      "commit two",
      "cleanup two",
      "cleanup one",
    }, calls)
  end)

  it("rolls back the failing participant when it reports a mutation", function()
    local calls = {}
    local function participant(label, commit)
      return {
        label = label,
        commit = function()
          calls[#calls + 1] = "commit " .. label
          return commit()
        end,
        rollback = function()
          calls[#calls + 1] = "rollback " .. label
          return true
        end,
        cleanup = function()
          calls[#calls + 1] = "cleanup " .. label
          return true
        end,
      }
    end

    local ok, err = transaction.run({
      participant("one", function()
        return true
      end),
      participant("two", function()
        return false, "disk changed", true
      end),
      participant("three", function()
        error("must not commit")
      end),
    })

    assert.is_false(ok)
    assert.are.equal("two commit failed: disk changed", err)
    assert.are.same({
      "commit one",
      "commit two",
      "rollback two",
      "rollback one",
      "cleanup three",
      "cleanup two",
      "cleanup one",
    }, calls)
  end)

  it("rolls back the current participant when commit raises", function()
    local calls = {}
    local ok, err = transaction.run({
      {
        label = "source",
        commit = function()
          calls[#calls + 1] = "commit source"
          error("write interrupted")
        end,
        rollback = function()
          calls[#calls + 1] = "rollback source"
          return true
        end,
        cleanup = function()
          calls[#calls + 1] = "cleanup source"
          return true
        end,
      },
    })

    assert.is_false(ok)
    assert.matches("source commit raised:", err, 1, true)
    assert.matches("write interrupted", err, 1, true)
    assert.are.same({ "commit source", "rollback source", "cleanup source" }, calls)
  end)

  it("aggregates the primary, rollback, and cleanup errors", function()
    local ok, err = transaction.run({
      {
        label = "source",
        commit = function()
          return true
        end,
        rollback = function()
          return false, "user changed buffer"
        end,
        cleanup = function()
          return false, "extmark remains"
        end,
      },
      {
        label = "resource",
        commit = function()
          return false, "rename failed", true
        end,
        rollback = function()
          error("restore failed")
        end,
        cleanup = function()
          return false, "stage remains"
        end,
      },
    })

    assert.is_false(ok)
    assert.matches("resource commit failed: rename failed", err, 1, true)
    assert.matches("rollback errors: resource rollback raised:", err, 1, true)
    assert.matches("restore failed; source rollback failed: user changed buffer", err, 1, true)
    assert.matches(
      "cleanup errors: resource cleanup failed: stage remains; source cleanup failed: extmark remains",
      err,
      1,
      true
    )
  end)

  it("reports cleanup failure without making a committed transaction retryable", function()
    local notifications = {}
    add_stub(vim, "notify", function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end)

    local ok, err = transaction.run({
      {
        label = "resource",
        commit = function()
          return true
        end,
        rollback = function()
          return true
        end,
        cleanup = function()
          return false, "stage remains"
        end,
      },
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.matches("resource cleanup failed: stage remains", notifications[1].message, 1, true)
  end)

  it("cleans up all participants after preflight failure", function()
    local calls = {}
    local ok, err = transaction.run({
      {
        label = "source",
        validate = function()
          return false, "changedtick differs"
        end,
        commit = function()
          error("must not commit")
        end,
        rollback = function()
          error("must not roll back")
        end,
        cleanup = function()
          calls[#calls + 1] = "cleanup source"
          return true
        end,
      },
      {
        label = "resource",
        commit = function()
          error("must not commit")
        end,
        rollback = function()
          error("must not roll back")
        end,
        cleanup = function()
          calls[#calls + 1] = "cleanup resource"
          return true
        end,
      },
    })

    assert.is_false(ok)
    assert.are.equal("source validate failed: changedtick differs", err)
    assert.are.same({ "cleanup resource", "cleanup source" }, calls)
  end)
end)
