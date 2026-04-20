-- Scope resolution. Returns a Scope with the primary payload (what the AI
-- sees as "the code") and trigger metadata (cursor row/col, originating
-- file, line text, symbol, node kind, diagnostics, visual range) — so even
-- `project` scope knows exactly where the user invoked the action.

local M = {}

M.kinds = { "line", "function", "file", "folder", "project", "auto", "visual" }

-- ─── Treesitter helpers ────────────────────────────────────────────────

local IDENTIFIER_KINDS = {
	identifier = true, property_identifier = true, field_identifier = true,
	shorthand_property_identifier = true, type_identifier = true,
	method_name = true, name = true,
}

local FUNCTION_KINDS = {
	function_declaration = true, function_definition = true,
	function_statement  = true, ["function"]        = true,
	method_definition   = true, arrow_function      = true,
	local_function      = true, function_expression = true,
	method              = true, function_item       = true,  -- rust
}

local function ts_node_at(bufnr, row, col)
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
	if ok and node then return node end
	-- Parser may be attached but not yet parsed (common in headless or when
	-- TS hasn't been driven by highlighting). Force a parse and retry.
	local pok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not (pok and parser) then return nil end
	pcall(function() parser:parse() end)
	ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
	return ok and node or nil
end

local function ts_climb(node, kinds)
	while node do
		if kinds[node:type()] then return node end
		node = node:parent()
	end
end

local function ts_text(node, bufnr)
	local ok, t = pcall(vim.treesitter.get_node_text, node, bufnr)
	return ok and t or nil
end

-- ─── Diagnostics ───────────────────────────────────────────────────────

--- Diagnostics in `bufnr` whose range overlaps the inclusive row span.
local function overlap_diagnostics(bufnr, start_row, end_row)
	local out = {}
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
		local dl, del = d.lnum or 0, d.end_lnum or d.lnum or 0
		if dl <= end_row and del >= start_row then out[#out + 1] = d end
	end
	return out
end

--- Diagnostics from every loaded buffer whose path is in `paths`. LSPs only
--- analyze loaded buffers, so unloaded files yield nothing.
local function loaded_buffer_diagnostics(paths)
	local want = {}
	for _, p in ipairs(paths or {}) do want[p] = true end
	local out = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name ~= "" and want[name] then
				for _, d in ipairs(vim.diagnostic.get(bufnr)) do
					d.bufnr = d.bufnr or bufnr
					out[#out + 1] = d
				end
			end
		end
	end
	return out
end

-- ─── File enumeration (folder/project) ─────────────────────────────────

local DEFAULT_IGNORE = { ".git", "node_modules", ".venv", "venv",
	"__pycache__", "target", "build", "dist", ".idea", ".vscode" }

local function git_root(start_path)
	local found = vim.fs.find(".git", { upward = true, path = start_path })[1]
	return found and vim.fs.dirname(found) or nil
end

--- Returns (paths, files_omitted). files_omitted is -1 when the enumeration
--- hit a cap or timed out before rg finished (exact overflow unknown).
---
--- Streams `rg --files` stdout via vim.system, accumulating paths until
--- max_files is reached, at which point the rg process is SIGTERM'd. The
--- main-thread wait is bounded by timeout_ms so nvim never freezes on a
--- pathological repo. Returns nil if rg isn't on $PATH or errored — caller
--- falls back to the pure-Lua walker.
local function list_files_rg(root, max_files, timeout_ms)
	if vim.fn.executable("rg") == 0 then return nil, 0 end

	local out = {}
	local buf = ""
	local done, killed = false, false
	local exit_code = nil
	local handle

	handle = vim.system(
		{ "rg", "--files", "--hidden", "--glob", "!.git", root },
		{
			text = true,
			stdout = function(_, chunk)
				if killed or not chunk then return end
				buf = buf .. chunk
				while true do
					local nl = buf:find("\n", 1, true)
					if not nl then break end
					local line = buf:sub(1, nl - 1)
					buf = buf:sub(nl + 1)
					if line ~= "" then
						out[#out + 1] = line
						if #out >= max_files then
							killed = true
							pcall(function() handle:kill(15) end)
							return
						end
					end
				end
			end,
			stderr = false,
		},
		function(result) exit_code = result.code; done = true end
	)

	vim.wait(timeout_ms or 500, function() return done or killed end, 20)

	if not done and not killed then
		-- Timeout: kill rg and keep what we've enumerated so far.
		killed = true
		pcall(function() handle:kill(15) end)
	end

	-- Flush a trailing non-newline-terminated line (rare but possible if
	-- we killed rg mid-flush).
	if buf ~= "" and #out < max_files then
		out[#out + 1] = buf
	end

	-- rg finished cleanly with a non-zero exit — treat as error, let the
	-- walker fallback take over. (rg --files returns 0 even for empty
	-- directories, so non-zero here is a real failure.)
	if done and not killed and exit_code and exit_code ~= 0 then
		return nil, 0
	end
	return out, killed and -1 or 0
end

local function list_files_walk(root, max_files)
	max_files = max_files or 2000
	local out, hit_cap = {}, false
	local ignore = {}
	for _, d in ipairs(DEFAULT_IGNORE) do ignore[d] = true end

	local function walk(dir)
		if #out >= max_files then hit_cap = true; return end
		local ok, iter = pcall(vim.fs.dir, dir)
		if not ok then return end
		for name, kind in iter do
			if not ignore[name] then
				local p = dir .. "/" .. name
				if kind == "file" then
					out[#out + 1] = p
					if #out >= max_files then hit_cap = true; return end
				elseif kind == "directory" then
					walk(p)
					if hit_cap then return end
				end
			end
		end
	end

	walk(root)
	return out, hit_cap and -1 or 0
end

local function list_files(root, opts)
	local max_files   = opts and opts.max_files or 2000
	local timeout_ms  = opts and opts.file_scan_timeout_ms or 500
	local rg, omitted = list_files_rg(root, max_files, timeout_ms)
	if rg then return rg, omitted end
	return list_files_walk(root, max_files)
end

local function read_file_safe(path, byte_cap)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read(byte_cap or 200000)
	f:close()
	return data
end

-- ─── Payload assembly ──────────────────────────────────────────────────

--- Append a truncation marker if text exceeds max_chars. Returns (text, truncated).
local function cap_text(text, max_chars)
	if not text or #text <= max_chars then return text or "", false end
	local head = text:sub(1, math.max(0, max_chars - 80))
	return head .. string.format("\n\n-- + %d chars truncated (budget %d) --\n",
		#text - #head, max_chars), true
end

--- Concat files up to max_chars at file-boundaries. `files` is always complete
--- (even when text is truncated) — each entry carries its individual-file
--- truncation flag so callers know what was skipped.
local function assemble_multi_file(paths, max_chars, root, opts)
	local text_parts, files, total, omitted = {}, {}, 0, 0
	local byte_cap = opts and opts.max_file_bytes or 200000

	for _, p in ipairs(paths) do
		local rel = p
		if root and p:sub(1, #root + 1) == root .. "/" then rel = p:sub(#root + 2) end
		local data = read_file_safe(p, byte_cap)
		if data then
			local block = string.format("\n-- FILE: %s --\n%s\n", rel, data)
			if total + #block > max_chars then
				files[#files + 1] = { path = p, text = data, truncated = true }
				omitted = omitted + 1
			else
				text_parts[#text_parts + 1] = block
				files[#files + 1] = { path = p, text = data, truncated = false }
				total = total + #block
			end
		end
	end

	if omitted > 0 then
		text_parts[#text_parts + 1] = string.format(
			"\n-- + %d file(s) omitted (payload budget %d chars) --\n", omitted, max_chars)
	end
	return table.concat(text_parts, ""), files
end

local function files_capped_notice(files_omitted, max_files)
	if files_omitted == 0 then return nil end
	if files_omitted > 0 then
		return string.format(
			"-- + %d file(s) beyond max_files=%d were not listed --\n",
			files_omitted, max_files)
	end
	return string.format(
		"-- file enumeration capped at max_files=%d (more exist) --\n", max_files)
end

-- ─── Trigger metadata ──────────────────────────────────────────────────

--- True when `d`'s range contains `col`. `end_col` is treated as exclusive;
--- if missing / <= `col`, the diagnostic is treated as a single-char mark
--- at `d.col` and matches only when `col == d.col`.
local function diag_overlaps_col(d, col)
	local d_col = d.col or 0
	local d_end = d.end_col
	if not d_end or d_end <= d_col then return col == d_col end
	return col >= d_col and col < d_end
end

--- Split `diags` into (at_col, line_only) where `at_col` = diagnostics whose
--- range contains the cursor column and `line_only` = the rest.
local function partition_diagnostics_at_col(diags, col)
	local at, other = {}, {}
	for _, d in ipairs(diags) do
		if diag_overlaps_col(d, col) then at[#at + 1] = d else other[#other + 1] = d end
	end
	return at, other
end

local function trigger_metadata(bufnr, visual_range)
	local pos = vim.api.nvim_win_get_cursor(0)
	local row, col = pos[1] - 1, pos[2]

	local symbol, node_kind = nil, nil
	local node = ts_node_at(bufnr, row, col)
	if node and IDENTIFIER_KINDS[node:type()] then
		symbol, node_kind = ts_text(node, bufnr), node:type()
	elseif node then
		node_kind = node:type()
	end

	local line_diags = vim.diagnostic.get(bufnr, { lnum = row })
	local at_col, line_only = partition_diagnostics_at_col(line_diags, col)

	return {
		file                = vim.api.nvim_buf_get_name(bufnr),
		cursor              = { row = row, col = col },
		line_text           = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or "",
		symbol              = symbol,
		node_kind           = node_kind,
		diagnostics         = line_diags,   -- all diagnostics on cursor LINE (back-compat)
		diagnostics_at_col  = at_col,       -- subset whose range contains cursor COLUMN
		diagnostics_on_line = line_only,    -- `diagnostics` minus `diagnostics_at_col`
		visual              = visual_range,
	}
end

-- ─── Scope factory ─────────────────────────────────────────────────────

--- Build a Scope with empty-list defaults for file/diagnostic fields.
--- Individual resolvers override only what they need.
local function make_scope(fields)
	fields.files         = fields.files         or {}
	fields.files_omitted = fields.files_omitted or 0
	fields.truncated     = fields.truncated     or false
	return fields
end

-- ─── Resolvers ─────────────────────────────────────────────────────────

local function resolve_line(bufnr, trg, opts)
	local row = trg.cursor.row
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local text, truncated = cap_text(line, opts.max_payload_chars or 6000)
	return make_scope {
		label = "line", bufnr = bufnr, text = text, truncated = truncated,
		start = { row = row, col = 0 }, end_ = { row = row, col = #line },
		diagnostics = overlap_diagnostics(bufnr, row, row),
		trigger = trg,
	}
end

--- Current paragraph (used as fallback when no enclosing function found).
local function paragraph_range(bufnr, row)
	local total = vim.api.nvim_buf_line_count(bufnr)
	local s, e = row, row
	while s > 0 and not (vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1] or ""):match("^%s*$") do
		s = s - 1
	end
	while e < total - 1 and not (vim.api.nvim_buf_get_lines(bufnr, e + 1, e + 2, false)[1] or ""):match("^%s*$") do
		e = e + 1
	end
	return s, e
end

local function resolve_function(bufnr, trg, opts)
	local cap = opts.max_payload_chars or 6000
	local node = ts_node_at(bufnr, trg.cursor.row, trg.cursor.col)
	local func = node and ts_climb(node, FUNCTION_KINDS) or nil
	local r1, c1, r2, c2
	if func then
		r1, c1, r2, c2 = func:range()
	else
		r1, r2 = paragraph_range(bufnr, trg.cursor.row)
		c1, c2 = 0, 0
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, r1, r2 + 1, false)
	local text, truncated = cap_text(table.concat(lines, "\n"), cap)
	return make_scope {
		label = "function", bufnr = bufnr, text = text, truncated = truncated,
		start = { row = r1, col = c1 }, end_ = { row = r2, col = c2 },
		diagnostics = overlap_diagnostics(bufnr, r1, r2),
		trigger = trg,
	}
end

local function resolve_file(bufnr, trg, opts)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local text, truncated = cap_text(table.concat(lines, "\n"), opts.max_payload_chars or 6000)
	return make_scope {
		label = "file", bufnr = bufnr, text = text, truncated = truncated,
		start = { row = 0, col = 0 }, end_ = { row = #lines, col = 0 },
		diagnostics = overlap_diagnostics(bufnr, 0, math.max(0, #lines - 1)),
		trigger = trg,
	}
end

--- Shared folder/project resolver. Differs only in how `root` is derived.
--- For multi-file scopes the (start, end_) range covers the FULL cursor
--- buffer (not just row 0) so the applier's bounds check lets the AI's
--- diff target any line in the file the user was actually on. Applying
--- to files OTHER than the cursor buffer is not supported in v1.
local function resolve_multi_file(label, bufnr, trg, opts, root)
	local paths, files_omitted = list_files(root, opts)
	paths = paths or {}
	local max_chars = opts.max_payload_chars or 6000
	local text, files = assemble_multi_file(paths, max_chars, root, opts)
	local notice = files_capped_notice(files_omitted, opts.max_files or 2000)
	if notice then text = notice .. text end
	local last_row = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
	return make_scope {
		label = label, bufnr = bufnr, text = text,
		truncated = (#text > max_chars) or files_omitted ~= 0,
		start = { row = 0, col = 0 }, end_ = { row = last_row, col = 0 },
		files = files, files_omitted = files_omitted,
		diagnostics = loaded_buffer_diagnostics(paths),
		trigger = trg,
	}
end

local function buffer_dir(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
end

local function resolve_folder(bufnr, trg, opts)
	return resolve_multi_file("folder", bufnr, trg, opts, buffer_dir(bufnr))
end

local function resolve_project(bufnr, trg, opts)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local start = name ~= "" and name or vim.fn.getcwd()
	return resolve_multi_file("project", bufnr, trg, opts,
		git_root(start) or vim.fn.getcwd())
end

local function resolve_visual(bufnr, trg, opts)
	local vr = trg.visual
	if not vr then
		error("visual scope requires a visual selection (invoke from v/V/\\22 mode)")
	end
	local s, e = vr.start, vr.end_
	local lines
	if vr.mode == "V" then
		lines = vim.api.nvim_buf_get_lines(bufnr, s.row, e.row + 1, false)
	else
		local end_col = math.min(e.col,
			#(vim.api.nvim_buf_get_lines(bufnr, e.row, e.row + 1, false)[1] or ""))
		local ok, got = pcall(vim.api.nvim_buf_get_text,
			bufnr, s.row, s.col, e.row, end_col + 1, {})
		lines = ok and got or vim.api.nvim_buf_get_lines(bufnr, s.row, e.row + 1, false)
	end
	local text, truncated = cap_text(table.concat(lines or {}, "\n"), opts.max_payload_chars or 6000)
	return make_scope {
		label = "visual", bufnr = bufnr, text = text, truncated = truncated,
		start = { row = s.row, col = s.col }, end_ = { row = e.row, col = e.col },
		diagnostics = overlap_diagnostics(bufnr, s.row, e.row),
		trigger = trg,
	}
end

local function resolve_auto(bufnr, trg, opts)
	if trg.visual then return resolve_visual(bufnr, trg, opts) end
	local node = ts_node_at(bufnr, trg.cursor.row, trg.cursor.col)
	if node and ts_climb(node, FUNCTION_KINDS) then
		return resolve_function(bufnr, trg, opts)
	end
	return resolve_file(bufnr, trg, opts)
end

-- ─── Public API ────────────────────────────────────────────────────────

local RESOLVERS = {
	line         = resolve_line,
	["function"] = resolve_function,
	file         = resolve_file,
	folder       = resolve_folder,
	project      = resolve_project,
	visual       = resolve_visual,
	auto         = resolve_auto,
}

---@param name string  one of M.kinds
---@param opts table|nil  { bufnr, visual_range, max_payload_chars, max_files,
---                         max_file_bytes, file_scan_timeout_ms }
function M.get(name, opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local resolver = RESOLVERS[name]
	if not resolver then
		error("smart_actions.scope: unknown scope '" .. tostring(name) .. "'")
	end
	return resolver(bufnr, trigger_metadata(bufnr, opts.visual_range), opts)
end

return M
