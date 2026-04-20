-- Resolved, read-only config for smart-actions. setup() calls apply();
-- the rest of the plugin calls get().

local M = {}

local defaults = {
	-- "ask" | "auto" | "line" | "function" | "file" | "folder" | "project" | "visual"
	default_scope = "ask",

	-- nil = auto-detect (walks probe_order, or registration order).
	-- Set to a registered provider id to force.
	provider = nil,

	-- Probe order when provider is nil. nil = registration order, which is
	-- claude_code → anthropic → any externally-registered providers.
	probe_order = nil,

	-- Per-provider opts. Arbitrary table; each provider reads its own slot
	-- via req.opts (populated by providers.stream). Third-party providers
	-- add their own keys here.
	provider_config = {
		claude_code = {
			extra_args = {},       -- appended to `claude -p ...`
		},
		anthropic = {
			-- Sonnet 4.6 is the code-actions sweet spot: roughly half the
			-- latency of Opus 4.7 at near-identical quality on scope-bounded
			-- code edits. Override to "claude-opus-4-7" for judgment-heavy
			-- work (multi-step refactor, cross-file review) if Sonnet
			-- returns underpowered suggestions.
			model      = "claude-sonnet-4-6",
			max_tokens = 4096,
		},
	},

	categories = { "quickfix" },

	-- Project-knowledge layer. Built-ins self-register at setup():
	--   claude_md  agents_md  cursorrules  neovim_plugin  language_default
	-- Third-party providers add via require("smart_actions.context").register(...).
	context = {
		enabled   = true,
		max_chars = 4000,  -- budget across all providers; lower-priority truncated first
		allowlist = nil,   -- nil = all matching; or { "claude_md", "noethervim" }
		denylist  = nil,   -- e.g. { "language_default" } to mute one
	},

	include_diagnostics = true,
	max_payload_chars   = 6000,    -- hard cap on a scope's text payload
	max_files           = 2000,    -- hard cap on enumeration for folder/project
	max_file_bytes      = 200000,  -- per-file read cap (~200 KB)

	-- Upper bound on how long folder/project scope will block nvim while
	-- enumerating files via `rg --files`. Enumeration streams stdout and
	-- early-exits once it has `max_files` paths; this cap protects against
	-- pathological repos (cold fs cache, NFS, million-file monorepos).
	-- On timeout or cap-hit, the rg process is killed and scope.files_omitted
	-- becomes -1 (meaning "unknown, there may be more").
	file_scan_timeout_ms = 500,

	-- Auto-cancel the AI request if it hasn't settled after this many ms.
	-- Guards against hangs (network stalls, provider freezes). Set to 0 to
	-- disable. The cancel fires on_error("...timed out after Nms") and the
	-- busy spinner clears normally.
	provider_timeout_ms = 120000,  -- 2 minutes

	-- When true, the moment an explain stream finishes, quickfix starts in
	-- the background while the user is still reading. If the user presses
	-- a/<CR> in the explain float, actions are (or soon will be) ready;
	-- if they press q/<Esc>, the in-flight quickfix is cancelled.
	-- Trade-off: doubles token cost whenever the user dismisses BEFORE
	-- the background quickfix completes. Leave false unless you frequently
	-- explain→fix and want to hide the latency.
	eager_action_after_explain = false,

	keymap = "grA", -- set false to skip the default binding
}

local current = vim.deepcopy(defaults)

function M.apply(opts)
	current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
	return current
end

function M.defaults()
	return vim.deepcopy(defaults)
end

return M
