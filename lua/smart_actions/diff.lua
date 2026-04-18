-- Unified-diff parsing and application.
--
-- Parse hunks, apply each in reverse order via nvim_buf_set_lines so earlier
-- hunk line numbers stay valid. Consecutive hunks join into a single undo
-- entry so `u` reverts the whole action at once.
--
-- Diffs are interpreted relative to `scope_start_row` (0-indexed) — the
-- diff's line 1 maps to buffer row `scope_start_row`. The AI is prompted
-- to emit scope-relative diffs.
--
-- Hunk counts come from the BODY, not the header. AI-emitted diffs have been
-- observed to claim `old=8 new=6` in the header when the body only contains
-- `old=7 new=5` lines. Trusting the header in that case deletes buffer rows
-- the AI never had context for. Body-derived counts are always safe.

local M = {}

-- Pull start-line numbers from an @@ header. Counts are ignored — we derive
-- them from the body.
local function parse_hunk_header(line)
	local ol, nl = line:match("^@@%s*%-(%d+),?%d*%s+%+(%d+),?%d*%s*@@")
	if ol then return tonumber(ol), tonumber(nl) end
	return nil
end

--- Parse a unified diff into a list of hunks.
--- Each hunk: { old_start, new_start, old_count, new_count, lines = {...} }
--- where old_count/new_count are derived from the body.
function M.parse(patch)
	if type(patch) ~= "string" or patch == "" then return {} end
	local hunks = {}
	local cur = nil
	for line in (patch .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^@@") then
			local ol, nl = parse_hunk_header(line)
			if ol then
				cur = { old_start = ol, new_start = nl, lines = {} }
				hunks[#hunks + 1] = cur
			else
				cur = nil
			end
		elseif line:match("^%-%-%-%s") or line:match("^%+%+%+%s") then
			-- Multi-file file-header between hunks. Terminate current hunk so
			-- we don't confuse `--- a/other.txt` for a deletion line.
			cur = nil
		elseif cur then
			local c = line:sub(1, 1)
			if c == " " or c == "+" or c == "-" then
				cur.lines[#cur.lines + 1] = line
			else
				cur = nil
			end
		end
	end
	for _, h in ipairs(hunks) do
		h.old_count, h.new_count = 0, 0
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == " " then
				h.old_count = h.old_count + 1
				h.new_count = h.new_count + 1
			elseif c == "-" then
				h.old_count = h.old_count + 1
			elseif c == "+" then
				h.new_count = h.new_count + 1
			end
		end
	end
	return hunks
end

--- Apply a unified diff to `bufnr`, scoped so diff line 1 maps to
--- `scope_start_row` (0-indexed). `scope_end_row` (inclusive, 0-indexed,
--- optional) clamps the valid target range so a hunk can't accidentally
--- reach into code outside the scope (catches AI diffs that use
--- file-relative line numbers or fabricate out-of-range hunks).
--- All hunks join into a single undo entry via undojoin.
--- Returns (ok, err).
function M.apply_to_buffer(patch, bufnr, scope_start_row, scope_end_row)
	scope_start_row = scope_start_row or 0
	local hunks = M.parse(patch)
	if #hunks == 0 then return false, "no hunks parsed" end

	-- Resolve each hunk's effective buffer start row. Try scope-relative
	-- first (what the prompt asks for); fall back to file-relative if that
	-- overshoots scope bounds. AIs are inconsistent for narrow scopes: a
	-- `line` scope at file line 7 may get `@@ -1,... @@` (scope-relative)
	-- or `@@ -7,... @@` (file-relative, ignoring the scope).
	--
	-- Bounds check: every DELETION must target a row within scope. Context
	-- lines can extend beyond (they're observation, not modification), and
	-- pure-insertion `+` lines inherit the neighboring context's position.
	local function fits_at(start_row, h)
		if not scope_end_row then return true end
		local offset = 0
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == "-" then
				local br = start_row + offset
				if br < scope_start_row or br > scope_end_row then return false end
			end
			if c == " " or c == "-" then offset = offset + 1 end
		end
		return true
	end

	for _, h in ipairs(hunks) do
		local scope_rel = scope_start_row + h.old_start - 1
		local file_rel  = h.old_start - 1
		if fits_at(scope_rel, h) then
			h.effective_start = scope_rel
		elseif scope_rel ~= file_rel and fits_at(file_rel, h) then
			h.effective_start = file_rel
		else
			return false, string.format(
				"hunk @@ -%d @@ out of scope rows %d..%d under both "
				.. "scope-relative and file-relative interpretations; rejecting",
				h.old_start, scope_start_row, scope_end_row or -1)
		end
	end

	table.sort(hunks, function(a, b) return a.effective_start > b.effective_start end)

	for i, h in ipairs(hunks) do
		local buf_start = h.effective_start
		local buf_end   = buf_start + h.old_count

		local new_lines = {}
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == " " or c == "+" then
				new_lines[#new_lines + 1] = l:sub(2)
			end
		end

		if i > 1 then pcall(vim.cmd, "silent! undojoin") end
		local ok, err = pcall(vim.api.nvim_buf_set_lines,
			bufnr, buf_start, buf_end, false, new_lines)
		if not ok then
			return false, string.format("hunk at line %d failed: %s", h.old_start, tostring(err))
		end
	end

	return true
end

return M
