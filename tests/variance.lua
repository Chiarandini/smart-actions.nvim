-- AI-variance harness. Runs grA N times against a fixture with cursor on a
-- known line and prints each action's deletion count, addition count, and
-- max line-distance from the cursor. Flag an unhealthy prompt if any run
-- touches lines far from the trigger.
--
-- Usage:
--   nvim --headless -c 'lua _G.SA_RUNS = 10' \
--     -c 'edit tests/fixtures/undefined_name.py' \
--     -c 'call cursor(7, 1)' \
--     -c 'luafile tests/variance.lua' -c 'qa!'

local RUNS         = _G.SA_RUNS or 5
local CURSOR_ROW   = _G.SA_CURSOR_ROW or 7  -- 1-indexed line where the bug is
local SCOPE_NAME   = _G.SA_SCOPE or "file"
local TIMEOUT_NS   = 90e9

require("smart_actions").setup({ keymap = false })

local function probe()
	local scope = require("smart_actions.scope").get(SCOPE_NAME)
	local cat   = require("smart_actions.categories").get("quickfix")
	local req, parser = cat.build(scope, { include_diagnostics = true })
	local done = false
	require("smart_actions.providers").stream(req, {
		on_text  = function(c) parser:feed(c) end,
		on_done  = function() done = true end,
		on_error = function() done = true end,
	})
	local t0 = vim.uv.hrtime()
	while not done and (vim.uv.hrtime() - t0) < TIMEOUT_NS do vim.wait(200) end
	return parser.actions
end

local function summarize(a)
	local hunks = require("smart_actions.diff").parse(a.diff or "")
	local minus, plus, max_dist = 0, 0, 0
	for _, h in ipairs(hunks) do
		local offset = 0
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == "-" then
				minus = minus + 1
				local dist = math.abs((h.old_start + offset) - CURSOR_ROW)
				if dist > max_dist then max_dist = dist end
			elseif c == "+" then
				plus = plus + 1
			end
			if c == " " or c == "-" then offset = offset + 1 end
		end
	end
	return minus, plus, max_dist
end

print(string.format("variance harness: scope=%s cursor=line %d runs=%d",
	SCOPE_NAME, CURSOR_ROW, RUNS))
print(string.rep("-", 70))

for i = 1, RUNS do
	vim.api.nvim_win_set_cursor(0, { CURSOR_ROW, 0 })
	local actions = probe()
	if #actions == 0 then
		print(string.format("%02d: NO ACTIONS", i))
	else
		for j, a in ipairs(actions) do
			local minus, plus, max_dist = summarize(a)
			print(string.format("%02d.%d: -%d +%d  max_dist=%d  title=%q",
				i, j, minus, plus, max_dist, a.title or ""))
		end
	end
end
