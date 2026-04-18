-- review category — v2.
--
-- Broader feedback than quickfix/refactor — the user has explicitly
-- opted IN to nit-level commentary. Items come in four severities
-- (blocker / suggestion / nit / question) and may be either FIXES
-- (have a unified_diff) or OBSERVATIONS (empty diff; rationale-only).
--
-- The picker auto-detects observation items and renders the rationale
-- as markdown in the preview pane instead of an empty diff.

local stream_json = require("smart_actions.stream_json")

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT = [[You are a code reviewer embedded in a Neovim plugin. The user has
explicitly opted IN to broad feedback — this category is where you
share concerns that quickfix, refactor, and suppress deliberately
exclude (style, naming, design judgement, clarifying questions).

Return a FOCUSED code review of the scope. Each concern is a separate
review item. Items may be:
  - Fixes (have a working unified_diff that applies cleanly)
  - Observations (no diff; just prose rationale)

Severity tags — include one at the START of every title:
  [blocker]    Serious issue — bug, data-loss risk, security flaw.
               Must be addressed.
  [suggestion] Would meaningfully improve the code (clearer name,
               better error handling, a more idiomatic pattern).
  [nit]        Small polish — style, redundancy, naming preferences.
  [question]   Something unclear that needs human judgement before
               any change can be proposed.

Rules (strict):
  1. Return AT MOST 5 items.
  2. Sort by severity: blockers first, questions last.
  3. Each item must be a DISTINCT concern. Do not group related
     items; do not output the same issue as both a fix and an
     observation.
  4. A fix item must have a unified_diff that applies cleanly.
  5. An observation item must have "" (empty string) for
     unified_diff AND a substantial prose rationale (2-3 sentences)
     explaining the concern.
  6. If the scope is truly clean — no blockers, no suggestions, no
     nits worth raising, no unclear parts — return NOTHING.
     Do not invent concerns to fill the quota.
  7. Prefer observations over stretch-fixes for [nit]-level items
     where the "fix" would be contentious (e.g. renaming a public
     symbol).

Output format (identical schema to quickfix):
  {
    "title":        "[severity] short description (<=60 chars)",
    "rationale":    "2-3 sentences: the concern AND — for fixes —
                     why the proposed change resolves it",
    "unified_diff": "unified diff OR empty string"
  }

Do NOT:
  - wrap output in markdown code fences
  - emit preamble outside JSON
  - propose fixes that belong in quickfix (bug fixes) or refactor
    (behaviour-preserving structural changes) unless it's a
    [blocker]-level concern a reviewer would still surface]]

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
			if not seen[k] then seen[k] = true; other[#other + 1] = d end
		end
		if #trigger_diag > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Diagnostic at cursor (informational):"
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
		category    = "review",
		title       = (obj.title or "(untitled)"):sub(1, 120),
		description = obj.rationale or obj.description or "",
		diff        = obj.unified_diff or obj.diff or "",
		kind        = "review",
		raw         = obj,
	}
end

return {
	id    = "review",
	label = "Review",
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
