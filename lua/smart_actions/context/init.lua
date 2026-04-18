-- Context registry. Each context provider is a module under
-- smart_actions.context.* returning:
--   { id, priority, detect(root) -> bool, gather(scope) -> string }
--
-- assemble() is called once per grA press. It walks the registry, keeps
-- providers that (a) detect() true, (b) aren't claimed by the AI provider's
-- handles_natively list, (c) survive allowlist/denylist. Results are sorted
-- by priority desc and packed into a <project_context> block, truncated to
-- config.context.max_chars with lower-priority blocks dropped first.

local util = require("smart_actions.util")

local M = require("smart_actions.registry").new({
	module_prefix = "smart_actions.context",
	kind          = "context provider",
})

local BUILTINS = { "claude_md", "agents_md", "cursorrules", "neovim_plugin", "language_default" }

function M.preload_builtins()
	M.preload(BUILTINS)
end

--- Helper for file-walking context providers (claude_md, agents_md, .cursorrules).
--- Concatenates every ancestor file named `filename`, root-most first.
function M.ancestor_file_source(opts)
	return {
		id       = opts.id,
		priority = opts.priority or 0,
		detect   = function(root)
			return #util.find_ancestor_files(root or vim.fn.getcwd(), opts.filename) > 0
		end,
		gather = function(scope)
			local start = (scope and scope.trigger and scope.trigger.file) or vim.fn.getcwd()
			local paths = util.find_ancestor_files(start, opts.filename)
			if #paths == 0 then return "" end
			local parts = {}
			for i = #paths, 1, -1 do
				local f = io.open(paths[i], "r")
				if f then
					parts[#parts + 1] = string.format("--- %s ---\n%s",
						vim.fn.fnamemodify(paths[i], ":~"), f:read("*a"))
					f:close()
				end
			end
			return table.concat(parts, "\n\n")
		end,
	}
end

--- Assemble the <project_context> string for a given scope + AI provider.
--- Returns "" if disabled, no matches, or everything filtered.
function M.assemble(scope, ai_provider)
	local config = require("smart_actions.config").get().context or {}
	if config.enabled == false then return "" end

	local max_chars = config.max_chars or 4000
	local allow    = config.allowlist
	local deny     = config.denylist

	local natively = {}
	for _, id in ipairs((ai_provider and ai_provider.handles_natively) or {}) do
		natively[id] = true
	end

	local root = util.project_root(scope and scope.trigger and scope.trigger.file)

	local matches = {}
	for _, p in ipairs(M.list()) do
		repeat
			if natively[p.id] then break end
			if allow and not util.tbl_contains(allow, p.id) then break end
			if deny and util.tbl_contains(deny, p.id) then break end

			local ok, matched = pcall(p.detect, root)
			if not (ok and matched) then break end

			local gok, block = pcall(p.gather, scope)
			if not gok or type(block) ~= "string" or block == "" then break end

			matches[#matches + 1] = { id = p.id, priority = p.priority or 0, block = block }
		until true
	end

	table.sort(matches, function(a, b) return a.priority > b.priority end)

	local parts, total, omitted = {}, 0, 0
	for _, m in ipairs(matches) do
		local wrapped = string.format('<source id="%s">\n%s\n</source>', m.id, m.block)
		if total + #wrapped + 2 > max_chars then
			omitted = omitted + 1
		else
			parts[#parts + 1] = wrapped
			total = total + #wrapped + 2
		end
	end

	if #parts == 0 then return "" end
	local body = "<project_context>\n" .. table.concat(parts, "\n\n") .. "\n</project_context>"
	if omitted > 0 then
		body = body .. string.format(
			"\n<!-- %d context block(s) omitted (budget %d chars) -->", omitted, max_chars)
	end
	return body
end

return M
