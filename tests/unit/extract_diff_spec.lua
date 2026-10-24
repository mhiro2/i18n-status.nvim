local stub = require("luassert.stub")

local extract_diff = require("i18n-status.extract_diff")
local fs = require("i18n-status.fs")
local resources = require("i18n-status.resources")

describe("extract diff", function()
  local stubs = {}

  local function add_stub(tbl, method, impl)
    local s = stub(tbl, method, impl)
    stubs[#stubs + 1] = s
    return s
  end

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
    stubs = {}
  end)

  it("builds resource diff lines for new key", function()
    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
      message = "Hello",
      proposed_key = "common:hello",
      mode = "new",
    }, { "ja", "en" }, "ja")

    assert.are.same({
      "Resource diff:",
      'ja/common.json: + "hello": "Hello"',
      'en/common.json: + "hello": ""',
    }, lines)
  end)

  it("previews the escaped resource message instead of the source text", function()
    local lines = extract_diff.resource_diff_lines({
      text = "Hello {name}",
      message = "Hello '{'name'}'",
      proposed_key = "Home:hello-name",
      mode = "new",
    }, { "ja" }, "ja")

    assert.are.same({
      "Resource diff:",
      [[ja/Home.json: + "hello-name": "Hello '{'name'}'"]],
    }, lines)
  end)

  it("builds reuse-only resource diff", function()
    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
      message = "Hello",
      proposed_key = "common:hello",
      mode = "reuse",
    }, { "ja", "en" }, "ja")

    assert.are.same({
      "Resource diff:",
      "(reuse existing key: no resource changes)",
    }, lines)
  end)

  it("uses resolved resource path and key path when start_dir is provided", function()
    add_stub(resources, "namespace_path", function(_start_dir, lang, _namespace)
      return "/tmp/project/messages/" .. lang .. ".json"
    end)
    add_stub(resources, "key_path_for_file", function(namespace, key_path, _start_dir, _lang, _path)
      return namespace .. "." .. key_path
    end)
    add_stub(fs, "shorten_path", function(path)
      return path:match("messages/.+$")
    end)

    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
      message = "Hello",
      proposed_key = "common:hello",
      mode = "new",
    }, { "ja", "en" }, "ja", "/tmp/project/src")

    assert.are.same({
      "Resource diff:",
      'messages/ja.json: + "common.hello": "Hello"',
      'messages/en.json: + "common.hello": ""',
    }, lines)
  end)
end)
