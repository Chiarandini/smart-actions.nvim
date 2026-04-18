-- Scope picker — static 7-entry menu shown when default_scope = "ask".
-- Uses vim.ui.select so dressing/snacks overrides pick up the skin.

local M = {}

local ENTRIES = {
	{ value = "auto",      label = "auto — visual selection → function → file" },
	{ value = "line",      label = "line" },
	{ value = "function",  label = "function (treesitter)" },
	{ value = "file",      label = "file (current buffer)" },
	{ value = "folder",    label = "folder (current dir)" },
	{ value = "project",   label = "project (git root)" },
	{ value = "visual",    label = "visual selection" },
}

---@param cb fun(scope: string|nil)
function M.choose(cb)
	vim.ui.select(ENTRIES, {
		prompt      = "Smart action scope",
		format_item = function(item) return item.label end,
	}, function(choice)
		if choice then cb(choice.value) else cb(nil) end
	end)
end

return M
