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
--- optional) clamps the valid target range.
---
--- Anchoring strategy (in order):
---   1. scope-relative: scope_start_row + h.old_start - 1
---   2. file-relative:  h.old_start - 1
---   3. small offsets (±5) from either, used to recover when the AI's
---      line numbers are off by a few, or when the user has hand-edited
---      the hunk header to a value inconsistent with the body.
--- A candidate is accepted only if BOTH
---   (a) every `-` deletion falls within [scope_start_row, scope_end_row]
---   (b) every context/deletion line matches the actual buffer content
---       (the "patch would-apply-cleanly" check)
--- are satisfied. This makes the applier behave like `git apply` — if
--- you keep the body correct the diff lands, even if the header is off.
---
--- All hunks join into a single undo entry via undojoin.
--- Returns (ok, err).
function M.apply_to_buffer(patch, bufnr, scope_start_row, scope_end_row)
	scope_start_row = scope_start_row or 0
	local hunks = M.parse(patch)
	if #hunks == 0 then return false, "no hunks parsed" end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	--- Every `-` deletion line's target row is within scope bounds.
	local function deletions_in_bounds(start_row, h)
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

	--- The body's context + deletion lines match buffer rows starting at
	--- start_row. Hunks without any context are vacuously matched — bounds
	--- then becomes the only check.
	local function context_matches(start_row, h)
		local offset = 0
		local had_anchor = false
		for _, l in ipairs(h.lines) do
			local c = l:sub(1, 1)
			if c == " " or c == "-" then
				had_anchor = true
				local expected = l:sub(2)
				local actual   = buffer_lines[start_row + offset + 1] -- Lua 1-indexed table
				if actual ~= expected then return false end
				offset = offset + 1
			end
		end
		return had_anchor and true or true -- vacuous true when no anchor lines
	end

	--- Build the list of candidate start rows, ordered by preference.
	local function candidates_for(h)
		local base = {
			scope_start_row + h.old_start - 1, -- scope-relative
			h.old_start - 1,                   -- file-relative
		}
		local cands = {}
		local seen = {}
		local function push(row)
			if row >= 0 and not seen[row] then
				seen[row] = true
				cands[#cands + 1] = row
			end
		end
		for _, b in ipairs(base) do push(b) end
		for delta = 1, 5 do
			for _, b in ipairs(base) do
				push(b - delta)
				push(b + delta)
			end
		end
		return cands
	end

	for _, h in ipairs(hunks) do
		local anchored
		for _, cand in ipairs(candidates_for(h)) do
			if deletions_in_bounds(cand, h) and context_matches(cand, h) then
				anchored = cand
				break
			end
		end
		if not anchored then
			return false, string.format(
				"hunk @@ -%d @@ cannot be anchored — no nearby row matches "
				.. "the hunk's context under any line-number interpretation. "
				.. "Either the header is wrong, the context lines don't match "
				.. "the buffer, or a deletion falls outside scope rows %d..%d.",
				h.old_start, scope_start_row, scope_end_row or -1)
		end
		h.effective_start = anchored
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
