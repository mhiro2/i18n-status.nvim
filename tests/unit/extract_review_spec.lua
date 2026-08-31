local extract_review = require("i18n-status.extract_review")

local function with_replacement_context(candidates)
  for _, candidate in ipairs(candidates) do
    candidate.t_func = "t"
    candidate.source_key_policy = "canonical"
    candidate.replacement_context = "jsx_child"
  end
  return candidates
end

describe("extract review state", function()
  it("updates candidate statuses for conflict/invalid/reuse", function()
    local candidates = with_replacement_context({
      {
        id = 1,
        namespace = "common",
        proposed_key = "common:exists",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 2,
        namespace = "common",
        proposed_key = "common:new-key",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 3,
        namespace = "common",
        proposed_key = "common:..bad",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 4,
        namespace = "common",
        proposed_key = "common:exists",
        mode = "reuse",
        selected = true,
        status = "ready",
      },
      {
        id = 5,
        namespace = "common",
        proposed_key = "common:not-found",
        mode = "reuse",
        selected = true,
        status = "ready",
      },
    })

    extract_review._test.refresh_candidate_statuses(candidates, {
      ["common:exists"] = true,
    })

    assert.are.equal("conflict_existing", candidates[1].status)
    assert.are.equal("ready", candidates[2].status)
    assert.are.equal("invalid_key", candidates[3].status)
    assert.are.equal("ready", candidates[4].status)
    assert.are.equal("error", candidates[5].status)
  end)

  it("marks duplicate new keys as conflicts", function()
    local candidates = with_replacement_context({
      {
        id = 1,
        namespace = "common",
        proposed_key = "common:dup",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 2,
        namespace = "common",
        proposed_key = "common:dup",
        mode = "new",
        selected = true,
        status = "ready",
      },
    })

    extract_review._test.refresh_candidate_statuses(candidates, {})

    assert.are.equal("conflict_existing", candidates[1].status)
    assert.are.equal("conflict_existing", candidates[2].status)
  end)

  it("marks every member of a transitive key-shape conflict", function()
    local candidates = with_replacement_context({
      {
        id = 1,
        namespace = "common",
        proposed_key = "common:a.b",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 2,
        namespace = "common",
        proposed_key = "common:a.c",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 3,
        namespace = "common",
        proposed_key = "common:a",
        mode = "new",
        selected = true,
        status = "ready",
      },
    })

    extract_review._test.refresh_candidate_statuses(candidates, {})

    assert.are.equal("conflict_existing", candidates[1].status)
    assert.are.equal("conflict_existing", candidates[2].status)
    assert.are.equal("conflict_existing", candidates[3].status)
  end)

  it("filters applicable candidates from selected entries", function()
    local candidates = with_replacement_context({
      {
        id = 1,
        namespace = "common",
        proposed_key = "common:ready",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 2,
        namespace = "common",
        proposed_key = "common:exists",
        mode = "new",
        selected = true,
        status = "ready",
      },
      {
        id = 3,
        namespace = "common",
        proposed_key = "common:skip",
        mode = "new",
        selected = false,
        status = "ready",
      },
    })

    local applicable, skipped = extract_review._test.applicable_candidates(candidates, {
      ["common:exists"] = true,
    })

    assert.are.equal(1, #applicable)
    assert.are.equal("common:ready", applicable[1].proposed_key)
    assert.are.equal(1, skipped)
  end)

  it("supports mode transition helpers", function()
    local candidate = {
      mode = "new",
    }

    extract_review._test.set_reuse_mode(candidate)
    assert.are.equal("reuse", candidate.mode)

    extract_review._test.set_new_mode(candidate)
    assert.are.equal("new", candidate.mode)
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
