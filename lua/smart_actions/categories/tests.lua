-- tests category — v2.
--
-- Generates ONE test for the function/method closest to the cursor and
-- appends it to the current file. The AI picks the test framework from
-- the language + existing imports (pytest / vitest / #[test] / Go's
-- testing package / plenary for Lua).
--
-- Scope is forced to "file" by M.tests() so the AI sees the full context
-- and the append-at-end diff lands within scope bounds. Multi-file test
-- placement (e.g. tests/test_foo.py) is deferred — for now, the test is
-- appended to the current file and can be hand-moved if a separate test
-- file is the project convention.

local stream_json = require("smart_actions.stream_json")

local SYSTEM_PROMPT = [[You are a test-generation assistant embedded in a Neovim plugin.

You are given:
  - a scope of code (the "=== CODE ===" block)
  - trigger metadata (which function/method the cursor is on or near)
  - optional <project_context> rules earlier in this system prompt

Task: generate EXACTLY ONE test for the function or method closest to
the cursor. The test must exercise the public contract — inputs and
outputs a consumer of the function would observe — NOT internal
implementation details.

Framework detection (from file extension + existing imports):
  - Python (.py):    pytest-style (`def test_xxx():` + `assert`)
  - TypeScript/JS:   vitest or jest (`describe`/`it` + `expect(...)`)
  - Rust (.rs):      built-in `#[test]` inside `#[cfg(test)] mod tests {}`
  - Go (.go):        `func TestXxx(t *testing.T)` — note: by convention
                     this belongs in a `_test.go` file; if the current
                     file is NOT a _test.go, emit nothing and let the
                     user move to the right file.
  - Lua (.lua):      plenary `describe`/`it` if the project uses it
                     (look at imports), else a simple
                     `assert(my_func(x) == y)` block

Output: ONE JSON object on a single logical entry, as newline-delimited
JSON. Schema identical to quickfix:

  {
    "title":        "Test: <what it verifies>",
    "rationale":    "one sentence: which input/output behaviour this covers",
    "unified_diff": "unified diff that APPENDS the test to the current file"
  }

Rules (strict):
  1. APPEND the test to the end of the current file. The diff should be
     a single append-only hunk (no deletions, no changes to existing
     code). Target the last lines of the scope.
  2. For Python: if the file has a `if __name__ == "__main__":` block,
     place the test function definition ABOVE the block so the runner
     can call it. If the file has no such block, just append the test.
  3. For Rust: if the scope contains a `#[cfg(test)] mod tests {}`, add
     the test inside it. If not, create that module at the file's end.
  4. Do NOT modify any existing code. Diff must only add lines.
  5. Do NOT invent imports that aren't already used in the scope, unless
     it's the standard test framework for that language (`pytest`,
     `describe`/`expect`, `testing`, `#[cfg(test)]`, etc.).
  6. If you cannot identify a clear testable function near the cursor
     (file is all constants/types, cursor is between functions), output
     NOTHING.
  7. If the file is the wrong place for a test (e.g. Go non-`_test.go`,
     Python `__init__.py`), output NOTHING.

Do NOT:
  - wrap output in markdown code fences
  - emit any preamble or postamble
  - emit more than one test per invocation
  - propose mutation of existing code (that's `quickfix` or `refactor`)]]

local function build_user_prompt(scope)
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

	lines[#lines + 1] = ""
	lines[#lines + 1] = "=== CODE ==="
	lines[#lines + 1] = scope.text or ""
	lines[#lines + 1] = "=== END ==="
	return table.concat(lines, "\n")
end

local function to_action(obj)
	return {
		category    = "tests",
		title       = (obj.title or "(untitled)"):sub(1, 120),
		description = obj.rationale or obj.description or "",
		diff        = obj.unified_diff or obj.diff or "",
		kind        = "tests",
		raw         = obj,
	}
end

return {
	id    = "tests",
	label = "Tests",
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
