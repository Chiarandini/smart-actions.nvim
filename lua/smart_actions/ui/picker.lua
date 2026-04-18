-- Results picker. Preferred backend: Snacks.picker with the built-in "diff"
-- previewer, so the unified diff renders inline (pretty via `delta` if you
-- have it on $PATH; else fancy/syntax-highlighted). Fallback: vim.ui.select
-- (no inline preview; just a flat menu) — kept so the plugin degrades when
-- snacks isn't installed.
--
-- Callback contract:
--   on_finish(action, mode) where mode is:
--     "apply"  → user confirmed; caller should apply action.diff
--     "edit"   → user pressed `e`; caller should open scratch editor
--     nil      → user cancelled (action will also be nil)

local M = {}

local function snacks_available()
	local ok = pcall(require, "snacks")
	return ok and _G.Snacks and _G.Snacks.picker and true or false
end

local function open_snacks(actions, on_finish)
	local items = {}
	for _, a in ipairs(actions) do
		items[#items + 1] = {
			action = a,
			text   = (a.title or "(untitled)") .. " " .. (a.description or ""),
			diff   = a.diff or "",
		}
	end

	local settled = false
	local function settle(action, mode)
		if settled then return end
		settled = true
		if on_finish then on_finish(action, mode) end
	end

	_G.Snacks.picker({
		source = "smart_actions",
		title  = "Smart actions",
		items  = items,
		format = function(item, _picker)
			local a = item.action
			return {
				{ "[" .. (a.category or "?") .. "] ", "Comment" },
				{ a.title or "(untitled)", "Normal" },
				{ "  " .. (a.description or ""), "Comment" },
			}
		end,
		preview = "diff",
		confirm = function(picker, item)
			-- Settle BEFORE close(). picker:close() fires on_close synchronously,
			-- and on_close calls settle(nil, nil) to handle cancellation — if we
			-- close first, the cancellation settle wins and "apply" is lost.
			if item and item.action then settle(item.action, "apply") end
			picker:close()
		end,
		actions = {
			smart_edit = function(picker)
				local item = picker:current()
				if not item or not item.action then return end
				settle(item.action, "edit")
				picker:close()
			end,
		},
		win = {
			input = {
				keys = {
					["e"] = { "smart_edit", mode = { "n", "i" }, desc = "open diff for editing" },
				},
			},
		},
		on_close = function() settle(nil, nil) end,
	})
end

local function open_vanilla(actions, on_finish)
	local function fmt(a)
		local desc = a.description or ""
		if #desc > 80 then desc = desc:sub(1, 77) .. "..." end
		return string.format("[%s] %s — %s", a.category or "?", a.title or "(untitled)", desc)
	end
	vim.ui.select(actions, {
		prompt      = "Smart actions",
		format_item = fmt,
	}, function(choice)
		if on_finish then on_finish(choice, choice and "apply" or nil) end
	end)
end

---@param actions table[]
---@param on_finish fun(action: table|nil, mode: "apply"|"edit"|nil)
function M.open(actions, on_finish)
	if not actions or #actions == 0 then
		if on_finish then on_finish(nil, nil) end
		return
	end
	if snacks_available() then
		open_snacks(actions, on_finish)
	else
		open_vanilla(actions, on_finish)
	end
end

return M
