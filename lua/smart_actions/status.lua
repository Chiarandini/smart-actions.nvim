-- Per-request status surface. The pipeline in init.lua calls begin()
-- when dispatching a stream, chunk() on each incoming chunk, and
-- finish() on settle. External observers (statuslines, status reports)
-- call list()/current() to inspect in-flight work.
--
-- This is intentionally separate from busy.lua: busy.lua signals "work
-- in progress" via vim.bo.busy for generic consumers; status.lua carries
-- the rich metadata (scope, category, provider, timings) a dedicated
-- consumer can render without scraping notifications.

local M = {}

local function now()
	return (vim.uv or vim.loop).now()
end

local active = {}  -- oldest first; most recent is active[#active]

--- Record a new in-flight request.
---@param info { scope: table, category: table, provider: table, bufnr: integer }
---@return table handle — opaque; pass back to chunk()/finish()
function M.begin(info)
	local scope    = info.scope or {}
	local trigger  = scope.trigger or {}
	local cursor   = trigger.cursor or {}
	local rec = {
		scope_label    = scope.label or "?",
		file           = trigger.file or "",
		cursor_row     = cursor.row,
		cursor_col     = cursor.col,
		category_id    = info.category and info.category.id or "?",
		category_label = info.category and info.category.label or nil,
		provider_id    = info.provider and info.provider.id or "?",
		bufnr          = info.bufnr,
		started_at     = now(),
		first_chunk_at = nil,
		bytes          = 0,
		state          = "pending",
	}
	active[#active + 1] = rec
	return rec
end

--- Record an incoming chunk; first call transitions state to "streaming"
--- and stamps time-to-first-byte.
function M.chunk(rec, text)
	if not rec then return end
	if not rec.first_chunk_at then
		rec.first_chunk_at = now()
		rec.state = "streaming"
	end
	rec.bytes = rec.bytes + #(text or "")
end

--- Remove the record. Safe to call multiple times.
function M.finish(rec)
	if not rec then return end
	for i = #active, 1, -1 do
		if active[i] == rec then
			table.remove(active, i)
			return
		end
	end
end

--- All in-flight requests, oldest first. Returned table is live — do not
--- mutate.
function M.list()
	return active
end

--- Most recent in-flight request, or nil.
function M.current()
	return active[#active]
end

return M
