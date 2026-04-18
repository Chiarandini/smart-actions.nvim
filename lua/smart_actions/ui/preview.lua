-- Scratch-buffer diff editor invoked when the user presses `e` in the picker.
-- Opens the action's unified diff as a scratch buffer with filetype=diff.
-- `:w` calls on_confirm(true, edited_patch); any close without write cancels
-- via on_confirm(false).

local M = {}

---@param action table       -- { title, description, diff, ... }
---@param target_bufnr integer  (carried for the caller's apply step)
---@param on_confirm fun(accepted: boolean, patch: string|nil)
function M.edit(action, target_bufnr, on_confirm)
	local diff_lines = vim.split((action.diff or ""), "\n", { plain = true })
	if diff_lines[#diff_lines] == "" then diff_lines[#diff_lines] = nil end

	local edit_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, diff_lines)
	vim.bo[edit_buf].buftype   = "acwrite"
	vim.bo[edit_buf].bufhidden = "wipe"
	vim.bo[edit_buf].filetype  = "diff"
	vim.api.nvim_buf_set_name(edit_buf, "smart-action-edit://" .. (action.title or "patch"))

	local settled = false
	local function settle(accepted, patch)
		if settled then return end
		settled = true
		if on_confirm then on_confirm(accepted, patch) end
	end

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = edit_buf, once = true,
		callback = function()
			local edited = table.concat(
				vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false), "\n")
			vim.bo[edit_buf].modified = false
			pcall(vim.cmd, "bwipeout!")
			settle(true, edited)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		buffer = edit_buf, once = true,
		callback = function() settle(false, nil) end,
	})

	vim.api.nvim_set_current_buf(edit_buf)
	vim.notify("[smart-actions] :w to apply, :q! to cancel", vim.log.levels.INFO)
end

return M
