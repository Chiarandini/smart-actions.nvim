# smart-actions.nvim

AI-suggested code actions for Neovim, bound to `grA`. Complements (does not replace) the stock LSP code-action flow on `gra`.

## Status

v1 in development. The `quickfix` category and the Claude Code CLI provider land first; other categories (refactor, docs, explain, tests, transform) and providers (OpenAI, Ollama, etc.) are planned.

## Install

**lazy.nvim (local dev):**

```lua
{
  "smart-actions.nvim",
  dir = vim.fn.expand("~/programming/custom_plugins/smart-actions.nvim"),
  keys = { { "grA", mode = { "n", "x" }, desc = "smart code [A]ction" } },
  cmd = { "SmartAction", "SmartActionCancel" },
  opts = {
    default_scope = "ask",
    categories = { "quickfix" },
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

## UX

`grA` → scope picker (if `default_scope = "ask"`) → AI streams → results picker opens with all actions:

- `<CR>` applies the highlighted action's diff.
- `e` opens the diff in a scratch buffer for hand-editing; `:w` applies, `:q!` cancels.
- `<Esc>` dismisses without applying.

Every apply is a single undo unit — `u` reverts the full action.

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

- **`e2e_spec.lua`** — end-to-end: each test opens a deliberately-buggy fixture, runs the full pipeline (scope → context → quickfix → real Claude Code stream → apply), and asserts shape properties (action count, apply succeeds within scope bounds, bug gone from buffer after apply, edit distance from cursor). Gated by `SA_E2E=1`. Covers `line`, `function`, `file`, `visual`, and `auto` scopes.

  ```sh
  ./tests/run-e2e.sh                   # 5 cases, ~30s total
  ```

- **`variance.lua`** — an N-run harness for measuring AI variance on a fixed fixture. Reports deletions/additions/max-distance-from-cursor per run so you can see if a prompt tweak is narrowing or widening the AI's output.

  ```sh
  SA_RUNS=10 ./tests/run-variance.sh
  ```

## Docs

`:help smart-actions` — full vimdoc, including context & provider extension points.
