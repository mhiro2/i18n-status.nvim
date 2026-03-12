local resource_roots = require("i18n-status.resource_roots")
local helpers = require("tests.helpers")

local uv = vim.uv

local function write(path, content)
  helpers.write_file(path, content)
end

describe("resource roots", function()
  it("normalizes and sorts roots for stable cache keys", function()
    local root = helpers.tmpdir()
    vim.fn.mkdir(root .. "/messages", "p")
    local roots = resource_roots.normalize_roots({
      { kind = "next-intl", path = root .. "/messages/../messages" },
      { kind = "i18next", path = root .. "/locales" },
    })

    assert.are.equal("i18next", roots[1].kind)
    assert.are.equal("next-intl", roots[2].kind)
    assert.are.equal(uv.fs_realpath(root .. "/messages") or (root .. "/messages"), roots[2].path)
  end)

  it("collects i18next and next-intl resource files", function()
    local root = helpers.tmpdir()
    write(root .. "/locales/ja/common.json", '{"title":"ja"}')
    write(root .. "/messages/en.json", '{"common":{"title":"en"}}')
    write(root .. "/messages/en/common.json", '{"title":"fallback"}')

    local files = resource_roots.collect_resource_files({
      { kind = "i18next", path = root .. "/locales" },
      { kind = "next-intl", path = root .. "/messages" },
    })

    assert.are.same({
      uv.fs_realpath(root .. "/locales/ja/common.json"),
      uv.fs_realpath(root .. "/messages/en.json"),
      uv.fs_realpath(root .. "/messages/en/common.json"),
    }, files)
  end)

  it("detects next-intl root files and namespace files", function()
    local root = helpers.tmpdir()
    local roots = {
      { kind = "next-intl", path = root .. "/messages" },
      { kind = "i18next", path = root .. "/locales" },
    }

    local root_info = resource_roots.resource_info_from_roots(roots, root .. "/messages/ja.json")
    local ns_info = resource_roots.resource_info_from_roots(roots, root .. "/locales/en/common.json")

    assert.are.same({
      kind = "next-intl",
      root = root .. "/messages",
      lang = "ja",
      namespace = nil,
      is_root = true,
    }, root_info)
    assert.are.same({
      kind = "i18next",
      root = root .. "/locales",
      lang = "en",
      namespace = "common",
      is_root = false,
    }, ns_info)
  end)

  it("computes project root from common ancestor when roots are provided", function()
    local root = helpers.tmpdir()
    write(root .. "/public/locales/ja/common.json", '{"title":"ja"}')
    write(root .. "/messages/en.json", '{"common":{"title":"en"}}')
    vim.fn.mkdir(root .. "/src/app", "p")

    local project_root = resource_roots.project_root(
      root .. "/src/app",
      resource_roots.normalize_roots({
        { kind = "i18next", path = root .. "/public/locales" },
        { kind = "next-intl", path = root .. "/messages" },
      })
    )

    assert.are.equal(uv.fs_realpath(root) or root, project_root)
  end)
end)
