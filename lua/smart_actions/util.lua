-- Misc helpers — grown as needed in later phases.

local M = {}

function M.notify(msg, level)
	vim.notify("[smart-actions] " .. msg, level or vim.log.levels.INFO)
end

--- Walk upward from `start` looking for files named `name`.
--- Returns abs paths, leaf-first (closest to start comes first).
function M.find_ancestor_files(start, name)
	local out = {}
	if not start or start == "" then return out end
	local dir = start
	-- If start is a file, begin from its parent.
	local stat = vim.uv.fs_stat(dir)
	if stat and stat.type == "file" then
		dir = vim.fs.dirname(dir)
	end
	local seen = {}
	while dir and dir ~= "" and dir ~= "/" and not seen[dir] do
		seen[dir] = true
		local candidate = dir .. "/" .. name
		local s = vim.uv.fs_stat(candidate)
		if s and s.type == "file" then
			out[#out + 1] = candidate
		end
		local parent = vim.fs.dirname(dir)
		if parent == dir then break end
		dir = parent
	end
	return out
end

function M.tbl_contains(t, v)
	if not t then return false end
	for _, x in ipairs(t) do if x == v then return true end end
	return false
end

--- Effective project root for a scope. Uses .git as the primary marker
--- (matches scope.lua's project-scope heuristic). If no .git is found, falls
--- back to the file's own directory — NOT cwd, which may drift after the
--- user changes directories mid-session.
function M.project_root(path)
	if not path or path == "" then return vim.fn.getcwd() end
	local found = vim.fs.find(".git", { upward = true, path = path })[1]
	if found then return vim.fs.dirname(found) end
	local dir = vim.fs.dirname(path)
	return (dir and dir ~= "") and dir or vim.fn.getcwd()
end

return M
