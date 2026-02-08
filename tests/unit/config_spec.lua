local config = require("i18n-status.config")

describe("config validation", function()
  it("accepts valid configuration", function()
    local cfg = config.setup({
      primary_lang = "en",
      inline = {
        position = "after_key",
        max_len = 50,
        visible_only = false,
        status_only = true,
        debounce_ms = 100,
      },
      resource_watch = {
        enabled = false,
        debounce_ms = 300,
      },
      doctor = {
        ignore_keys = { "^test:", "^dev:" },
      },
      extract = {
        min_length = 3,
        exclude_components = { "Trans", "Translation" },
      },
    })

    assert.are.equal("en", cfg.primary_lang)
    assert.are.equal("after_key", cfg.inline.position)
    assert.are.equal(50, cfg.inline.max_len)
    assert.is_false(cfg.inline.visible_only)
    assert.is_true(cfg.inline.status_only)
    assert.are.equal(100, cfg.inline.debounce_ms)
    assert.is_false(cfg.resource_watch.enabled)
    assert.are.equal(300, cfg.resource_watch.debounce_ms)
    assert.are.same({ "^test:", "^dev:" }, cfg.doctor.ignore_keys)
    assert.are.equal(3, cfg.extract.min_length)
    assert.are.same({ "Trans", "Translation" }, cfg.extract.exclude_components)
  end)

  it("validates inline.position", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      inline = {
        position = "invalid",
      },
    })

    assert.are.equal("eol", cfg.inline.position) -- Should fallback to default
    assert.are.equal(1, #notify_calls)
    assert.is_true(notify_calls[1].msg:match("inline.position") ~= nil)
    assert.are.equal(vim.log.levels.WARN, notify_calls[1].level)

    vim.notify = original_notify
  end)

  it("validates inline.max_len", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    -- Test negative value
    local cfg1 = config.setup({
      inline = {
        max_len = -1,
      },
    })
    assert.are.equal(80, cfg1.inline.max_len) -- Should fallback to default

    -- Test non-integer
    local cfg2 = config.setup({
      inline = {
        max_len = 3.14,
      },
    })
    assert.are.equal(80, cfg2.inline.max_len) -- Should fallback to default

    -- Test zero
    local cfg3 = config.setup({
      inline = {
        max_len = 0,
      },
    })
    assert.are.equal(80, cfg3.inline.max_len) -- Should fallback to default

    -- Test non-number
    local cfg4 = config.setup({
      inline = {
        max_len = "invalid",
      },
    })
    assert.are.equal(80, cfg4.inline.max_len) -- Should fallback to default

    assert.are.equal(4, #notify_calls)

    vim.notify = original_notify
  end)

  it("validates inline.visible_only", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      inline = {
        visible_only = "invalid",
      },
    })

    assert.is_true(cfg.inline.visible_only) -- Should fallback to default
    assert.are.equal(1, #notify_calls)

    vim.notify = original_notify
  end)

  it("validates inline.debounce_ms", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    -- Test negative value
    local cfg1 = config.setup({
      inline = {
        debounce_ms = -1,
      },
    })
    assert.are.equal(80, cfg1.inline.debounce_ms) -- Should fallback to default

    -- Test non-integer
    local cfg2 = config.setup({
      inline = {
        debounce_ms = 3.14,
      },
    })
    assert.are.equal(80, cfg2.inline.debounce_ms) -- Should fallback to default

    -- Test zero (should be valid)
    local cfg3 = config.setup({
      inline = {
        debounce_ms = 0,
      },
    })
    assert.are.equal(0, cfg3.inline.debounce_ms) -- Zero is valid
    assert.are.equal(2, #notify_calls) -- Only 2 warnings (for -1 and 3.14)

    vim.notify = original_notify
  end)

  it("validates resource_watch.debounce_ms", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      resource_watch = {
        debounce_ms = -1,
      },
    })

    assert.are.equal(200, cfg.resource_watch.debounce_ms) -- Should fallback to default
    assert.are.equal(1, #notify_calls)

    vim.notify = original_notify
  end)

  it("validates doctor.ignore_keys", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    -- Test non-table
    local cfg1 = config.setup({
      doctor = {
        ignore_keys = "invalid",
      },
    })
    assert.are.same({}, cfg1.doctor.ignore_keys) -- Should fallback to default

    -- Test array with non-string elements
    local cfg2 = config.setup({
      doctor = {
        ignore_keys = { "valid", 123, "also_valid" },
      },
    })
    -- Invalid entries should be removed
    assert.are.same({ "valid", "also_valid" }, cfg2.doctor.ignore_keys)

    assert.are.equal(2, #notify_calls)

    vim.notify = original_notify
  end)

  it("validates primary_lang", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      primary_lang = 123,
    })

    assert.are.equal("en", cfg.primary_lang) -- Should fallback to default
    assert.are.equal(1, #notify_calls)

    vim.notify = original_notify
  end)

  it("handles nil opts", function()
    local cfg = config.setup(nil)
    assert.are.equal("en", cfg.primary_lang)
    assert.are.equal("eol", cfg.inline.position)
  end)

  it("handles empty opts", function()
    local cfg = config.setup({})
    assert.are.equal("en", cfg.primary_lang)
    assert.are.equal("eol", cfg.inline.position)
  end)

  it("validates extract.min_length", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      extract = {
        min_length = -1,
      },
    })

    assert.are.equal(2, cfg.extract.min_length)
    assert.are.equal(1, #notify_calls)
    assert.is_true(notify_calls[1].msg:match("extract.min_length") ~= nil)
    vim.notify = original_notify
  end)

  it("validates extract.exclude_components", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      extract = {
        exclude_components = { "Trans", 1, "" },
      },
    })

    assert.are.same({ "Trans" }, cfg.extract.exclude_components)
    assert.are.equal(1, #notify_calls)
    vim.notify = original_notify
  end)
end)
