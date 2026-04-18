-- refactor category — v2.
--
-- Prompts the AI for 1-3 behaviour-preserving refactors (extract, inline,
-- simplify, replace-mutation-with-functional, etc.) over the scope. NOT
-- a bug-fix category (that's `quickfix`), NOT a stylistic one (nothing
-- ever is — we explicitly forbid cosmetic edits).
--
-- Emitted Action shape: { category, title, description, diff, kind = "refactor" }

local stream_json = require("smart_actions.stream_json")

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT = [[You are a refactor assistant embedded in a Neovim plugin.

You are given:
  - a scope of code (the "=== CODE ===" block below)
  - trigger metadata (where the cursor is)
  - any LSP diagnostics overlapping the trigger line
  - optional <project_context> rules earlier in this system prompt

Return AT MOST 3 refactor actions that improve structure or clarity
WITHOUT changing observable behaviour.

Valid refactors include:
  - Extract repeated or complex logic into a helper function
  - Inline a variable that's used exactly once
  - Simplify a nested conditional into an early return
  - Replace a mutation loop with a functional expression (map/filter/
    reduce or comprehension equivalent in the target language)
  - Split a large function along a clear seam
  - Collapse redundant or symmetric branches
  - Replace a hand-rolled pattern with a standard library equivalent
    that is already in use elsewhere in the scope

Explicitly OUT OF SCOPE for this category (do NOT emit):
  - Pure style / formatting / renaming changes
  - Bug fixes — emit in `quickfix` instead
  - Added comments or documentation — belongs in `docs` (future)
  - Suppression comments — belongs in `suppress`
  - ANY change that could alter observable behaviour (exception
    handling, side-effect ordering, public API shape, concurrency
    semantics). If in doubt, do NOT emit the action.

Ranking rules (strict):
  1. The FIRST action MUST touch the trigger line or its immediate
     context (the enclosing statement or expression).
  2. Subsequent actions must still refactor code VERY near the cursor.
  3. If the scope has no clear refactor opportunity, return NOTHING.
     Do NOT invent cosmetic changes to fill the quota.

Output ONLY newline-delimited JSON — one complete JSON object per
action. Each object has exactly:

  {
    "title":        "short action title (<=60 chars)",
    "rationale":    "one sentence: what structural improvement this provides",
    "unified_diff": "a unified diff that applies cleanly to the scope"
  }

The unified_diff must:
  - use `--- a/<file>` / `+++ b/<file>` headers with the scope's
    relative file path
  - include `@@` hunk headers with correct line numbers
  - touch ONLY lines visible in the scope

Do NOT:
  - wrap output in markdown code fences
  - emit any preamble, postamble, or explanation outside the JSON objects
  - invent imports, APIs, or types not visible in the scope
  - propose a refactor that changes what the code computes]]

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
		local seen = {}
		for _, d in ipairs(trigger_diag) do
			seen[(d.lnum or 0) .. "|" .. (d.message or "") .. "|" .. (d.source or "")] = true
		end
		local other = {}
		for _, d in ipairs(scope_diag) do
			local k = (d.lnum or 0) .. "|" .. (d.message or "") .. "|" .. (d.source or "")
			if not seen[k] then
				seen[k] = true; other[#other + 1] = d
			end
		end
		if #trigger_diag > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Diagnostic at cursor (informational — do NOT fix; refer to `quickfix`):"
			for _, d in ipairs(trigger_diag) do lines[#lines + 1] = fmt(d) end
		end
		if #other > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Other diagnostics in this scope (informational):"
			for _, d in ipairs(other) do lines[#lines + 1] = fmt(d) end
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== CODE ==="
	lines[#lines + 1] = scope.text or ""
	lines[#lines + 1] = "=== END ==="
	return table.concat(lines, "\n")
end

local function to_action(obj)
	return {
		category    = "refactor",
		title       = (obj.title or "(untitled)"):sub(1, 120),
		description = obj.rationale or obj.description or "",
		diff        = obj.unified_diff or obj.diff or "",
		kind        = "refactor",
		raw         = obj,
	}
end

return {
	id    = "refactor",
	label = "Refactor",
	icon  = "",

	build = function(scope, ctx)
		ctx = ctx or {}
		local request = {
			system   = SYSTEM_PROMPT,
			messages = {
				{ role = "user",
				  content = build_user_prompt(scope, ctx.include_diagnostics ~= false) },
			},
		}

		local parser_wrap = { actions = {}, on_action = nil, on_warn = nil }

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

		function parser_wrap:feed(chunk) json_parser:feed(chunk) end
		function parser_wrap:finalize()   return self.actions    end

		return request, parser_wrap
	end,
}
