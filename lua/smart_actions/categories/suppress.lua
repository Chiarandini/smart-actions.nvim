-- suppress category — narrow sibling of quickfix.
--
-- Adds a language-appropriate suppression comment for an LSP diagnostic
-- WITHOUT modifying code behavior. Invoked via :SmartActionSuppress or
-- require("smart_actions").suppress(). Not enabled on grA by default —
-- quickfix stays the primary path; suppress is explicit.
--
-- When to reach for this: the diagnostic is noise in your specific
-- context (a library's type stubs are wrong, a known-false-positive
-- lint, etc.) and you've decided the right fix is to mute it.

local stream_json = require("smart_actions.stream_json")

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT = [[You are a diagnostic-suppression assistant embedded in a Neovim plugin.

You are given:
  - a scope of code
  - trigger metadata (cursor position + file path)
  - LSP diagnostics overlapping the scope
  - optional <project_context> rules earlier in this system prompt

Task: produce AT MOST 3 suppression-comment actions that silence a
specific diagnostic WITHOUT changing code behavior. "No actions" is the
correct response when there are no diagnostics to suppress.

Rules (strict):
  1. Output nothing if there are no LSP diagnostics in the scope.
  2. Prefer the first action to target the diagnostic on the trigger line.
  3. A suppression MUST be a comment or attribute appropriate to the
     language. Use the most SPECIFIC form available (rule-scoped over
     broad):
       - Python:     # pyright: ignore[<rule>]  |  # type: ignore[<rule>]  |  # noqa: <code>
       - TypeScript: // @ts-expect-error  |  // eslint-disable-next-line <rule>
       - JavaScript: // eslint-disable-next-line <rule>
       - Rust:       #[allow(<lint>)]
       - Go:         //nolint:<linter>
       - Shell:      # shellcheck disable=<code>
       - Lua:        ---@diagnostic disable-next-line: <code>
  4. The suppression MUST target the EXACT diagnostic line. Either:
     a. Insert the comment on the line above (preferred for "next-line"
        directives), or
     b. Append the comment to the end of the same line (inline form).
  5. DO NOT modify any logic. Diffs must only add/modify comment or
     attribute lines.
  6. If two actions suppress the same diagnostic with different forms
     (e.g. broad `# type: ignore` vs scoped `# pyright: ignore[reportFoo]`),
     prefer the more specific one and skip the broader one.

Output format (identical to quickfix):
  {
    "title":        "short title (<=60 chars)",
    "rationale":    "one sentence explaining which diagnostic this mutes",
    "unified_diff": "unified diff that inserts/modifies the suppression comment"
  }

Do NOT:
  - wrap output in markdown code fences
  - emit any preamble or postamble outside the JSON objects
  - propose suppressing a diagnostic that doesn't exist
  - modify any line's semantics (even "minor" cleanup)]]

local function build_user_prompt(scope)
	local trg = scope.trigger
	local rel = vim.fn.fnamemodify(trg.file, ":.")
	if rel == "" then rel = "[nofile]" end

	local lines = {
		string.format("Scope: %s (%d chars)", scope.label, #(scope.text or "")),
		string.format("File: %s", rel),
		string.format("Cursor: line %d col %d  symbol=%s",
			trg.cursor.row + 1, trg.cursor.col + 1, trg.symbol or "-"),
	}

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
		lines[#lines + 1] = "Diagnostic at cursor:"
		for _, d in ipairs(trigger_diag) do lines[#lines + 1] = fmt(d) end
	end
	if #other > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Other diagnostics in this scope:"
		for _, d in ipairs(other) do lines[#lines + 1] = fmt(d) end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== CODE ==="
	lines[#lines + 1] = scope.text or ""
	lines[#lines + 1] = "=== END ==="
	return table.concat(lines, "\n")
end

local function to_action(obj)
	return {
		category    = "suppress",
		title       = (obj.title or "(untitled)"):sub(1, 120),
		description = obj.rationale or obj.description or "",
		diff        = obj.unified_diff or obj.diff or "",
		kind        = "suppress",
		raw         = obj,
	}
end

return {
	id    = "suppress",
	label = "Suppress",
	icon  = "",

	build = function(scope, _ctx)
		local request = {
			system   = SYSTEM_PROMPT,
			messages = { { role = "user", content = build_user_prompt(scope) } },
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
