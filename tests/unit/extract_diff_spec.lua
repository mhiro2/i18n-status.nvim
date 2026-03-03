local stub = require("luassert.stub")

local extract_diff = require("i18n-status.extract_diff")
local resources = require("i18n-status.resources")
local util = require("i18n-status.util")

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

  it("builds source diff lines", function()
    local lines = extract_diff.source_diff_lines({
      text = "Hello",
      t_func = "t",
      proposed_key = "common:hello",
    })

    assert.are.same({
      "Source diff:",
      "- Hello",
      '+ {t("common:hello")}',
    }, lines)
  end)

  it("builds resource diff lines for new key", function()
    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
      proposed_key = "common:hello",
      mode = "new",
    }, { "ja", "en" }, "ja")

    assert.are.same({
      "Resource diff:",
      'ja/common.json: + "hello": "Hello"',
      'en/common.json: + "hello": ""',
    }, lines)
  end)

  it("builds reuse-only resource diff", function()
    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
      proposed_key = "common:hello",
      mode = "reuse",
    }, { "ja", "en" }, "ja")

    assert.are.same({
      "Resource diff:",
      "(reuse existing key: no resource changes)",
    }, lines)
  end)

  it("preserves multibyte text in source and resource previews", function()
    local lines = extract_diff.build_preview_lines({
      text = "日本語テキスト",
      t_func = "tr",
      proposed_key = "common:key",
      mode = "new",
    }, { "ja", "en" }, "ja")

    assert.is_true(lines[2]:find("日本語テキスト", 1, true) ~= nil)
    assert.is_true(lines[3]:find('tr("common:key")', 1, true) ~= nil)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find('ja/common.json: + "key": "日本語テキスト"', 1, true) ~= nil)
  end)

  it("uses resolved resource path and key path when start_dir is provided", function()
    add_stub(resources, "namespace_path", function(_start_dir, lang, _namespace)
      return "/tmp/project/messages/" .. lang .. ".json"
    end)
    add_stub(resources, "key_path_for_file", function(namespace, key_path, _start_dir, _lang, _path)
      return namespace .. "." .. key_path
    end)
    add_stub(util, "shorten_path", function(path)
      return path:match("messages/.+$")
    end)

    local lines = extract_diff.resource_diff_lines({
      text = "Hello",
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
