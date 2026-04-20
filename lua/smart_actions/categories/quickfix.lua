-- quickfix category.
--
-- Two prompt modes, chosen by scope shape:
--   - "cursor" (default): the user is pointing at something and wants it
--     fixed. Rules bias hard toward the trigger line; cap of 3 actions.
--     Triggered by any non-visual scope (line/function/file/folder/project).
--   - "region": the user made a visual selection and wants every bug in it
--     fixed. No cursor-proximity bias; dynamic cap scales with diagnostic
--     count up to config.quickfix_region_max_actions.
--
-- Output format for both modes: one complete JSON object per line
-- (NDJSON-ish; the streaming parser tolerates fences / pretty-printing /
-- non-JSON preamble). Each emitted Action:
--   { category, title, description, diff, kind }

local stream_json = require("smart_actions.stream_json")

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT_CURSOR = [[You are a code-fix assistant embedded in a Neovim plugin.

You are given:
  - a scope of code (the "=== CODE ===" block below)
  - trigger metadata (where in the file the user invoked the action)
  - any LSP diagnostics overlapping the cursor line
  - optional <project_context> rules earlier in this system prompt

Return AT MOST 3 distinct bug fixes or edge-case hardenings for the given
scope, ranked by relevance to the trigger line and the symbol under cursor.

Ranking rules (strict, in priority order):
  1. If an LSP diagnostic overlaps the trigger line, you MUST return at
     least one action addressing it. The FIRST action MUST target that
     diagnostic. When multiple diagnostics exist, target them in the
     order they appear in the prompt: the "Diagnostic AT cursor column"
     section takes priority over "Other diagnostics on cursor line",
     which in turn takes priority over "Other diagnostics in this scope".
     "No actions" is NOT an option while any diagnostic exists in the
     scope — if the only sensible fix is "delete the line", emit that as
     an action rather than returning nothing.
  2. Otherwise, the FIRST action MUST address the most obvious bug on the
     trigger line or at the cursor's immediate vicinity (the symbol under
     cursor, the enclosing statement).
  3. Subsequent actions must still be real bugs or edge cases affecting
     code VERY near the cursor. Do NOT include suggestions far from the
     cursor just because they look wrong — that's clutter, not value.
  4. If neither the trigger line nor its immediate vicinity contains a
     plausible bug AND no LSP diagnostic overlaps the scope, you may
     return AT MOST ONE action addressing the nearest real bug in the
     scope. Prefix its rationale with "(distant from cursor)".
  5. If there are no LSP diagnostics AND no plausible bug anywhere in
     the scope, output NOTHING. One good suggestion beats three noisy ones.

Explicitly OUT OF SCOPE for this category (do not emit these as actions):
  - stylistic tweaks, formatting, naming conventions
  - adding or rewriting comments / docstrings
  - refactors that change structure without fixing behavior
  - speculative "defensive" hardening unrelated to a real failure mode
  - changes that don't touch the cursor's immediate vicinity unless
    rule 3 applies

Output ONLY newline-delimited JSON — one complete JSON object per action.
Each object has exactly:

  {
    "title":        "short action title (<=60 chars)",
    "rationale":    "one sentence: why this fix matters",
    "unified_diff": "a unified diff that applies cleanly to the scope"
  }

The unified_diff must:
  - use standard `--- a/<file>` / `+++ b/<file>` headers with the scope's
    file path (relative)
  - include `@@` hunk headers with correct line numbers relative to the scope
  - touch ONLY lines visible in the scope; do not invent surrounding context

Do NOT:
  - wrap the output in markdown code fences (no ```json, no ```)
  - emit any preamble, postamble, or explanation outside the JSON objects
  - invent imports, APIs, or types not visible in the scope]]

local SYSTEM_PROMPT_REGION_TEMPLATE = [[You are a code-fix assistant embedded in a Neovim plugin.

The user has VISUALLY SELECTED a region and wants every real bug in it
fixed. The selection IS the prioritisation signal — ignore cursor
position, ignore proximity heuristics, just fix what's broken.

You are given:
  - the selected code (the "=== CODE ===" block below)
  - any LSP diagnostics overlapping the selection
  - optional <project_context> rules earlier in this system prompt

Return up to %d distinct bug-fix actions (one per distinct concern).

Rules (strict):
  1. Every LSP diagnostic overlapping the selection MUST be addressed
     by at least one action. Collapse two diagnostics into one action
     only when they share the exact same underlying cause (e.g. a
     single typo flagged by two overlapping lints).
  2. You may surface real bugs the LSP didn't flag — off-by-one,
     null-deref, unhandled error, obvious logic error. These count
     toward the cap.
  3. Order actions by severity: LSP errors first, then LSP warnings,
     then non-LSP bugs you spotted, then edge-case hardenings.
  4. Do NOT pad the output with stylistic tweaks, comment edits,
     speculative hardenings, or rename suggestions. If the selection
     is truly clean, return NOTHING.

Output ONLY newline-delimited JSON — one complete JSON object per action.
Each object has exactly:

  {
    "title":        "short action title (<=60 chars)",
    "rationale":    "one sentence: why this fix matters",
    "unified_diff": "a unified diff that applies cleanly to the selection"
  }

The unified_diff must:
  - use standard `--- a/<file>` / `+++ b/<file>` headers with the scope's
    file path (relative)
  - include `@@` hunk headers with correct line numbers relative to the scope
  - touch ONLY lines visible in the scope; do not invent surrounding context

Do NOT:
  - wrap the output in markdown code fences (no ```json, no ```)
  - emit any preamble, postamble, or explanation outside the JSON objects
  - invent imports, APIs, or types not visible in the scope]]

--- Clamp(3, n_diagnostics + 2, ceiling).
--- Cursor mode always returns a fixed 3; region mode scales with diagnostics.
local function region_cap(n_diagnostics, ceiling)
	local c = math.max(3, math.min(ceiling or 10, (n_diagnostics or 0) + 2))
	return c
end

local function fmt_diag(d)
	return string.format("  line %d col %d: [%s] %s (%s)",
		(d.lnum or 0) + 1, (d.col or 0) + 1,
		SEVERITY_NAMES[d.severity] or "?",
		d.message or "",
		d.source or "?")
end

local function diag_key(d)
	return (d.lnum or 0) .. "|" .. (d.col or 0) .. "|"
		.. (d.message or "") .. "|" .. (d.source or "")
end

--- Cursor mode: three tiers (at-col, on-line, elsewhere-in-scope). The
--- AI consumes these as ordered priority buckets.
local function append_cursor_diagnostics(lines, trg, scope)
	local at_col_diag    = trg.diagnostics_at_col  or {}
	local line_only_diag = trg.diagnostics_on_line or {}
	local scope_diag     = scope.diagnostics or {}
	local seen = {}
	for _, d in ipairs(at_col_diag)    do seen[diag_key(d)] = true end
	for _, d in ipairs(line_only_diag) do seen[diag_key(d)] = true end
	local other = {}
	for _, d in ipairs(scope_diag) do
		local k = diag_key(d)
		if not seen[k] then seen[k] = true; other[#other + 1] = d end
	end
	if #at_col_diag > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Diagnostic AT cursor column (highest priority):"
		for _, d in ipairs(at_col_diag) do lines[#lines + 1] = fmt_diag(d) end
	end
	if #line_only_diag > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Other diagnostics on cursor line:"
		for _, d in ipairs(line_only_diag) do lines[#lines + 1] = fmt_diag(d) end
	end
	if #other > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Other diagnostics in this scope:"
		for _, d in ipairs(other) do lines[#lines + 1] = fmt_diag(d) end
	end
end

--- Region mode: single flat section — the cursor is arbitrary inside the
--- selection, so a "AT cursor column" tier would be misleading.
local function append_region_diagnostics(lines, scope)
	local scope_diag = scope.diagnostics or {}
	if #scope_diag == 0 then return end
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("Diagnostics in the selected region (%d):", #scope_diag)
	for _, d in ipairs(scope_diag) do lines[#lines + 1] = fmt_diag(d) end
end

local function build_user_prompt(scope, include_diagnostics, mode)
	local trg = scope.trigger
	local rel = vim.fn.fnamemodify(trg.file, ":.")
	if rel == "" then rel = "[nofile]" end

	local lines = {
		string.format("Scope: %s (%d chars, truncated=%s)",
			scope.label, #(scope.text or ""), tostring(scope.truncated or false)),
		string.format("File: %s", rel),
	}
	if mode == "cursor" then
		lines[#lines + 1] = string.format("Cursor: line %d col %d  symbol=%s",
			trg.cursor.row + 1, trg.cursor.col + 1, trg.symbol or "-")
	end

	if include_diagnostics then
		if mode == "region" then
			append_region_diagnostics(lines, scope)
		else
			append_cursor_diagnostics(lines, trg, scope)
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== CODE ==="
	lines[#lines + 1] = scope.text or ""
	lines[#lines + 1] = "=== END ==="
	return table.concat(lines, "\n")
end

-- Convert a streamed JSON object into an Action record.
local function to_action(obj)
	return {
		category    = "quickfix",
		title       = (obj.title or "(untitled)"):sub(1, 120),
		description = obj.rationale or obj.description or "",
		diff        = obj.unified_diff or obj.diff or "",
		kind        = obj.kind or "quickfix",
		raw         = obj,
	}
end

return {
	id    = "quickfix",
	label = "Quick fix",
	icon  = "",

	--- Build a request + a streaming parser for this category.
	--- Returns: request (table), parser (has :feed(chunk), .actions, :finalize())
	---
	--- `scope.label == "visual"` switches the prompt into region-fix mode:
	--- no cursor-proximity bias, dynamic cap based on diagnostic count (up
	--- to ctx.quickfix_region_max_actions, default 10). Any other scope
	--- keeps the cursor-focused behaviour (fixed cap of 3).
	build = function(scope, ctx)
		ctx = ctx or {}
		local mode = (scope.label == "visual") and "region" or "cursor"
		local system
		if mode == "region" then
			local cap = region_cap(#(scope.diagnostics or {}),
				ctx.quickfix_region_max_actions)
			system = string.format(SYSTEM_PROMPT_REGION_TEMPLATE, cap)
		else
			system = SYSTEM_PROMPT_CURSOR
		end
		local request = {
			system   = system,
			messages = {
				{ role = "user",
				  content = build_user_prompt(scope,
					ctx.include_diagnostics ~= false, mode) },
			},
		}

		local parser_wrap = {}
		parser_wrap.actions = {}
		parser_wrap.on_action = nil   -- caller sets this
		parser_wrap.on_warn   = nil

		local json_parser = stream_json.new({
			on_object = function(obj)
				local action = to_action(obj)
				parser_wrap.actions[#parser_wrap.actions + 1] = action
				if parser_wrap.on_action then parser_wrap.on_action(action) end
			end,
			on_warn = function(msg)
				if parser_wrap.on_warn then parser_wrap.on_warn(msg) end
			end,
		})

		function parser_wrap:feed(chunk)    json_parser:feed(chunk)    end
		function parser_wrap:finalize()     return self.actions         end

		return request, parser_wrap
	end,
}
