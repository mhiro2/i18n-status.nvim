local extract_review = require("i18n-status.extract_review")
local extract_review_apply = require("i18n-status.extract_review_apply")
local resource_catalog = require("i18n-status.resource_catalog")

---@param framework 'i18next'|'next_intl'
---@param index table<string, table<string, string>>
---@return I18nStatusFrameworkCatalog
local function make_catalog(framework, index)
  local languages = {}
  local catalog_index = {}
  for lang, entries in pairs(index) do
    languages[#languages + 1] = lang
    catalog_index[lang] = {}
    for key, value in pairs(entries) do
      catalog_index[lang][key] = { value = value }
    end
  end
  table.sort(languages)
  return {
    errors = {},
    existing_keys = resource_catalog.collect_existing_keys({ index = catalog_index }),
    framework = framework,
    index = catalog_index,
    languages = languages,
    namespaces = { "common" },
    root_kind = resource_catalog.root_kind(framework),
    roots = {},
  }
end

local next_id = 0

---@param key string
---@param opts? table
---@return I18nStatusExtractCandidate
local function make_candidate(key, opts)
  next_id = next_id + 1
  return vim.tbl_extend("force", {
    id = next_id,
    framework = "i18next",
    languages = { "en", "ja" },
    namespace = "common",
    proposed_key = key,
    mode = "new",
    selected = true,
    status = "ready",
    t_func = "t",
    source_key_policy = "canonical",
    replacement_context = "jsx_child",
  }, opts or {})
end

---@param candidates I18nStatusExtractCandidate[]
---@return string[]
local function statuses(candidates)
  return vim.tbl_map(function(candidate)
    return candidate.status
  end, candidates)
end

describe("extract review state", function()
  local catalogs

  before_each(function()
    catalogs = {
      i18next = make_catalog("i18next", {
        en = { ["common:exists"] = "Exists", ["common:parent.child"] = "Child" },
        ja = { ["common:exists"] = "既存", ["common:parent.child"] = "子", ["common:ja-only"] = "日本語" },
      }),
      next_intl = make_catalog("next_intl", { en = {}, ja = {} }),
    }
  end)

  it("updates candidate statuses for conflict/invalid/reuse against the catalog", function()
    local candidates = {
      make_candidate("common:exists"),
      make_candidate("common:new-key"),
      make_candidate("common:..bad"),
      make_candidate("common:exists", { mode = "reuse" }),
      make_candidate("common:not-found", { mode = "reuse" }),
    }

    extract_review_apply.refresh_candidate_statuses(candidates, catalogs, {})

    assert.are.same({ "conflict_existing", "ready", "invalid_key", "ready", "error" }, statuses(candidates))
    assert.are.equal("reuse target does not exist", candidates[5].error)
  end)

  it("treats existing ancestors and descendants as conflicts", function()
    local candidates = {
      make_candidate("common:exists.child"),
      make_candidate("common:parent"),
      make_candidate("common:parent-sibling"),
    }

    extract_review_apply.refresh_candidate_statuses(candidates, catalogs, {})

    assert.are.same({ "conflict_existing", "conflict_existing", "ready" }, statuses(candidates))
  end)

  it("checks existing keys only in the candidate languages", function()
    local english_only = make_candidate("common:ja-only", { languages = { "en" } })
    local both = make_candidate("common:ja-only", { languages = { "en", "ja" } })

    -- Evaluate separately so the duplicate check does not mask the per-language result.
    extract_review_apply.refresh_candidate_statuses({ english_only }, catalogs, {})
    extract_review_apply.refresh_candidate_statuses({ both }, catalogs, {})

    assert.are.same({ "ready", "conflict_existing" }, statuses({ english_only, both }))
  end)

  it("keeps each framework's catalog and duplicates separate", function()
    local candidates = {
      make_candidate("common:exists", { framework = "next_intl" }),
      make_candidate("common:shared", { framework = "next_intl" }),
      make_candidate("common:shared"),
    }

    extract_review_apply.refresh_candidate_statuses(candidates, catalogs, {})

    assert.are.same({ "ready", "ready", "ready" }, statuses(candidates))
  end)

  it("marks duplicate new keys as conflicts", function()
    local candidates = {
      make_candidate("common:dup"),
      make_candidate("common:dup"),
    }

    extract_review_apply.refresh_candidate_statuses(candidates, catalogs, {})

    assert.are.same({ "conflict_existing", "conflict_existing" }, statuses(candidates))
    assert.are.equal("duplicate candidate key", candidates[1].error)
  end)

  it("marks every member of a transitive key-shape conflict", function()
    local candidates = {
      make_candidate("common:a.b"),
      make_candidate("common:a.c"),
      make_candidate("common:a"),
    }

    extract_review_apply.refresh_candidate_statuses(candidates, catalogs, {})

    assert.are.same({ "conflict_existing", "conflict_existing", "conflict_existing" }, statuses(candidates))
    assert.are.equal("overlapping candidate key", candidates[1].error)
  end)

  it("filters applicable candidates from selected entries", function()
    local candidates = {
      make_candidate("common:ready"),
      make_candidate("common:exists"),
      make_candidate("common:skip", { selected = false }),
    }
    local ctx = {
      candidates = candidates,
      existing_keys = {},
      framework_catalogs = catalogs,
    }

    local applicable, skipped = extract_review_apply.applicable_candidates(ctx, candidates)

    assert.are.equal(1, #applicable)
    assert.are.equal("common:ready", applicable[1].proposed_key)
    assert.are.equal(1, skipped)
    assert.is_false(ctx.statuses_dirty)
  end)

  it("builds apply summary message", function()
    local message = extract_review._test.build_apply_message({
      applied = 2,
      skipped = 1,
      failed = 0,
    })

    assert.are.equal("i18n-status extract: applied=2 skipped=1 failed=0", message)
  end)
end)
