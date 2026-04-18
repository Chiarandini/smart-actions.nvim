-- smart-actions.nvim — AI-suggested code actions on grA.
--
-- Complements (does not replace) vim.lsp.buf.code_action on gra.
-- Scope is configurable (line/function/file/folder/project/visual);
-- categories are pluggable; providers resolve to Claude Code CLI then
-- Anthropic API. See :help smart-actions for the full surface.

local M = {}

local function notify(msg, level)
	vim.notify("[smart-actions] " .. msg, level or vim.log.levels.INFO)
end

--- Capture the live visual selection if invoked from visual mode.
local function capture_visual_range()
	local mode = vim.fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
	local sp, ep = vim.fn.getpos("v"), vim.fn.getpos(".")
	if (sp[2] > ep[2]) or (sp[2] == ep[2] and sp[3] > ep[3]) then sp, ep = ep, sp end
	return {
		mode  = mode,
		start = { row = sp[2] - 1, col = sp[3] - 1 },
		end_  = { row = ep[2] - 1, col = ep[3] - 1 },
	}
end

function M.setup(opts)
	local config = require("smart_actions.config")
	config.apply(opts or {})

	require("smart_actions.providers").preload_builtins()
	require("smart_actions.context").preload_builtins()

	local categories = require("smart_actions.categories")
	for _, id in ipairs(config.get().categories or {}) do
		local cat, err = categories.get(id)
		if not cat then
			notify("failed to load category '" .. id .. "': " .. tostring(err),
				vim.log.levels.WARN)
		end
	end

	if config.get().keymap then
		vim.keymap.set({ "n", "x" }, config.get().keymap, function()
			M.run({ visual_range = capture_visual_range() })
		end, { desc = "smart code [A]ction" })
	end
end

-- ─── Pipeline helpers ──────────────────────────────────────────────────

local function resolve_scope(name, visual_range)
	local config = require("smart_actions.config").get()
	local ok, scope = pcall(require("smart_actions.scope").get, name, {
		visual_range      = visual_range,
		max_payload_chars = config.max_payload_chars,
		max_files         = config.max_files,
		max_file_bytes    = config.max_file_bytes,
	})
	if not ok then
		notify("scope error: " .. tostring(scope), vim.log.levels.ERROR)
		return nil
	end
	return scope
end

local function pick_category()
	local config = require("smart_actions.config").get()
	local categories = require("smart_actions.categories")
	for _, id in ipairs(config.categories or {}) do
		local c = categories.get(id)
		if c then return c end
	end
	return nil
end

local function announce(scope, provider, category)
	local trg = scope.trigger
	local rel = vim.fn.fnamemodify(trg.file, ":.")
	local flags = {}
	if scope.truncated then flags[#flags + 1] = "TRUNC" end
	if (scope.files_omitted or 0) ~= 0 then flags[#flags + 1] = "FILES-CAPPED" end
	notify(string.format(
		"scope=%s %s at %s:%d:%d  via=%s  cat=%s  payload=%d  streaming…",
		scope.label,
		#flags > 0 and ("[" .. table.concat(flags, ",") .. "]") or "",
		rel == "" and "[nofile]" or rel,
		trg.cursor.row + 1, trg.cursor.col + 1,
		provider.id, category.id, #(scope.text or "")))
end

local function apply_patch(bufnr, scope, action, patch)
	-- Stash for :SmartActionLastDiff (helpful when the inline diff renderer
	-- hides +/- markers and the user wants post-hoc ground truth).
	vim.g.smart_actions_last_diff  = patch or ""
	vim.g.smart_actions_last_title = action.title or ""
	local ok, err = require("smart_actions.diff").apply_to_buffer(
		patch, bufnr,
		scope.start and scope.start.row or 0,
		scope.end_  and scope.end_.row)
	if ok then
		notify("applied: " .. (action.title or ""))
	else
		notify("apply failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

local function dispatch_picker(bufnr, scope, actions)
	require("smart_actions.ui.picker").open(actions, function(chosen, mode)
		if not chosen or not mode then return end
		if mode == "apply" then
			apply_patch(bufnr, scope, chosen, chosen.diff)
		elseif mode == "edit" then
			require("smart_actions.ui.preview").edit(chosen, bufnr,
				function(accepted, edited_patch)
					if accepted then apply_patch(bufnr, scope, chosen, edited_patch) end
				end)
		end
	end)
end

local function run_pipeline(scope_name, visual_range)
	local config = require("smart_actions.config").get()
	local scope  = resolve_scope(scope_name, visual_range)
	if not scope then return end

	local provider, perr = require("smart_actions.providers").active()
	if not provider then
		notify("no provider available: " .. tostring(perr), vim.log.levels.ERROR)
		return
	end

	local category = pick_category()
	if not category then
		notify("no enabled category loaded", vim.log.levels.ERROR)
		return
	end

	announce(scope, provider, category)

	local request, parser = category.build(scope, {
		include_diagnostics = config.include_diagnostics,
	})
	local context_block = require("smart_actions.context").assemble(scope, provider)
	if context_block ~= "" then
		request.system = request.system .. "\n\n" .. context_block
	end
	parser.on_warn = function(msg) notify(msg, vim.log.levels.WARN) end

	local bufnr = scope.bufnr
	local busy  = require("smart_actions.busy")
	busy.increment(bufnr)

	require("smart_actions.providers").stream(request, {
		on_text = function(chunk) parser:feed(chunk) end,
		on_done = function()
			busy.decrement(bufnr)
			local actions = parser.actions or {}
			if #actions == 0 then
				notify("no actions produced (AI returned nothing parseable)",
					vim.log.levels.WARN)
				return
			end
			dispatch_picker(bufnr, scope, actions)
		end,
		on_error = function(err)
			busy.decrement(bufnr)
			notify("AI error: " .. tostring(err), vim.log.levels.ERROR)
		end,
	})
end

-- ─── Public API ────────────────────────────────────────────────────────

---@param opts table|nil { scope?: string, visual_range?: table }
function M.run(opts)
	opts = opts or {}
	local config = require("smart_actions.config").get()
	local visual_range = opts.visual_range or capture_visual_range()
	local name = opts.scope or config.default_scope

	if name == "ask" then
		require("smart_actions.ui.scope_picker").choose(function(chosen)
			if chosen then run_pipeline(chosen, visual_range) end
		end)
		return
	end
	run_pipeline(name, visual_range)
end

---@param scope string
function M.run_scope(scope)
	return M.run({ scope = scope, visual_range = capture_visual_range() })
end

function M.cancel()
	require("smart_actions.providers").cancel_active()
end

return M
