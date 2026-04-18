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
	H.check("out-of-scope err surfaces",  err and err:match("rejecting") ~= nil, true)
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

H.summary()
