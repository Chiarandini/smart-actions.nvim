-- User commands. Keymaps are registered by setup() so they respect the
-- keymap opt; the :SmartAction command is always present once the plugin
-- is on the rtp.

if vim.g.loaded_smart_actions then return end
vim.g.loaded_smart_actions = true

vim.api.nvim_create_user_command("SmartAction", function(args)
	require("smart_actions").run({ scope = args.args ~= "" and args.args or nil })
end, {
	nargs = "?",
	complete = function()
		return { "line", "function", "file", "folder", "project", "auto", "visual", "ask" }
	end,
	desc = "Run a smart code action (optionally with explicit scope)",
})

vim.api.nvim_create_user_command("SmartActionCancel", function()
	require("smart_actions").cancel()
end, { desc = "Cancel the in-flight smart action" })

vim.api.nvim_create_user_command("SmartActionExplain", function(args)
	require("smart_actions").explain({
		scope = args.args ~= "" and args.args or nil,
	})
end, {
	nargs = "?",
	complete = function()
		return { "line", "function", "file", "folder", "project", "auto", "visual", "ask" }
	end,
	desc = "Explain the code under cursor (streams into a floating window)",
})

vim.api.nvim_create_user_command("SmartActionSuppress", function(args)
	require("smart_actions").suppress({
		scope = args.args ~= "" and args.args or nil,
	})
end, {
	nargs = "?",
	complete = function()
		return { "line", "function", "file", "folder", "project", "auto", "visual", "ask" }
	end,
	desc = "Add a suppression comment for an LSP diagnostic (no logic change)",
})

vim.api.nvim_create_user_command("SmartActionRefactor", function(args)
	require("smart_actions").refactor({
		scope = args.args ~= "" and args.args or nil,
	})
end, {
	nargs = "?",
	complete = function()
		return { "line", "function", "file", "folder", "project", "auto", "visual", "ask" }
	end,
	desc = "Propose behaviour-preserving refactors for the code under cursor",
})

vim.api.nvim_create_user_command("SmartActionLastDiff", function()
	local diff = vim.g.smart_actions_last_diff or ""
	local title = vim.g.smart_actions_last_title or ""
	if diff == "" then
		vim.notify("[smart-actions] no diff applied yet this session", vim.log.levels.INFO)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false,
		vim.split("# " .. title .. "\n\n" .. diff, "\n"))
	vim.bo[buf].filetype  = "diff"
	vim.bo[buf].bufhidden = "wipe"
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end, { desc = "Show the last applied smart action's diff" })
