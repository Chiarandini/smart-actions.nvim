# smart-actions.nvim

AI-suggested code actions for Neovim. Complements (does not replace) the stock LSP code-action flow on `gra`.

Three entry points:

- **`grA`** — quickfix actions (bug fixes, edge-case hardening). Pick from an inline-diff picker.
- **`grE`** (`:SmartActionExplain`) — prose explanation of a diagnostic / tricky code, streamed into a floating window. Pivot to quickfix with `a`/`<CR>`.
- **`grS`** (`:SmartActionSuppress`) — language-appropriate suppression-comment actions for LSP diagnostics (pyright-ignore, ts-expect-error, allow, noqa, etc.) without modifying logic.
- **`grR`** (`:SmartActionRefactor`) — behaviour-preserving refactors (extract, inline, simplify, replace-mutation-with-functional). Explicitly not a bug-fix or styling category.
- **`grT`** (`:SmartActionTests`) — generate ONE test for the function under cursor, framework auto-detected (pytest / vitest / `#[test]` / Go testing / plenary). Currently appends to the current file (multi-file test-file placement is a deferred v2.x feature).
- **`grV`** (`:SmartActionReview`) — broad review with `[blocker]` / `[suggestion]` / `[nit]` / `[question]` severity tags. Items may be fixes (have a diff, apply normally) or observations (rationale-only, surface as a notification).

All three share the same scope picker (line / function / file / folder / project / auto / visual), the same provider layer (Claude Code CLI → Anthropic API auto-fallback), and the same pluggable context system.

## Status

v0.8.0. Categories shipped: `quickfix`, `explain`, `suppress`, `refactor`, `tests`, `review`. Providers shipped: `claude_code` (CLI), `anthropic` (API). Default `anthropic` model is `claude-sonnet-4-6` (roughly half the latency of Opus at near-identical quality on scope-bounded edits); override with `provider_config.anthropic.model`. Quickfix prompt now splits cursor-line diagnostics into an "AT cursor column" tier ahead of the rest-of-line tier so the AI targets the one you're pointing at first. Folder/project enumeration streams through `vim.system` (`file_scan_timeout_ms`, default 500ms). Additional providers (OpenAI, Ollama) remain planned.

## Install

```lua
{
  "Chiarandini/smart-actions.nvim",
  keys = {
    { "grA", mode = { "n", "x" }, desc = "smart code [A]ction" },
    { "grE", function() require("smart_actions").explain()  end, desc = "smart action: [E]xplain" },
    { "grS", function() require("smart_actions").suppress() end, desc = "smart action: [S]uppress diagnostic" },
    { "grR", function() require("smart_actions").refactor() end, desc = "smart action: [R]efactor" },
    { "grT", function() require("smart_actions").tests()    end, desc = "smart action: generate [T]est" },
    { "grV", function() require("smart_actions").review()   end, desc = "smart action: re[V]iew" },
  },
  cmd = {
    "SmartAction", "SmartActionCancel", "SmartActionLastDiff",
    "SmartActionExplain", "SmartActionSuppress", "SmartActionRefactor",
    "SmartActionTests", "SmartActionReview",
  },
  opts = {
    default_scope = "ask",       -- or "auto" / "line" / "function" / ...
    categories    = { "quickfix" },
    -- eager_action_after_explain = true,  -- opt-in: pre-warm quickfix while you read the explanation
  },
  config = function(_, opts) require("smart_actions").setup(opts) end,
}
```

## Requires

One of:
- `claude` CLI on `$PATH` (Claude Code), **or**
- `ANTHROPIC_API_KEY` in env or `lua/secrets.lua` as `{ anthropic = { api_key = "..." } }`.

Optional but recommended:
- [`snacks.nvim`](https://github.com/folke/snacks.nvim) — the results picker uses Snacks's built-in `diff` previewer so the unified diff renders inline next to the action list. Without snacks, the plugin falls back to `vim.ui.select` (flat menu; no inline preview).
- [`delta`](https://github.com/dandavison/delta) on `$PATH` — if present, Snacks's diff previewer uses it for colored, side-by-side diff rendering.

### Model

Default model for the `anthropic` provider is `claude-sonnet-4-6` — the code-actions sweet spot (roughly half the latency of Opus at near-identical quality on scope-bounded edits). Override for judgment-heavy work:

```lua
opts = {
  provider_config = {
    anthropic = { model = "claude-opus-4-7" },  -- or a Haiku id for speed
  },
}
```

The `claude_code` provider uses whatever model Claude Code itself is configured with — set it via the CLI's `/model` command or your Claude Code config.

## UX

### Quickfix (`grA`)

Scope picker (if `default_scope = "ask"`) → AI streams → results picker opens with all actions, inline diff preview in the side pane:

- `<CR>` applies the highlighted action's diff (or all Tab-selected actions — see below).
- `<Tab>` / `<S-Tab>` toggle-select actions for multi-apply. Selected actions apply sequentially with a single undo unit; any whose context can't land on the mutated buffer is silently skipped and reported ("N of M applied, K skipped").
- `<C-e>` opens the diff in a scratch buffer for hand-editing; `:w` applies the (possibly edited) patch, `:q!` cancels. Always targets the hovered action, even if others are Tab-selected.
- `<Esc>` dismisses without applying.

Every apply is a single undo unit — `u` reverts the full action cleanly (including multi-select bundles). The applier is *anchor-by-context*: if the AI's hunk header is slightly off, hunks relocate to where the body's context lines actually match the buffer (like `git apply`), so minor drift doesn't corrupt the edit.

### Explain (`grE`)

Streams a prose explanation into a bordered floating window — useful when an LSP diagnostic is cryptic or a piece of code looks wrong but you're not sure why. In the float:

- `a` / `<CR>` — close and pivot to quickfix on the same scope (*"OK, now fix it"*).
- `q` / `<Esc>` — dismiss without further action.

The active keybindings are shown in the float's bottom border so they don't need to be memorised.

### Suppress (`grS`)

### Refactor (`grR`)

Same picker UX as quickfix, but each action is a behaviour-preserving refactor — extract a helper, inline a variable, simplify a conditional, replace a mutation loop with a functional expression. Explicitly forbidden from this category: bug fixes (use `grA`), stylistic tweaks, renames, comments. Returns nothing when the scope has no clear refactor opportunity.

### Tests (`grT`)

Generates ONE test for the function or method closest to the cursor, framework auto-detected from the file extension + existing imports:

- Python: `def test_xxx():` + `assert`
- TypeScript / JavaScript: vitest or jest (`describe` / `it` / `expect`)
- Rust: `#[test]` inside `#[cfg(test)] mod tests {}`
- Go: `func TestXxx(t *testing.T)` (only if the file is a `_test.go`)
- Lua: plenary `describe` / `it` if present, else `assert(...)` block

The test is appended to the current file (scope is forced to `file`). Multi-file placement — creating or extending a separate `tests/test_foo.py`-style file — is a deferred v2.x feature; in the meantime you can move the generated test by hand.

### Review (`grV`)

Broad feedback, explicitly opted-in. Each item carries a severity tag: `[blocker]` / `[suggestion]` / `[nit]` / `[question]`. Items may be either:

- **Fixes** — have a unified_diff, apply normally via `<CR>` like any other category.
- **Observations** — rationale-only (empty diff). The picker renders their rationale as markdown in the preview pane; hitting `<CR>` surfaces the rationale as a notification rather than trying to apply nothing.

Use this when you want opinions that `grA` / `grR` deliberately leave out (style, naming, design judgement, clarifying questions).

### Suppress (`grS`)

Same picker UX as quickfix, but each action is a language-appropriate suppression comment rather than a code fix. No logic is modified. Supports:

- Python: `# pyright: ignore[...]`, `# type: ignore`, `# noqa`
- TypeScript / JavaScript: `// @ts-expect-error`, `// eslint-disable-next-line`
- Rust: `#[allow(...)]`
- Go: `//nolint:...`
- Shell: `# shellcheck disable=...`
- Lua: `---@diagnostic disable-next-line: ...`

Returns nothing when there are no LSP diagnostics to suppress.

### Eager action after explain (opt-in)

When `eager_action_after_explain = true` in setup, the quickfix category starts streaming in the background the moment an explain stream finishes. If you press `a`/`<CR>` in the float, the picker opens (near-)instantly — the read time has hidden the latency. If you press `q`/`<Esc>`, the in-flight quickfix is cancelled. Trade-off: roughly doubles token cost on any explain that's dismissed before the background quickfix completes. Default off.

## Adding your own provider

Providers are pluggable from day one. Register a new one from anywhere after `setup()`:

```lua
require("smart_actions.providers").register({
  id = "ollama",
  display_name = "Ollama (local)",
  probe = function()
    return vim.fn.executable("ollama") == 1
  end,
  stream = function(req, cb)
    -- req:  { system, messages, stop, cancel_token, opts }
    --   opts = config.provider_config.ollama or {}
    -- cb:   { on_text(chunk), on_done(), on_error(err) }
    -- return: a cancel function
  end,
})

-- Then in setup():
require("smart_actions").setup({
  probe_order = { "ollama", "claude_code", "anthropic" },
  provider_config = { ollama = { model = "codellama" } },
})
```

## Adding your own context

Context providers inject **project knowledge** (rules, idioms, conventions) into the system prompt ahead of every request. Five built-ins self-register at setup: `claude_md`, `agents_md`, `cursorrules`, `neovim_plugin`, `language_default`. You add your own with `register()`:

```lua
-- Tiny: always-on personal style
require("smart_actions.context").register({
  id = "my_style", priority = 150,
  detect = function(_) return true end,
  gather = function(_) return "Use 2-space indents. Prefer explicit returns." end,
})

-- Medium: framework / project detection
require("smart_actions.context").register({
  id = "rust_workspace", priority = 120,
  detect = function(root)
    return vim.uv.fs_stat(root .. "/Cargo.toml") ~= nil
  end,
  gather = function(_)
    return "Rust workspace. Prefer `?` for error propagation. No panics in lib code."
  end,
})

-- Rich: pull content from disk
require("smart_actions.context").register({
  id = "contributing", priority = 95,
  detect = function(root)
    return vim.uv.fs_stat(root .. "/CONTRIBUTING.md") ~= nil
  end,
  gather = function(scope)
    local root = require("smart_actions.util").project_root(scope.trigger.file)
    local f = io.open(root .. "/CONTRIBUTING.md", "r")
    if not f then return "" end
    local content = f:read("*a"); f:close()
    return "--- CONTRIBUTING.md ---\n" .. content
  end,
})
```

**Contract:**
- `id` — unique string, used for budget bookkeeping and `handles_natively` filtering
- `priority` — higher wins when the `max_chars` budget is tight (default 0)
- `detect(root)` — cheap boolean, called once per `grA`
- `gather(scope)` — returns the context block text; `""` means "skip"

**Config knobs** (all optional):

```lua
context = {
  enabled   = true,
  max_chars = 4000,              -- total budget; low-priority dropped first
  allowlist = { "claude_md" },   -- nil = all matching
  denylist  = { "language_default" },
}
```

**Inspect what the AI sees:**

```vim
:lua =require("smart_actions.context").assemble(
        require("smart_actions.scope").get("function"),
        require("smart_actions.providers").active())
```

**Provider / context coordination:** if your AI provider already consumes a context source natively (e.g. Claude Code auto-reads `CLAUDE.md`), list the context id in the provider's `handles_natively` field — the assembler will skip it for that provider only.

## Testing

Two suites under `tests/`:

- **`diff_spec.lua`** — fast, offline unit tests for the unified-diff parser & applier. Includes the malformed-header regression (AI header claims `old=8` but body has 7, applier trusts the body).

  ```sh
  NVIM_APPNAME=noethervim nvim --headless \
    --cmd 'set rtp+=~/programming/custom_plugins/smart-actions.nvim' \
    -c 'luafile tests/diff_spec.lua' -c 'qa!'
  ```

- **`e2e_spec.lua`** — end-to-end: each test opens a deliberately-buggy fixture, runs the full pipeline (scope → context → category → real Claude Code stream → apply), and asserts shape properties (action count, apply succeeds within scope bounds, bug gone after apply, edit distance from cursor). Gated by `SA_E2E=1`. Covers all 7 scopes (`line` / `function` / `file` / `folder` / `project` / `visual` / `auto`), five languages (Python, Lua, Rust, Go, TypeScript; LaTeX if your env permits), the quickfix / explain / suppress categories, multi-hunk, syntax-broken input, and dirty-buffer apply.

  ```sh
  ./tests/run-e2e.sh                   # ~15 cases, ~90s total
  ```

- **`variance.lua`** — an N-run harness for measuring AI variance on a fixed fixture. Reports deletions/additions/max-distance-from-cursor per run so you can see if a prompt tweak is narrowing or widening the AI's output.

  ```sh
  SA_RUNS=10 ./tests/run-variance.sh
  ```

## Docs

`:help smart-actions` — full vimdoc, including context & provider extension points.
