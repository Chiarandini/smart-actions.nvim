-- Regression tests for smart_actions.diff.
--
-- Run:
--   NVIM_APPNAME=noethervim nvim --headless \
--     --cmd 'set rtp+=~/programming/custom_plugins/smart-actions.nvim' \
--     -c 'luafile tests/diff_spec.lua' -c 'qa!'

local diff = require("smart_actions.diff")
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")

-- Regression: AI-malformed header (off-by-one).
-- Header says old=8 new=6 but body has only 7 old / 5 new lines. Trusting
-- the header deletes one extra buffer row (bug seen in the wild — Python
-- "undefined name `sf`" case where `    pass` in a following function
-- was silently eaten).
H.with_buf({
	"def hello_world():", "    pass", "", "",
	"global TEST", "", "sf", "",
	"TEST = 2", "", "def randomFunc():", "    pass",
	"", "randomFunc()",
}, function(buf)
	local patch = "--- a/tmp.py\n+++ b/tmp.py\n@@ -5,8 +5,6 @@\n global TEST\n \n-sf\n-\n TEST = 2\n \n def randomFunc():\n"
	local ok, err = diff.apply_to_buffer(patch, buf, 0, 13)
	H.check("malformed-header apply ok",  ok,  true)
	H.check("malformed-header apply err", err, nil)
	H.check("malformed-header preserves randomFunc pass",
		vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
			"def hello_world():", "    pass", "", "",
			"global TEST", "", "TEST = 2", "",
			"def randomFunc():", "    pass", "", "randomFunc()",
		})
end)

-- Well-formed diff.
H.with_buf({ "local function f(n)", "  return n + 1", "end" }, function(buf)
	local patch = "@@ -1,3 +1,3 @@\n local function f(n)\n-  return n + 1\n+  return n\n end\n"
	H.check("well-formed apply ok", diff.apply_to_buffer(patch, buf, 0, 2), true)
	H.check("well-formed edit applied",
		vim.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "local function f(n)", "  return n", "end" })
end)

-- Out-of-scope hunk rejection.
-- Hunk targets rows 20..25 but scope ends at row 5. Must reject.
H.with_buf({ "a", "b", "c", "d", "e", "f" }, function(buf)
	local ok, err = diff.apply_to_buffer("@@ -20,1 +20,0 @@\n-out of scope\n", buf, 0, 5)
	H.check("out-of-scope rejected",      ok,  false)
	-- The error message's phrasing varies as the anchor heuristic evolves;
	-- just assert that SOMETHING meaningful was surfaced.
	H.check("out-of-scope err surfaces",  type(err) == "string" and #err > 0, true)
end)

-- Regression: file-relative fallback for narrow scopes.
-- AI emits `@@ -7,1 @@` against a line scope at buffer row 6 (file line 7).
-- Scope-relative would compute buf_start = 6+7-1 = 12 (out of bounds);
-- fallback to file-relative gives buf_start = 7-1 = 6 (in bounds) and applies.
H.with_buf({
	"def hello_world():", "    pass", "", "",
	"global TEST", "", "sf", "",
	"TEST = 2", "", "def randomFunc():", "    pass",
	"", "randomFunc()",
}, function(buf)
	local patch = "@@ -7,1 +7,0 @@\n-sf\n"
	H.check("file-relative fallback applies", diff.apply_to_buffer(patch, buf, 6, 6), true)
	H.check("file-relative fallback removed sf",
		vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1], "")
end)

-- Regression: user hand-edits a hunk header to a WRONG start line, but
-- leaves the body correct. Our anchor-by-context logic should relocate
-- the hunk to where the body actually matches the buffer.
-- (Real-world repro: user's `<C-e>` edit changed `@@ -6 @@` to `@@ -7 @@`
-- with unchanged context starting at `def test():`. Trusting the header
-- duplicated `def test():` in the output.)
H.with_buf({
	"def myFunc():", "    pass", "", "", "",
	"def test():", "    print('in test')", "",
	"df", "",
	"if __name__ == \"__main__\":", "    print(\"hi\")",
}, function(buf)
	local patch = table.concat({
		"--- a/tmp.py",
		"+++ b/tmp.py",
		"@@ -7,8 +7,6 @@",              -- header says line 7 (WRONG; real is line 6)
		" def test():",                  -- context — actually at row 5 (line 6)
		"     print('in test')",
		" ",
		"-df",
		"-",
		"+ testing this",
		" if __name__ == \"__main__\":",
		"     print(\"hi\")",
		"",
	}, "\n")
	H.check("anchor-by-context: apply ok", diff.apply_to_buffer(patch, buf, 0, 11), true)
	-- def test(): appears exactly ONCE after apply (no duplication).
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local count = 0
	for _, l in ipairs(lines) do if l == "def test():" then count = count + 1 end end
	H.check("anchor-by-context: no duplicated def test():", count, 1)
	-- The `+ testing this` addition landed in place of `df` + blank.
	H.check("anchor-by-context: `df` removed",
		vim.tbl_contains(lines, "df"), false)
	H.check("anchor-by-context: addition present",
		vim.tbl_contains(lines, " testing this"), true)
end)

-- Multi-hunk diff. Two disparate edits in a single patch must apply in
-- reverse order so the earlier hunk's line numbers remain valid, and the
-- whole patch is a single undo entry.
H.with_buf({
	"function greet(name)",
	"  return 'hi ' .. nam",
	"end",
	"",
	"function farewell(name)",
	"  return 'bye ' .. nane",
	"end",
}, function(buf)
	local patch = table.concat({
		"@@ -2,1 +2,1 @@",
		"-  return 'hi ' .. nam",
		"+  return 'hi ' .. name",
		"@@ -6,1 +6,1 @@",
		"-  return 'bye ' .. nane",
		"+  return 'bye ' .. name",
		"",
	}, "\n")
	H.check("multi-hunk applies", diff.apply_to_buffer(patch, buf, 0, 6), true)
	H.check("multi-hunk: first hunk applied",
		vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "  return 'hi ' .. name")
	H.check("multi-hunk: second hunk applied",
		vim.api.nvim_buf_get_lines(buf, 5, 6, false)[1], "  return 'bye ' .. name")
end)

-- apply_many: independent edits, both apply cleanly, single undo reverts all.
H.with_buf({ "line 1", "line 2", "line 3", "line 4" }, function(buf)
	local p1 = "@@ -2,1 +2,1 @@\n-line 2\n+line 2 NEW\n"
	local p2 = "@@ -4,1 +4,1 @@\n-line 4\n+line 4 NEW\n"
	local applied, skipped = diff.apply_many({ p1, p2 }, buf, 0, 3)
	H.check("apply_many: both applied", applied, 2)
	H.check("apply_many: no skips",     #skipped, 0)
	H.check("apply_many: buffer after",
		vim.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "line 1", "line 2 NEW", "line 3", "line 4 NEW" })
end)

-- apply_many: two actions that both try to modify line 2. First applies,
-- second's context ("line 2") no longer exists, anchor search fails, skip.
H.with_buf({ "alpha", "line 2", "beta", "line 2", "gamma" }, function(buf)
	local p1 = "@@ -2,1 +2,1 @@\n-line 2\n+line 2 VERSION A\n"
	-- p2 tries to change the FIRST "line 2" to VERSION B. Post-p1, the
	-- first line 2 is gone (replaced by "line 2 VERSION A"), so p2's
	-- context cannot match at row 1. The SECOND "line 2" at row 3 is a
	-- valid anchor (fuzzy search ±5), so p2 actually lands there.
	-- For a true skip, the diff must have context lines that are all
	-- mutated by p1. We set up p2 with narrower context that p1 destroyed.
	local p2 = "@@ -2,2 +2,2 @@\n-line 2\n alpha\n+line 2 VERSION B\n alpha\n"
	local applied, skipped = diff.apply_many({ p1, p2 }, buf, 0, 4)
	H.check("apply_many: first applied", applied, 1)
	H.check("apply_many: second skipped", #skipped, 1)
	H.check("apply_many: skipped index",  skipped[1].index, 2)
end)

-- ─── quickfix mode selection & region_cap ───────────────────────────────
--
-- Deterministic unit tests for the cursor-vs-region mode split, so we don't
-- rely on AI variance to prove the plumbing works.

local function synth_scope(label, scope_diag_count)
	local scope = {
		label = label, text = "code", truncated = false,
		start = { row = 0, col = 0 }, end_ = { row = 5, col = 0 },
		diagnostics = {},
		trigger = {
			file = "/tmp/x.py", cursor = { row = 0, col = 0 },
			symbol = nil, line_text = "",
			diagnostics = {}, diagnostics_at_col = {}, diagnostics_on_line = {},
		},
	}
	for i = 1, scope_diag_count do
		scope.diagnostics[i] = { lnum = 0, col = 0, severity = 1,
			message = "err " .. i, source = "test" }
	end
	return scope
end

local qf = require("smart_actions.categories.quickfix")

local function build_system(label, diag_count, ceiling)
	local req, _ = qf.build(synth_scope(label, diag_count),
		{ quickfix_region_max_actions = ceiling or 10 })
	return req.system
end

-- Cursor mode: any non-visual scope uses the cursor prompt.
for _, label in ipairs({ "line", "function", "file", "folder", "project", "auto" }) do
	local sys = build_system(label, 5)
	H.check("quickfix mode cursor for " .. label,
		sys:find("Return AT MOST 3", 1, true) ~= nil, true)
	H.check("quickfix no region marker for " .. label,
		sys:find("VISUALLY SELECTED", 1, true) == nil, true)
end

-- Region mode: visual scope uses the region prompt with a dynamic cap.
local cases = {
	{ diags = 0,  ceiling = 10, expected_cap = 3  },  -- max(3, 2) = 3
	{ diags = 2,  ceiling = 10, expected_cap = 4  },  -- max(3, 4) = 4
	{ diags = 5,  ceiling = 10, expected_cap = 7  },  -- max(3, 7) = 7
	{ diags = 8,  ceiling = 10, expected_cap = 10 },  -- max(3, 10) = 10
	{ diags = 20, ceiling = 10, expected_cap = 10 },  -- clamped at ceiling
	{ diags = 20, ceiling = 15, expected_cap = 15 },  -- user-raised ceiling
	{ diags = 20, ceiling = 5,  expected_cap = 5  },  -- user-lowered ceiling
}
for _, c in ipairs(cases) do
	local sys = build_system("visual", c.diags, c.ceiling)
	H.check(string.format("quickfix region mode (diags=%d ceiling=%d)", c.diags, c.ceiling),
		sys:find("VISUALLY SELECTED", 1, true) ~= nil, true)
	local actual = tonumber(sys:match("Return up to (%d+) distinct bug%-fix"))
	H.check(string.format("quickfix region cap (diags=%d ceiling=%d)", c.diags, c.ceiling),
		actual, c.expected_cap)
end

H.summary()
