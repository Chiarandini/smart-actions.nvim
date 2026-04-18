-- Streaming JSON object extractor.
--
-- Brace-counts across a token stream, emitting each complete top-level
-- object the instant its closing brace arrives. Tolerant to:
--   - preamble before the first {
--   - markdown code fences (```json ... ```)
--   - pretty-printed objects (newlines inside values)
--   - strings containing { or } (tracked via in-string flag + \ escape)
--   - malformed objects (fail-silently on vim.json.decode error)
--
-- Safeguards:
--   - if buffer grows past max_buffer_bytes with no complete object extracted,
--     the parser resets (and logs a warning via cb.on_warn if provided). This
--     prevents unbounded growth when the AI emits non-JSON garbage forever.

local M = {}

local Parser = {}
Parser.__index = Parser

--- Create a parser.
--- opts = { on_object = fn(obj), on_warn? = fn(msg), max_buffer_bytes? = 65536 }
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		buf             = "",
		depth           = 0,
		in_string       = false,
		escape          = false,
		obj_start       = nil,      -- 1-based index into buf where current object began
		scan_pos        = 1,        -- resume scanning here on next feed
		on_object       = opts.on_object,
		on_warn         = opts.on_warn,
		max_buffer      = opts.max_buffer_bytes or 65536,
		objects         = {},
	}, Parser)
end

function Parser:_reset_parse_state()
	self.depth     = 0
	self.in_string = false
	self.escape    = false
	self.obj_start = nil
end

function Parser:feed(chunk)
	if not chunk or chunk == "" then return end
	self.buf = self.buf .. chunk

	-- Safeguard: runaway buffer without any object completion.
	if self.depth == 0 and #self.buf > self.max_buffer then
		if self.on_warn then
			self.on_warn(string.format("stream_json: discarding %d-char buffer (no objects)", #self.buf))
		end
		self.buf      = ""
		self.scan_pos = 1
		self:_reset_parse_state()
		return
	end

	local i = self.scan_pos
	while i <= #self.buf do
		local c = self.buf:byte(i)
		-- 0x22 = "  0x5C = \  0x7B = {  0x7D = }
		if self.in_string then
			if self.escape then
				self.escape = false
			elseif c == 0x5C then
				self.escape = true
			elseif c == 0x22 then
				self.in_string = false
			end
		else
			if c == 0x22 then
				self.in_string = true
			elseif c == 0x7B then
				if self.depth == 0 then self.obj_start = i end
				self.depth = self.depth + 1
			elseif c == 0x7D then
				if self.depth > 0 then
					self.depth = self.depth - 1
					if self.depth == 0 and self.obj_start then
						local obj_str = self.buf:sub(self.obj_start, i)
						local ok, obj = pcall(vim.json.decode, obj_str)
						if ok and type(obj) == "table" then
							self.objects[#self.objects + 1] = obj
							if self.on_object then self.on_object(obj) end
						elseif self.on_warn then
							self.on_warn("stream_json: json.decode failed on balanced object")
						end
						-- Chop past this object so buf doesn't grow unboundedly.
						self.buf = self.buf:sub(i + 1)
						self.scan_pos = 1
						self:_reset_parse_state()
						i = 0 -- post-increment -> 1
					end
				end
				-- Stray } outside any object: ignore (preamble noise).
			end
		end
		i = i + 1
	end
	self.scan_pos = i
end

--- Call at end-of-stream. Returns the accumulated objects list.
function Parser:finalize()
	-- Nothing to flush — partial objects are discarded.
	return self.objects
end

M.Parser = Parser

return M
