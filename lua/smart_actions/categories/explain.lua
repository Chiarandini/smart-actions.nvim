-- explain category — read-only.
--
-- Asks the AI to explain why a diagnostic / piece of code is considered
-- problematic (or just what it does). Output is prose, streamed into a
-- floating window — no diff, no apply step. Complements `quickfix`: one
-- category tells you how to fix, the other tells you why you'd want to.

local SEVERITY_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }

local SYSTEM_PROMPT = [[You are a code explainer embedded in a Neovim plugin.

You are given:
  - a scope of code (the "=== CODE ===" block below)
  - trigger metadata (where the user's cursor was)
  - any LSP diagnostics overlapping the trigger line or scope
  - optional <project_context> rules earlier in this system prompt

Task: explain why this code is problematic, or what a subtle diagnostic is
really saying. Be precise and technical but concise (2-5 short paragraphs).

Prioritize in this order:
  1. If there is a diagnostic on the trigger line, explain IT — what the
     LSP is complaining about, why it matters, and what a fix would look
     like (in prose, do NOT emit a diff).
  2. Otherwise explain the most likely bug or confusing pattern at or
     near the cursor.
  3. If everything looks fine, say so plainly.

Format: plain markdown. Use inline `code` for identifiers, fenced blocks
only when showing a concrete alternative. No preamble, no "Here's an
explanation:" sign-on. No sign-off. Start with the substance.]]

local function build_user_prompt(scope, include_diagnostics)
	local trg = scope.trigger
	local rel = vim.fn.fnamemodify(trg.file, ":.")
	if rel == "" then rel = "[nofile]" end

	local lines = {
		string.format("Scope: %s (%d chars)", scope.label, #(scope.text or "")),
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

return {
	id          = "explain",
	label       = "Explain",
	icon        = "",
	output_kind = "text",  -- streams prose, not JSON actions

	build = function(scope, ctx)
		ctx = ctx or {}
		local request = {
			system   = SYSTEM_PROMPT,
			messages = {
				{ role = "user", content = build_user_prompt(scope, ctx.include_diagnostics ~= false) },
			},
		}

		-- parser contract for text categories: :feed(chunk) appends to the
		-- accumulator + fires on_text if set. No Actions, no .actions array.
		local parser = { text = "", on_text = nil, on_warn = nil }

		function parser:feed(chunk)
			if not chunk or chunk == "" then return end
			self.text = self.text .. chunk
			if self.on_text then self.on_text(chunk) end
		end

		function parser:finalize() return self.text end

		return request, parser
	end,
}
