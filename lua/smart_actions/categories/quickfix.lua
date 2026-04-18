-- quickfix category — v1.
--
-- Prompts the AI for 1-5 bug / edge-case fixes over the scope payload plus
-- any LSP diagnostics overlapping the cursor line. Output format: one
-- complete JSON object per line (NDJSON-ish; the streaming parser is
-- tolerant of fences, pretty-printing, and non-JSON preamble).
--
-- Each emitted Action: { category, title, description, diff, kind }

local stream_json = require("smart_actions.stream_json")

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT = [[You are a code-fix assistant embedded in a Neovim plugin.

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
     diagnostic. "No actions" is NOT an option while any diagnostic exists
     in the scope — if the only sensible fix is "delete the line", emit
     that as an action rather than returning nothing.
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

local function build_user_prompt(scope, include_diagnostics)
	local trg = scope.trigger
	local rel = vim.fn.fnamemodify(trg.file, ":.")
	if rel == "" then rel = "[nofile]" end

	local lines = {
		string.format("Scope: %s (%d chars, truncated=%s)",
			scope.label, #(scope.text or ""), tostring(scope.truncated or false)),
		string.format("File: %s", rel),
		string.format("Cursor: line %d col %d  symbol=%s",
			trg.cursor.row + 1, trg.cursor.col + 1, trg.symbol or "-"),
	}

	if include_diagnostics then
		local fmt = function(d)
			return string.format("  line %d: [%s] %s (%s)",
				(d.lnum or 0) + 1,
				SEVERITY_NAMES[d.severity] or "?",
				d.message or "",
				d.source or "?")
		end

		local trigger_diag = trg.diagnostics or {}
		local scope_diag   = scope.diagnostics or {}

		-- Dedup: "other diagnostics" = scope set minus trigger set,
		-- keyed by (lnum, message, source).
		local seen = {}
		for _, d in ipairs(trigger_diag) do
			seen[(d.lnum or 0) .. "|" .. (d.message or "") .. "|" .. (d.source or "")] = true
		end
		local other = {}
		for _, d in ipairs(scope_diag) do
			local k = (d.lnum or 0) .. "|" .. (d.message or "") .. "|" .. (d.source or "")
			if not seen[k] then
				seen[k] = true
				other[#other + 1] = d
			end
		end

		if #trigger_diag > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Diagnostic at cursor:"
			for _, d in ipairs(trigger_diag) do lines[#lines + 1] = fmt(d) end
		end
		if #other > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Other diagnostics in this scope:"
			for _, d in ipairs(other) do lines[#lines + 1] = fmt(d) end
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
	build = function(scope, ctx)
		ctx = ctx or {}
		local request = {
			system   = SYSTEM_PROMPT,
			messages = {
				{ role = "user", content = build_user_prompt(scope, ctx.include_diagnostics ~= false) },
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
