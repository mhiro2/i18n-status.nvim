local contract = require("i18n-status.core_contract")
local helpers = require("tests.helpers")

describe("core contract", function()
  it("loads the unified manifest used by the Rust build", function()
    local manifest = vim.json.decode(helpers.read_file(vim.fs.joinpath(vim.fn.getcwd(), "core-contract.json")))
    local cargo_toml = helpers.read_file(vim.fs.joinpath(vim.fn.getcwd(), "rust", "Cargo.toml"))
    local package = cargo_toml:match("%[package%](.-)%[") or cargo_toml:match("%[package%](.*)")
    local cargo_name = package and package:match('name%s*=%s*"([^"]+)"') or nil
    local cargo_version = package and package:match('version%s*=%s*"([^"]+)"') or nil

    assert.are.equal(manifest.client_name, contract.client_name)
    assert.are.equal(manifest.core_name, contract.core_name)
    assert.are.equal(manifest.version, contract.version)
    assert.are.equal(manifest.protocol_version, contract.protocol_version)
    assert.are.equal(contract.core_name, cargo_name)
    assert.are.equal(contract.version, cargo_version)
  end)

  it("rejects malformed and incompatible initialize results", function()
    assert.are.equal("core initialize response is missing identity", contract.validate_initialize_result({}))
    assert.is_truthy(contract
      .validate_initialize_result({
        core = { name = contract.core_name, version = contract.version },
        protocol_version = 2,
      })
      :find("core protocol mismatch", 1, true))
    assert.is_truthy(contract
      .validate_initialize_result({
        core = { name = contract.core_name, version = "9.9.9" },
        protocol_version = contract.protocol_version,
      })
      :find("core version mismatch", 1, true))
    assert.is_truthy(contract
      .validate_initialize_result({
        core = { name = "other-core", version = contract.version },
        protocol_version = contract.protocol_version,
      })
      :find("core name mismatch", 1, true))
  end)
end)
