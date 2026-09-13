local stub = require("luassert.stub")

local fs = require("i18n-status.fs")
local resources = require("i18n-status.resources")
local rpc = require("i18n-status.rpc")
local treesitter = require("i18n-status.treesitter")
local contract = require("i18n-status.core_contract")

describe("health", function()
  local stubs
  local original_plugin
  local messages
  local ready_result
  local status_result

  local function add_stub(target, method, implementation)
    local value = stub(target, method, implementation)
    stubs[#stubs + 1] = value
  end

  before_each(function()
    stubs = {}
    messages = {}
    ready_result = { true, nil }
    status_result = {
      state = "ready",
      expected = {
        name = contract.core_name,
        version = contract.version,
        protocol_version = contract.protocol_version,
      },
      core = {
        name = contract.core_name,
        version = contract.version,
        protocol_version = contract.protocol_version,
      },
    }
    original_plugin = package.loaded["i18n-status"]

    for _, level in ipairs({ "start", "ok", "info", "warn" }) do
      add_stub(vim.health, level, function(message)
        messages[#messages + 1] = level .. ": " .. message
      end)
    end

    package.loaded["i18n-status"] = {
      get_config = function()
        return { primary_lang = "en", resource_watch = { enabled = false }, core = { path = "/bin/sh" } }
      end,
    }

    add_stub(rpc, "configure", function() end)
    add_stub(rpc, "ensure_ready", function()
      return ready_result[1], ready_result[2]
    end)
    add_stub(rpc, "status", function()
      return status_result
    end)
    add_stub(rpc, "resolve_binary", function()
      return "/bin/sh", "core.path"
    end)
    add_stub(resources, "start_dir", function()
      return "/tmp/project"
    end)
    add_stub(resources, "ensure_index", function()
      return {
        key = "/tmp/project",
        roots = { { kind = "i18next", path = "/tmp/project/locales" } },
        languages = { "en" },
        errors = {},
      }
    end)
    add_stub(resources, "namespace_hint", function()
      return "common", "single", { "common" }
    end)
    add_stub(fs, "is_dir", function()
      return true
    end)
    add_stub(treesitter, "has_parser", function()
      return true
    end)
  end)

  after_each(function()
    for _, value in ipairs(stubs) do
      value:revert()
    end
    package.loaded["i18n-status"] = original_plugin
    package.loaded["i18n-status.health"] = nil
  end)

  it("reports the selected binary and completed contract", function()
    require("i18n-status.health").check()
    local output = table.concat(messages, "\n")

    assert.is_truthy(
      output:find(
        string.format(
          "required contract: %s %s, protocol %d",
          contract.core_name,
          contract.version,
          contract.protocol_version
        ),
        1,
        true
      )
    )
    assert.is_truthy(
      output:find(
        string.format(
          "core handshake complete: %s %s, protocol %d",
          contract.core_name,
          contract.version,
          contract.protocol_version
        ),
        1,
        true
      )
    )
    assert.is_truthy(output:find("binary selected (core.path): /bin/sh", 1, true))
  end)

  it("warns after a fail-closed handshake timeout", function()
    ready_result = { false, "core handshake timed out after 3000ms" }
    status_result.state = "failed"
    status_result.error = ready_result[2]
    status_result.core = nil

    require("i18n-status.health").check()
    local output = table.concat(messages, "\n")

    assert.is_truthy(output:find("warn: core handshake failed: core handshake timed out after 3000ms", 1, true))
  end)
end)
