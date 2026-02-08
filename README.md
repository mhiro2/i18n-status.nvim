# 🌐 i18n-status.nvim

[![GitHub Release](https://img.shields.io/github/release/mhiro2/i18n-status.nvim?style=flat)](https://github.com/mhiro2/i18n-status.nvim/releases/latest)
[![CI](https://github.com/mhiro2/i18n-status.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/mhiro2/i18n-status.nvim/actions/workflows/ci.yaml)

**Inline-first i18n status & review tooling for Neovim**
for **i18next / next-intl** projects

Stop guessing whether `t("login.title")` is safe.
See **i18n health inline**, inspect details on demand, and run safe edits.

## 👀 What you see (inline = status, not display)

```ts
t("login.title"): Login              [=]
t("login.description"): Welcome back [≠]
t("login.button"): Login             [?]
t("login.error"): {count} errors     [!]
t("signup.title"):                   [×]
```

| Marker | Meaning | When shown |
| ------ | ------- | ---------- |
| `[=]`  | All languages same | All languages exist and have identical values (may need translation) |
| `[≠]`  | Localized | All languages exist but values differ |
| `[?]`  | Fallback is used | Missing in some languages (but primary exists) |
| `[×]`  | Missing in primary | Primary language value is missing |
| `[!]`  | Placeholder mismatch | Placeholders differ between languages |

**Priority**: `×` > `!` > `?` > `≠` > `=`

Examples:
- `[=]`: `en: "Login"`, `ja: "Login"` (identical values - check if translated)
- `[≠]`: `en: "Welcome back"`, `ja: "おかえりなさい"` (both exist, localized values)
- `[?]`: `en: "Login"`, `ja: missing` (primary exists, other missing)
- `[×]`: `en: missing`, `ja: "サインアップ"` (primary missing)
- `[!]`: `en: "{count} items"`, `ja: "{name} 件"` (different placeholders)

## 🎬 Demo

### Inline status (hover)

<img src="https://github.com/user-attachments/assets/32691d2b-bfb6-4615-9105-e2b88fa86a26" width="100%" alt="Inline status hover (5 types)" />

### Inline key translation + :I18nLang

<img src="https://github.com/user-attachments/assets/8c0c5bae-7f52-486c-848f-bc00ba046b32" width="100%" alt="Inline key translation and I18nLang switch" />

### blink.cmp integration

<img src="https://github.com/user-attachments/assets/95c003e7-58b8-4c1d-8fc5-763c03d8b4d8" width="100%" alt="blink.cmp completion with i18n-status" />

### Review / Doctor

<img src="https://github.com/user-attachments/assets/33ad6a20-9dda-4f56-867e-6346d9f9d649" width="100%" alt="Review / Doctor UI" />

## ✨ Features

- ✅ **Inline status**: Lightweight extmarks, quiet by design.
- 🗂️ **Translation file inline**: When you open a resource JSON file, show another language inline (controlled by `:I18nLang`).
- 💬 **Hover details**: Values for all languages + reason + file path (git-relative when possible).
- 🔁 **Language cycling**: yankround-style next/prev + "back to previous".
- 🎯 **Inline goto definition (opt-in)**: Map any keys (e.g. `gd`) to jump straight to the translation file under the cursor.
- 🩺 **Doctor + Review**: Diagnose project-wide issues and review/fix them in a two-pane floating UI where the left list drives every action and the right side stays as a live preview.
- ⚡ **Completion**: blink.cmp source (first argument only), missing-first sorting.
- 🔄 **Auto reload**: Translation file changes update inline quickly (watcher + cache).

## 🧰 Requirements

- **Neovim**: >= 0.10
- **Tree-sitter**: `javascript`, `typescript`, `jsx`, `tsx` parsers installed (plus `json` for translation files)
- **Completion (optional)**: [`saghen/blink.cmp`](https://github.com/saghen/blink.cmp) (only supported completion engine)

## 🚀 Installation (lazy.nvim)

Set up the plugin with minimal options, then configure language-cycling helpers and custom keymaps.

```lua
{
  "mhiro2/i18n-status.nvim",
  config = function()
    local i18n_status = require("i18n-status")
    i18n_status.setup({
      -- Source-of-truth language (used for inline rendering + doctor comparisons).
      primary_lang = "en",

      auto_hover = {
        enabled = true, -- auto-show hover on cursor hold (default: true)
      },

      inline = {
        -- Controls how inline virtual text is displayed. (JSON files always use "eol")
        position = "eol", -- set to "after_key" to draw text directly after the key
      },
    })
  end,
}
```

```lua
-- Example keymaps:
vim.keymap.set("n", "<leader>in", "<Cmd>I18nLangNext<CR>", { desc = "Next language" })
vim.keymap.set("n", "<leader>ip", "<Cmd>I18nLangPrev<CR>", { desc = "Previous language" })
vim.keymap.set("n", "<leader>id", "<Cmd>I18nDoctor<CR>", { desc = "i18n doctor" })
vim.keymap.set("n", "<leader>ia", "<Cmd>I18nAddKey<CR>", { desc = "Add new i18n key" })

-- Inline goto-definition is opt-in. Configure it per-buffer so LSP mappings don't override it.
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local bufnr = args.buf
    vim.keymap.set("n", "gd", function()
      if not require("i18n-status").goto_definition(bufnr) then
        vim.lsp.buf.definition()
      end
    end, { buffer = bufnr, desc = "i18n-status: goto translation or LSP definition" })
  end,
})
```

### Options (overview)

- **`primary_lang`** *(string)*: Primary language used to render inline text.
- **`resource_watch.enabled`** *(boolean)*: Watch translation files and auto-refresh. Default: `true`.
- **`resource_watch.debounce_ms`** *(integer)*: Debounce for watcher refresh. Default: `200`.
- **`doctor.ignore_keys`** *(string[])*: Patterns to ignore keys in doctor. Default: `{}`.
- **`doctor.float.width`** *(number)*: Width of Doctor UI floating window (0.0-1.0). Default: `0.8`.
- **`doctor.float.height`** *(number)*: Height of Doctor UI floating window (0.0-1.0). Default: `0.8`.
- **`doctor.float.border`** *(string)*: Border style for Doctor UI. Default: `"rounded"`. Options: `"none"`, `"single"`, `"double"`, `"rounded"`, `"solid"`, `"shadow"`.
- **`auto_hover.enabled`** *(boolean)*: Automatically show hover when cursor stops on i18n key. Default: `true`. Uses `vim.opt.updatetime` for delay (default 4000ms). Set to `false` to disable.
- **`extract.min_length`** *(integer)*: Minimum text length to consider for `:I18nExtract`. Default: `2`.
- **`extract.exclude_components`** *(string[])*: JSX component names to skip during extraction. Default: `{ "Trans", "Translation" }`.

Resource roots are auto-detected from the current buffer's directory.
Namespace is inferred from `useTranslation(s)/getTranslations` or explicit `ns:key`.
If none is found, a best-effort fallback is used and `:checkhealth` will warn.

Inline:

- **`inline.position`**: `"eol"` or `"after_key"`. Default: `"eol"`.
- **`inline.max_len`**: Max inline text length. Default: `80`.
- **`inline.visible_only`**: Render + scan/resolve only the visible range for better performance. Default: `true`.
- **`inline.status_only`**: Show only status marker (e.g. `[=]`) without translation text. Default: `false`.
- **`inline.debounce_ms`**: Debounce for refresh on edits. Default: `80`.
- **`inline.hl`**: Override highlight groups (see below).

## ⌨️ Commands

### Core

- **`:I18nHover`**: Hover details for the i18n key under cursor
- **`:I18nDoctor`**: Diagnose i18n issues across the entire project and open Review UI
- **`:I18nDoctorCancel`**: Cancel a running doctor scan
- **`:I18nAddKey`**: Add a new i18n key to all language files interactively
- **`:I18nExtract`**: Detect and extract hardcoded JSX text in current buffer (supports `:'<,'>I18nExtract`)
- **`:I18nRefresh`**: Force refresh current buffer

### Language

- **`:I18nLang {lang}`**: Set language explicitly (warns if `{lang}` isn't part of the detected languages)
- **`:I18nLangNext`** / **`:I18nLangPrev`**: Cycle languages

## ✅ Health check

Run `:checkhealth i18n-status` to verify configuration, resource discovery, Treesitter parsers, and blink.cmp integration.

## 🩺 Doctor

Run `:I18nDoctor` to diagnose i18n issues across the entire project and open Review UI.

> [!WARNING]
> `:I18nDoctor` scans project files and can be slow on large codebases.
> It is only run when you explicitly invoke it.

### Review UI

Doctor opens a floating window with two panes (left: key list, right: color-coded preview).

You can switch between two modes:

- **Problems**: issue-only view (fast, includes missing/mismatch/unused/drift issues)
- **Overview**: full key list (includes same/≠ status; heavier)

In **Overview**, `=` means the value matches the primary language, and `≠` means the value is localized (differs from the primary language; informational only).

**Keymaps:**

- **`q`** / **`<Esc>`**: Close
- **`Tab`**: Toggle Problems/Overview
- **`e`**: Edit display locale value
- **`E`**: Select locale to edit
- **`r`**: Rename key (updates resources + open buffers)
- **`a`**: Add missing key (only for missing primary keys)
- **`gd`**: Jump to definition file (Overview: open resource file)
- **`?`**: Toggle keymap help overlay

> [!TIP]
> The list pane statusline mirrors the most common shortcuts so you can glance without opening the help overlay.

**Review highlight groups:**

- Layout: `I18nStatusReviewListNormal`, `I18nStatusReviewListCursorLine`, `I18nStatusReviewDetailNormal`, `I18nStatusReviewBorder`
- Text: `I18nStatusReviewHeader`, `I18nStatusReviewDivider`, `I18nStatusReviewMeta`, `I18nStatusReviewKey`, `I18nStatusReviewTableHeader`
- Status colors: `I18nStatusReviewStatusOk`, `...Missing`, `...Fallback`, `...Localized`, `...Mismatch`, `...Primary`, `...Focus`, `...StatusDefault`

All groups are created with `default=true` and linked to Telescope/Diagnostic groups, so you can override them via `:highlight` if you prefer custom colors.

### Issue types

| Type | Meaning |
| --- | --- |
| `missing` | key is missing in the primary language |
| `mismatch` | placeholder mismatch between languages |
| `unused` | key exists in resources but is not referenced |
| `drift` | key differs across languages (missing/extra) |
| `resource errors` | invalid JSON or read errors |
| `roots missing` | no resource root found (`locales/`, `public/locales/`, or `messages/`) |


## ⚡ Completion (blink.cmp)

Manual setup (recommended):

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "buffer", "i18n_status" },
    providers = {
      i18n_status = { name = "i18n-status", module = "i18n-status.blink" },
    },
  },
})
```

> [!NOTE]
>  - Only completes the **first argument** of `t("...")` / `something.t("...")`.
> - Namespace is inferred from `useTranslation("ns")` / `useTranslations("ns")` / `getTranslations("ns")` scopes.

## 🎨 Highlights

Default links (created with `default=true`):

- `I18nStatusSame` -> `DiagnosticHint`
- `I18nStatusDiff` -> `DiagnosticOk`
- `I18nStatusFallback` -> `DiagnosticWarn`
- `I18nStatusMissing` -> `DiagnosticError`
- `I18nStatusMismatch` -> `DiagnosticError`

Override example:

```lua
require("i18n-status").setup({
  inline = {
    hl = {
      text = "Comment",
      same = "I18nStatusSame",
      diff = "I18nStatusDiff",
      fallback = "I18nStatusFallback",
      missing = "I18nStatusMissing",
      mismatch = "I18nStatusMismatch",
    },
  },
})
```

## 📁 Supported resource layouts

### i18next

- `locales/{lang}/{namespace}.json`
- `public/locales/{lang}/{namespace}.json`

### next-intl

- `messages/{lang}.json` (root file)
- `messages/{lang}/{namespace}.json` (namespace file)

> [!NOTE]
> When both `messages/{lang}.json` (root file) and `messages/{lang}/{namespace}.json` exist, the root file is prioritized. Actions like "Add missing" and "Extract" will write to the root file in this case.

## 🧩 Dynamic i18n key support (limited)

Supported:

- String literals
- Literal concatenation (e.g. `"a" + "b"`)
- Template literals without `${}` (e.g. `` `a.b` ``)
- `const` string references in the same scope

Not supported (initially):

- Runtime-dependent values
- Expressions with function calls
- Any runtime evaluation

## 📄 License

MIT License. See [LICENSE](./LICENSE).
