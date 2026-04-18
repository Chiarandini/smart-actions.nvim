-- Thin wrapper over vim.bo[bufnr].busy. The NoetherVim statusline already
-- animates a spinner whenever this is > 0 on any visible window, so the
-- plugin only needs to increment on start and decrement on completion or
-- cancellation.

local M = {}

function M.increment(bufnr)
	bufnr = bufnr or 0
	vim.bo[bufnr].busy = (vim.bo[bufnr].busy or 0) + 1
end

function M.decrement(bufnr)
	bufnr = bufnr or 0
	vim.bo[bufnr].busy = math.max(0, (vim.bo[bufnr].busy or 0) - 1)
end

return M
