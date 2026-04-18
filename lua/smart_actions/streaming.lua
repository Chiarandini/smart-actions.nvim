-- Line-buffered streaming over a subprocess. Shared by AI providers
-- (claude_code spawns `claude -p ...`, anthropic spawns `curl` against the
-- Messages API) — everything except the per-line parse and the argv is
-- identical, so we pull the plumbing here.
--
-- Contract:
--   spec = { cmd        = { "bin", "arg", ... },
--            stdin      = false | string,
--            parse_line = function(line) -> text: string|nil, err: string|nil,
--            name       = string,  -- used in exit-error messages
--            timeout_ms = nil | 0 | integer  -- auto-cancel if not settled in time }
--   cb   = { on_text = fn(chunk), on_done = fn(), on_error = fn(err) }
--
-- Exactly one of on_done / on_error fires per invocation. The returned
-- cancel_fn settles with on_error("cancelled") and kills the subprocess.
-- Timeout settles with on_error("... timed out after Nms").

local M = {}

function M.run_subprocess(spec, cb)
	local buf, settled, proc = "", false, nil
	local timer

	local function settle(kind, arg)
		if settled then return end
		settled = true
		if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
		vim.schedule(function()
			if kind == "done" and cb and cb.on_done then cb.on_done() end
			if kind == "error" and cb and cb.on_error then cb.on_error(arg) end
		end)
	end

	local function on_chunk(_, chunk)
		if settled or not chunk then return end
		buf = buf .. chunk
		while true do
			local nl = buf:find("\n")
			if not nl then break end
			local line = buf:sub(1, nl - 1)
			buf = buf:sub(nl + 1)
			local text, err = spec.parse_line(line)
			if err then settle("error", err); return end
			if text and text ~= "" then
				vim.schedule(function()
					if not settled and cb and cb.on_text then cb.on_text(text) end
				end)
			end
		end
	end

	proc = vim.system(spec.cmd, {
		text   = true,
		stdin  = spec.stdin or false,
		stdout = on_chunk,
		stderr = function(_, _) end,
	}, function(res)
		if res.code and res.code ~= 0 then
			settle("error", string.format("%s exited %d: %s",
				spec.name or "subprocess", res.code, (res.stderr or ""):sub(1, 500)))
		else
			settle("done")
		end
	end)

	if spec.timeout_ms and spec.timeout_ms > 0 then
		timer = vim.uv.new_timer()
		timer:start(spec.timeout_ms, 0, vim.schedule_wrap(function()
			if settled then return end
			if proc then pcall(function() proc:kill(15) end) end
			settle("error", string.format("%s timed out after %dms",
				spec.name or "subprocess", spec.timeout_ms))
		end))
	end

	return function()
		if settled then return end
		if proc then pcall(function() proc:kill(15) end) end
		settle("error", "cancelled")
	end
end

return M
