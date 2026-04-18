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
			model      = "claude-opus-4-7",
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

	-- Auto-cancel the AI request if it hasn't settled after this many ms.
	-- Guards against hangs (network stalls, provider freezes). Set to 0 to
	-- disable. The cancel fires on_error("...timed out after Nms") and the
	-- busy spinner clears normally.
	provider_timeout_ms = 120000,  -- 2 minutes

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
