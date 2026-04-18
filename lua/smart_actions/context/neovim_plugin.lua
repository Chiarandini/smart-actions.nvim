-- Detects a Neovim plugin repo and injects Lua/Neovim idioms so the AI
-- stops recommending vim.* calls that don't exist or old vimscript patterns.

return {
	id       = "neovim_plugin",
	priority = 70,

	detect = function(root)
		if not root or root == "" then return false end
		-- Walk up so we still match when project_root heuristics undershoot
		-- (e.g. a non-git plugin dir where root came back as lua/<name>).
		local dir = root
		local seen = {}
		while dir and dir ~= "" and dir ~= "/" and not seen[dir] do
			seen[dir] = true
			if dir:match("%.nvim$") then return true end
			if vim.fn.glob(dir .. "/plugin/*.lua", true, true)[1] then return true end
			if vim.fn.glob(dir .. "/lua/*/init.lua", true, true)[1]
				and vim.uv.fs_stat(dir .. "/lua") then
				return true
			end
			local parent = vim.fs.dirname(dir)
			if parent == dir then break end
			dir = parent
		end
		return false
	end,

	gather = function(_scope)
		return table.concat({
			"This project is a Neovim plugin (Lua).",
			"Prefer: vim.api.*, vim.keymap.set, vim.fs.*, vim.uv, vim.system, vim.treesitter.",
			"lazy.nvim spec form: { 'owner/repo', opts = {...}, ",
			"  config = function(_, opts) require('<mod>').setup(opts) end }.",
			"Target Neovim 0.10+ (assume vim.system, vim.uv, vim.fs.root exist).",
			"No emojis in code or comments.",
			"Follow existing module conventions: one 'local M = {}' per file, return M.",
		}, "\n")
	end,
}
