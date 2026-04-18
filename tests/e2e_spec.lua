-- End-to-end tests that exercise the full smart-actions pipeline against
-- real Claude Code (or Anthropic API). Each case:
--   1. Writes a deliberately-buggy fixture to a tempfile.
--   2. Positions cursor on the known trigger line.
--   3. Runs the pipeline (scope → context → quickfix → provider.stream).
--   4. Applies the first returned action and asserts shape properties:
--        - action count > 0
--        - apply succeeds (diff stays within scope bounds)
--        - "bug keyword" no longer appears in the buffer after apply
--        - for cursor-focused scopes, the diff's deletions cluster near cursor
--
-- Gated by SA_E2E=1 so default `tests/*_spec.lua` runs don't burn API calls.
--
-- Run:
--   SA_E2E=1 ./tests/run-e2e.sh
-- or:
--   SA_E2E=1 NVIM_APPNAME=noethervim nvim --headless \
--     --cmd 'set rtp+=~/programming/custom_plugins/smart-actions.nvim' \
--     -c 'luafile tests/e2e_spec.lua' -c 'qa!'

if vim.env.SA_E2E ~= "1" then
	print("e2e_spec: skipped (set SA_E2E=1 to enable — hits real Claude Code)")
	return
end

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
local diff_mod = require("smart_actions.diff")

require("smart_actions").setup({ keymap = false })

-- ─── Runner ────────────────────────────────────────────────────────────

local E2E_NS = vim.api.nvim_create_namespace("smart_actions_e2e")

local function run_case(case)
	local tmp = vim.fn.tempname() .. (case.suffix or ".py")
	local f = assert(io.open(tmp, "w"))
	f:write(case.content)
	f:close()
	-- `edit` triggers ftplugins which may fail in unusual environments (e.g.
	-- a tex ftplugin that requires vim-abolish headlessly). Soft-fail so one
	-- bad case doesn't abort the whole run.
	local edit_ok, edit_err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(tmp))
	if not edit_ok then
		os.remove(tmp)
		return {
			actions    = {},
			err        = "edit failed: " .. tostring(edit_err):sub(1, 200),
			elapsed_ms = 0,
			scope      = { label = "?" },
		}
	end
	vim.api.nvim_win_set_cursor(0, { case.cursor_row, case.cursor_col or 0 })
	-- Ensure TS is attached for this buffer's filetype. scope.ts_node_at
	-- force-parses if the parser is attached-but-not-yet-parsed, but start()
	-- must be called at least once per buffer.
	pcall(vim.treesitter.start, 0, vim.bo.filetype)
	-- Inject synthetic diagnostics if the case provides them. This lets us
	-- test the "diagnostic exists → AI must act" rule without waiting for a
	-- real LSP to analyze the file (async + language-parser-dependent).
	if case.diagnostics then
		vim.diagnostic.set(E2E_NS, 0, case.diagnostics)
	end
	-- Optional pre-edit hook: lets a case modify the buffer before running
	-- the pipeline. Used to exercise apply on an already-dirty buffer so
	-- undojoin is stress-tested against a pre-existing edit.
	if case.pre_edit then case.pre_edit(0) end

	local opts = { visual_range = case.visual_range }
	local scope = require("smart_actions.scope").get(case.scope, opts)

	local cat_id = case.category_id or "quickfix"
	local cat = require("smart_actions.categories").get(cat_id)
	local req, parser = cat.build(scope, { include_diagnostics = true })

	-- Prepend context the same way init.lua's pipeline does.
	local provider = require("smart_actions.providers").active()
	local ctx = require("smart_actions.context").assemble(scope, provider)
	if ctx ~= "" then req.system = req.system .. "\n\n" .. ctx end

	local done, err_msg = false, nil
	local t0 = vim.uv.hrtime()
	require("smart_actions.providers").stream(req, {
		on_text  = function(c) parser:feed(c) end,
		on_done  = function() done = true end,
		on_error = function(e) done = true; err_msg = e end,
	})
	while not done and (vim.uv.hrtime() - t0) < 90e9 do vim.wait(200) end
	local elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6)

	local result = {
		category   = cat,
		scope      = scope,
		elapsed_ms = elapsed_ms,
		err        = err_msg,
		buf_before = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
	}

	if cat.output_kind == "text" then
		-- Text-output categories (explain) stream prose into a float; no
		-- actions to apply. Expose the accumulated text for assertions.
		result.text    = parser.text or ""
		result.actions = {}
	else
		result.actions = parser.actions or {}
		if #result.actions > 0 then
			local a = result.actions[1]
			local ok, apply_err = diff_mod.apply_to_buffer(a.diff, 0,
				scope.start.row, scope.end_.row)
			result.apply_ok  = ok
			result.apply_err = apply_err
			result.first     = a
			if ok then
				result.buf_after = table.concat(
					vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
			end
		end
	end

	pcall(vim.cmd, "bwipeout!")
	os.remove(tmp)
	return result
end

--- Biggest distance (in lines, 1-indexed) between any deleted/added hunk line
--- and the trigger cursor. Used for "is the edit near the cursor" assertions.
local function max_edit_distance(action_diff, cursor_row_1_indexed)
	local hunks = diff_mod.parse(action_diff or "")
	local max_d = 0
	for _, h in ipairs(hunks) do
		local offset = 0
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == "-" or c == "+" then
				local d = math.abs((h.old_start + offset) - cursor_row_1_indexed)
				if d > max_d then max_d = d end
			end
			if c == " " or c == "-" then offset = offset + 1 end
		end
	end
	return max_d
end

-- ─── Test cases ────────────────────────────────────────────────────────

local cases = {
	{
		-- Context-independent bug: literal division by zero, always raises.
		-- `line` scope without a diagnostic — 0 actions is acceptable here.
		name = "line scope: no diagnostic",
		scope = "line", cursor_row = 2,
		content = "x = 42\nresult = 10 / 0\ny = 0\n",
		assert_fn = function(r)
			if #r.actions == 0 then
				print("  (0 actions — acceptable for line scope without diagnostic)")
				return
			end
			H.check("line: apply ok",        r.apply_ok,                              true)
			H.check("line: buffer mutated",  r.buf_after ~= r.buf_before,             true)
			H.check("line: edit dist <= 1",  max_edit_distance(r.first.diff, 2) <= 1, true)
		end,
	},
	{
		-- Regression: when an LSP diagnostic overlaps the trigger line, the
		-- AI MUST return an action — silence is not allowed per the
		-- quickfix prompt. Uses synthetic diagnostics so we don't depend on
		-- real LSP analysis timing in headless mode.
		name = "line scope: diagnostic forces action",
		scope = "line", cursor_row = 7,
		content = "def hello_world():\n    pass\n\n\nglobal TEST\n\nsf\n\nTEST = 2\n\ndef randomFunc():\n    pass\n\nrandomFunc()\n",
		diagnostics = {
			{ lnum = 6, col = 0, severity = vim.diagnostic.severity.ERROR,
			  message = '"sf" is not defined', source = "Pyright", end_lnum = 6 },
		},
		assert_fn = function(r)
			H.check("line+diag: >=1 action",    #r.actions >= 1,                 true)
			H.check("line+diag: apply ok",      r.apply_ok,                      true)
			-- apply_ok=true implies buf_after is a string; guard to avoid a
			-- spurious pass when apply failed (buf_after would be nil then).
			H.check("line+diag: sf removed or defined",
				r.buf_after and r.buf_after ~= r.buf_before or false, true)
		end,
	},
	{
		name = "function scope: off-by-one",
		scope = "function", cursor_row = 3,
		content = "def sum_first(items, n):\n    total = 0\n    for i in range(n + 1):\n        total += items[i]\n    return total\n",
		assert_fn = function(r)
			H.check("function: >=1 action", #r.actions >= 1, true)
			H.check("function: apply ok",   r.apply_ok,      true)
			-- After apply, the buggy `n + 1` should be gone (replaced by `n` or similar).
			H.check("function: off-by-one fixed",
				r.buf_after and not r.buf_after:find("range%(n %+ 1%)"), true)
			-- Diff stays within the function (rows 0..4 inclusive).
			H.check("function: edit within function body",
				max_edit_distance(r.first.diff, 3) <= 4, true)
		end,
	},
	{
		name = "file scope: undefined reference in small file",
		scope = "file", cursor_row = 7, -- on `sf`
		content = "def hello_world():\n    pass\n\n\nglobal TEST\n\nsf\n\nTEST = 2\n\ndef randomFunc():\n    pass\n\nrandomFunc()\n",
		bug_keyword = "sf",
		assert_fn = function(r)
			H.check("file: >=1 action",           #r.actions >= 1, true)
			H.check("file: apply ok",             r.apply_ok,      true)
			H.check("file: sf removed",           r.buf_after and r.buf_after:find("\nsf\n") == nil, true)
			-- Regression guard: the malformed-header bug deleted `pass` in
			-- the following function. Body must survive.
			H.check("file: randomFunc body intact",
				r.buf_after and r.buf_after:find("def randomFunc%(%):\n    pass") ~= nil, true)
		end,
	},
	{
		name = "visual scope: invalid comparison",
		scope = "visual", cursor_row = 2,
		content = "x = 5\nif x = 10:\n    print(\"yes\")\n",
		-- Select all of line 2 (0-indexed row 1) in line-wise visual.
		visual_range = {
			mode  = "V",
			start = { row = 1, col = 0 },
			end_  = { row = 1, col = 10 },
		},
		assert_fn = function(r)
			H.check("visual: >=1 action",     #r.actions >= 1, true)
			H.check("visual: apply ok",       r.apply_ok,      true)
			H.check("visual: `=` replaced",
				r.buf_after and r.buf_after:find("if x == 10") ~= nil, true)
		end,
	},
	{
		-- Regression: folder scope at a file with an LSP-diagnostic-flagged
		-- line. Previously scope.end_.row was set to 0 (degenerate), which
		-- made the bounds check reject any hunk targeting rows > 0 even
		-- though the diff was valid.
		name = "folder scope: diagnostic with bounds that span the buffer",
		scope = "folder", cursor_row = 7,
		content = "def hello_world():\n    pass\n\n\nglobal TEST\n\nsf\n\nTEST = 2\n\ndef randomFunc():\n    pass\n\nrandomFunc()\n",
		diagnostics = {
			{ lnum = 6, col = 0, severity = vim.diagnostic.severity.ERROR,
			  message = '"sf" is not defined', source = "Pyright", end_lnum = 6 },
		},
		assert_fn = function(r)
			H.check("folder: >=1 action",         #r.actions >= 1, true)
			H.check("folder: apply ok",           r.apply_ok,      true)
			H.check("folder: scope spans buffer", r.scope.end_.row > 0, true)
			H.check("folder: randomFunc body intact",
				r.buf_after and r.buf_after:find("def randomFunc%(%):\n    pass") ~= nil, true)
		end,
	},
	{
		-- Lua fixture — the Lua TS parser ships with nvim-treesitter in every
		-- NoetherVim install, so the auto→function resolution is deterministic
		-- here. Python would require an on-demand parser install.
		name = "auto scope: resolves to function when inside one",
		scope = "auto", cursor_row = 3, suffix = ".lua",
		content = "local function greet(name)\n  local out = 'hi ' .. nam\n  return out\nend\n\nprint(greet('world'))\n",
		assert_fn = function(r)
			H.check("auto: >=1 action",           #r.actions >= 1, true)
			H.check("auto: apply ok",             r.apply_ok,      true)
			H.check("auto: resolved to function", r.scope.label,   "function")
			H.check("auto: nam typo fixed",
				r.buf_after and r.buf_after:find("%.%. nam\n") == nil, true)
		end,
	},

	-- ─── Filetype matrix ────────────────────────────────────────────────
	-- File scope (doesn't depend on per-language TS parser being installed).
	{
		name = "rust: off-by-one in loop bound",
		scope = "file", cursor_row = 3, suffix = ".rs",
		content = "fn main() {\n    let xs = vec![1, 2, 3];\n    for i in 0..xs.len() + 1 {\n        println!(\"{}\", xs[i]);\n    }\n}\n",
		assert_fn = function(r)
			H.check("rust: >=1 action",   #r.actions >= 1, true)
			H.check("rust: apply ok",     r.apply_ok,      true)
			H.check("rust: `len() + 1` gone",
				r.buf_after and r.buf_after:find("len%(%) %+ 1") == nil, true)
		end,
	},
	{
		name = "go: nil pointer dereference",
		scope = "file", cursor_row = 7, suffix = ".go",
		content = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tvar x *int\n\tfmt.Println(*x)\n}\n",
		assert_fn = function(r)
			H.check("go: >=1 action",    #r.actions >= 1, true)
			H.check("go: apply ok",      r.apply_ok,      true)
			H.check("go: buffer mutated", r.buf_after ~= r.buf_before, true)
		end,
	},
	{
		-- Synthetic diagnostic on the cursor line makes this deterministic:
		-- our quickfix prompt's rule 1 mandates an action when a diagnostic
		-- overlaps. Without the diagnostic the test occasionally flakes —
		-- the AI reads `result + 1` as plausibly-intentional and returns
		-- nothing.
		name = "typescript: missing await on Promise",
		scope = "file", cursor_row = 7, suffix = ".ts",
		content = "async function fetchData(): Promise<number> {\n    return 42;\n}\n\nasync function main() {\n    const result = fetchData();\n    console.log(result + 1);\n}\n",
		diagnostics = {
			{ lnum = 6, col = 16, severity = vim.diagnostic.severity.ERROR,
			  message = "Operator '+' cannot be applied to types 'Promise<number>' and 'number'.",
			  source = "typescript", end_lnum = 6 },
		},
		assert_fn = function(r)
			H.check("ts: >=1 action",    #r.actions >= 1, true)
			H.check("ts: apply ok",      r.apply_ok,      true)
			H.check("ts: buffer mutated", r.buf_after ~= r.buf_before, true)
		end,
	},
	{
		-- NOTE: may soft-fail in some environments — tex ftplugins often
		-- require plugins (e.g. vim-abolish) that aren't loaded in a raw
		-- headless run. run_case wraps the `edit` in pcall so a bad
		-- ftplugin doesn't abort the full suite, and reports a clear
		-- "edit failed" error instead of hanging or crashing.
		name = "latex: typo in \\end{document}",
		scope = "file", cursor_row = 4, suffix = ".tex",
		content = "\\documentclass{article}\n\\begin{document}\nHello world\n\\end{documen}\n",
		assert_fn = function(r)
			H.check("tex: >=1 action",   #r.actions >= 1, true)
			H.check("tex: apply ok",     r.apply_ok,      true)
			H.check("tex: `documen}` replaced",
				r.buf_after and r.buf_after:find("\\end{documen}") == nil, true)
		end,
	},

	-- ─── Weird shapes ───────────────────────────────────────────────────
	{
		-- Truly-broken Python: incomplete expression. TS may fail to parse;
		-- resolve_function falls back to the paragraph heuristic.
		name = "syntax-broken: incomplete expression",
		scope = "function", cursor_row = 2,
		content = "def foo(x, y):\n    result = x +\n    return result\n",
		assert_fn = function(r)
			H.check("broken: >=1 action", #r.actions >= 1, true)
			H.check("broken: apply ok",   r.apply_ok,      true)
			-- `x +` (trailing operator) must be gone after the fix.
			H.check("broken: dangling operator gone",
				r.buf_after and r.buf_after:find("x %+\n") == nil, true)
		end,
	},
	{
		-- Two bugs one function. AI may emit one action with two hunks, or
		-- two separate actions; we just assert the first applies cleanly.
		name = "multi-bug function (stresses multi-hunk path)",
		scope = "function", cursor_row = 3,
		content = "def process(items, n):\n    total = 0\n    for i in range(n + 1):\n        total += items[i]\n    return total + 999\n",
		assert_fn = function(r)
			H.check("multi-bug: >=1 action", #r.actions >= 1, true)
			H.check("multi-bug: apply ok",   r.apply_ok,      true)
			-- At least one of the two bugs must be fixed.
			local range_fixed  = r.buf_after and r.buf_after:find("range%(n %+ 1%)") == nil
			local return_fixed = r.buf_after and r.buf_after:find("return total %+ 999") == nil
			H.check("multi-bug: at least one bug fixed", range_fixed or return_fixed, true)
		end,
	},
	-- ─── Additional categories ──────────────────────────────────────────
	{
		-- Explain streams prose into a float (headless: we just capture it).
		-- Synthetic diagnostic forces the prompt's rule-1 path (cursor
		-- diagnostic) so the AI has clear subject matter.
		name = "explain: prose streams for a diagnostic",
		scope = "line", cursor_row = 1,
		category_id = "explain",
		content = "x = undefined_thing\n",
		diagnostics = {
			{ lnum = 0, col = 4, severity = vim.diagnostic.severity.ERROR,
			  message = '"undefined_thing" is not defined', source = "Pyright",
			  end_lnum = 0 },
		},
		assert_fn = function(r)
			H.check("explain: text streamed",              r.text and #r.text >= 50,                      true)
			H.check("explain: mentions 'undefined'",
				r.text and r.text:lower():find("undefined") ~= nil,  true)
		end,
	},
	{
		-- Behaviour-preserving refactor: flatten nested if-chains into
		-- early returns. Assertions verify the function signature and
		-- core expression (sum(data) / len(data)) survive the refactor.
		name = "refactor: flatten nested conditionals",
		scope = "function", cursor_row = 3,
		category_id = "refactor",
		content = "def process(data):\n    if data is not None:\n        if len(data) > 0:\n            if isinstance(data, list):\n                return sum(data) / len(data)\n    return 0\n",
		assert_fn = function(r)
			H.check("refactor: >=1 action",    #r.actions >= 1, true)
			H.check("refactor: apply ok",      r.apply_ok,      true)
			H.check("refactor: buffer mutated", r.buf_after ~= r.buf_before, true)
			-- Behaviour preservation: signature + core computation still present.
			H.check("refactor: `def process` preserved",
				r.buf_after and r.buf_after:find("def process%(data%)") ~= nil, true)
			H.check("refactor: core expression preserved",
				r.buf_after and r.buf_after:find("sum%(data%)") ~= nil, true)
		end,
	},
	{
		-- Suppress adds a language-appropriate comment without changing
		-- code logic. We assert the diff contains a known suppression
		-- marker (pyright-ignore, type-ignore, or noqa) — the exact form
		-- varies per run, but one of these keywords must appear.
		name = "suppress: emits a suppression-comment action",
		scope = "line", cursor_row = 2,
		category_id = "suppress",
		content = "def compute(x):\n    return x + 'hello'\n",
		diagnostics = {
			{ lnum = 1, col = 4, severity = vim.diagnostic.severity.ERROR,
			  message = 'Operator "+" not supported for types "int" and "str"',
			  source = "Pyright", end_lnum = 1,
			  user_data = { lsp = { code = "reportOperatorIssue" } } },
		},
		assert_fn = function(r)
			H.check("suppress: >=1 action",     #r.actions >= 1,                     true)
			H.check("suppress: apply ok",       r.apply_ok,                          true)
			H.check("suppress: buffer mutated", r.buf_after and r.buf_after ~= r.buf_before, true)
			local diff = r.first and r.first.diff or ""
			local marker = diff:lower():match("pyright: ignore")
				or diff:lower():match("type: ignore")
				or diff:lower():match("noqa")
			H.check("suppress: diff contains pyright/type/noqa marker",
				marker ~= nil, true)
			-- The edit should NOT change the code's semantics — return-line
			-- content should be preserved (possibly with an appended comment).
			H.check("suppress: `x + 'hello'` still present",
				r.buf_after and r.buf_after:find("x %+ 'hello'") ~= nil, true)
		end,
	},
	{
		-- Apply on an already-dirty buffer. pre_edit inserts a harmless line
		-- at the TOP of the buffer; grA targets the bug line (now shifted
		-- down by 1). Applying should leave the pre-edit intact and not
		-- collapse undo entries beyond the action boundary.
		name = "modified buffer: apply on dirty state",
		scope = "line", cursor_row = 3,
		content = "x = 1\ny = 10 / 0\nz = 3\n",
		diagnostics = {
			{ lnum = 2, col = 0, severity = vim.diagnostic.severity.ERROR,
			  message = "possible division by zero", source = "synthetic", end_lnum = 2 },
		},
		pre_edit = function(buf)
			-- Prepend an unrelated comment line — cursor was set to row 3
			-- (which was `y = 10 / 0`); after pre_edit, that row is now 3
			-- still (since we insert BEFORE row 1 so indices shift one down,
			-- but our cursor fixup handles it via the direct set below).
			vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# pre-edit injection" })
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
		end,
		assert_fn = function(r)
			H.check("dirty: >=1 action",   #r.actions >= 1, true)
			H.check("dirty: apply ok",     r.apply_ok,      true)
			-- string:find returns an index (number) on match / nil on miss.
			-- Coerce to a boolean so the equality assertion is clean.
			H.check("dirty: pre-edit preserved",
				r.buf_after and r.buf_after:find("^# pre%-edit injection\n") ~= nil, true)
		end,
	},
}

-- ─── Execute ───────────────────────────────────────────────────────────

print(string.format("e2e: running %d case(s) — each hits Claude Code", #cases))
print(string.rep("=", 60))

for _, case in ipairs(cases) do
	print("\n── " .. case.name .. " ──")
	local r = run_case(case)
	r.bug_keyword = case.bug_keyword
	print(string.format("  elapsed: %dms  actions: %d  scope.label: %s",
		r.elapsed_ms, #r.actions, r.scope.label))
	if r.err and r.err:match("^edit failed") then
		-- Environmental (e.g. user ftplugin requires a plugin not on rtp).
		-- Surface the reason but don't count against the suite.
		print("  SKIP  " .. r.err)
	elseif r.err then
		H.failures = H.failures + 1
		print("  FAIL  stream error: " .. r.err)
	elseif r.category and r.category.output_kind == "text" then
		-- Text-category cases (explain): no .actions/.first; assertions
		-- operate on r.text.
		print(string.format("  text length: %d chars", #(r.text or "")))
		if r.text and #r.text > 0 and #r.text < 200 then
			print("  sample: " .. r.text:sub(1, 120))
		end
		case.assert_fn(r)
	elseif #r.actions == 0 then
		H.failures = H.failures + 1
		print("  FAIL  no actions returned")
	else
		print("  first action: " .. r.first.title)
		if r.apply_err then print("  apply_err: " .. r.apply_err) end
		case.assert_fn(r)
	end
end

H.summary()
