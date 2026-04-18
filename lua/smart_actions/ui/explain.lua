-- Streaming-text float for the `explain` category.
--
-- Opens a bordered floating window in markdown mode and appends tokens
-- as they stream in from the AI.
--
-- Buffer-local keymaps:
--   q / <Esc>     — close the float, invoke opts.on_dismiss if set
--   a / <CR>      — (only when on_action provided) close the float and
--                   run opts.on_action. Useful for the common flow:
--                   explain, decide, fix.
--
-- The window's footer shows the active keymaps so users don't have to
-- memorise or check :help.

local M = {}

---@param title string                       window title
---@param opts  table|nil                    { on_action? = fn(), on_dismiss? = fn() }
---@return table handle { feed(chunk), done(), close() }
function M.open(title, opts)
	opts = opts or {}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype   = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype  = "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	local width  = math.min(vim.o.columns - 4, 100)
	local height = math.min(math.floor(vim.o.lines * 0.6), 30)

	local footer = opts.on_action
		and " [a/<CR>] run action  [q/<Esc>] close "
		or  " [q/<Esc>] close "

	local win = vim.api.nvim_open_win(buf, true, {
		relative   = "editor",
		width      = width,
		height     = height,
		row        = math.floor((vim.o.lines - height) / 2),
		col        = math.floor((vim.o.columns - width) / 2),
		style      = "minimal",
		border     = "rounded",
		title      = title or " Explain ",
		title_pos  = "center",
		footer     = footer,
		footer_pos = "center",
	})

	local function close_win() pcall(vim.api.nvim_win_close, win, true) end

	local action_taken = false
	local dismissed    = false

	local function dismiss()
		if action_taken or dismissed then return end
		dismissed = true
		close_win()
		if opts.on_dismiss then vim.schedule(opts.on_dismiss) end
	end

	local function pivot()
		if action_taken or dismissed then return end
		action_taken = true
		close_win()
		-- Defer so the float is fully torn down before on_action opens any
		-- new UI (mirrors the picker's close→schedule pattern).
		vim.schedule(opts.on_action)
	end

	local km = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "q",     dismiss, km)
	vim.keymap.set("n", "<Esc>", dismiss, km)
	if opts.on_action then
		vim.keymap.set("n", "a",    pivot, km)
		vim.keymap.set("n", "<CR>", pivot, km)
	end

	-- Catch any close path other than q/<Esc>/pivot (e.g. :q, :bd, buffer
	-- wipe). If the window vanishes without action_taken, treat as dismiss.
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once   = true,
		callback = function()
			if action_taken or dismissed then return end
			dismissed = true
			if opts.on_dismiss then vim.schedule(opts.on_dismiss) end
		end,
	})

	local handle = {}

	function handle.feed(chunk)
		if not chunk or chunk == "" then return end
		if not vim.api.nvim_buf_is_valid(buf) then return end
		vim.bo[buf].modifiable = true
		local lines = vim.split(chunk, "\n", { plain = true })
		local last = vim.api.nvim_buf_line_count(buf)
		local tail = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
		vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { tail .. lines[1] })
		if #lines > 1 then
			vim.api.nvim_buf_set_lines(buf, last, last, false,
				{ select(2, unpack(lines)) })
		end
		vim.bo[buf].modifiable = false
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win,
				{ vim.api.nvim_buf_line_count(buf), 0 })
		end
	end

	function handle.done() end
	function handle.close() close_win() end

	return handle
end

return M
