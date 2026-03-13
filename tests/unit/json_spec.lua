local json = require("i18n-status.json")

describe("json", function()
  describe("json_decode", function()
    it("decodes valid json", function()
      local decoded, err = json.json_decode('{"ok":true}')

      assert.is_nil(err)
      assert.are.same({ ok = true }, decoded)
    end)

    it("returns an error for invalid json", function()
      local decoded, err = json.json_decode("{")

      assert.is_nil(decoded)
      assert.is_truthy(err)
    end)
  end)

  describe("detect_indent", function()
    it("detects space indentation", function()
      assert.are.equal("  ", json.detect_indent('{\n  "a": 1\n}'))
    end)

    it("detects tab indentation", function()
      assert.are.equal("\t", json.detect_indent('{\n\t"a": 1\n}'))
    end)

    it("falls back to two spaces for empty text", function()
      assert.are.equal("  ", json.detect_indent(""))
    end)
  end)

  describe("set_nested", function()
    it("creates nested tables as needed", function()
      local data = {}

      json.set_nested(data, "a.b.c", "value")

      assert.are.same({ a = { b = { c = "value" } } }, data)
    end)

    it("replaces non-table nodes on the path", function()
      local data = { a = "leaf" }

      json.set_nested(data, "a.b", "value")

      assert.are.same({ a = { b = "value" } }, data)
    end)
  end)

  describe("json_encode_pretty", function()
    it("encodes sorted objects and arrays", function()
      local encoded = json.json_encode_pretty({
        b = 1,
        a = { 1, 2 },
        c = { nested = true },
      })

      assert.are.equal('{\n  "a": [\n    1,\n    2\n  ],\n  "b": 1,\n  "c": {\n    "nested": true\n  }\n}', encoded)
    end)
  end)
end)
