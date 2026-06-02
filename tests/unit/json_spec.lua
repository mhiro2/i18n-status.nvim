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

      local ok = json.set_nested(data, "a.b.c", "value")

      assert.is_true(ok)
      assert.are.same({ a = { b = { c = "value" } } }, data)
    end)

    it("refuses to overwrite an existing scalar with a branch", function()
      local data = { login = "Login" }

      local ok, err = json.set_nested(data, "login.title", "Title")

      assert.is_false(ok)
      assert.is_truthy(err)
      -- The existing scalar must be left untouched.
      assert.are.same({ login = "Login" }, data)
    end)

    it("refuses to turn an existing list into a branch", function()
      local data = { login = { "a", "b" } }

      local ok, err = json.set_nested(data, "login.title", "Title")

      assert.is_false(ok)
      assert.is_truthy(err)
      -- The existing list must be left untouched.
      assert.are.same({ login = { "a", "b" } }, data)
    end)

    it("descends into a decoded empty object", function()
      local data = vim.json.decode('{"login":{}}')

      local ok = json.set_nested(data, "login.title", "Title")

      assert.is_true(ok)
      assert.are.equal('{\n  "login": {\n    "title": "Title"\n  }\n}', json.json_encode_pretty(data))
    end)

    it("overwrites an existing leaf value", function()
      local data = { a = { b = "old" } }

      local ok = json.set_nested(data, "a.b", "new")

      assert.is_true(ok)
      assert.are.same({ a = { b = "new" } }, data)
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

    it("encodes an empty object as {} rather than []", function()
      assert.are.equal("{}", json.json_encode_pretty(vim.empty_dict()))
      assert.are.equal("{}", json.json_encode_pretty(vim.json.decode("{}")))
    end)

    it("keeps an empty array as []", function()
      assert.are.equal("[]", json.json_encode_pretty(vim.json.decode("[]")))
    end)

    it("preserves nested empty objects when round-tripping", function()
      local decoded = vim.json.decode('{"a":{},"b":"x"}')

      assert.are.equal('{\n  "a": {},\n  "b": "x"\n}', json.json_encode_pretty(decoded))
    end)
  end)
end)
