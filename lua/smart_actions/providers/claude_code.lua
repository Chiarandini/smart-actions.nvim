-- Provider: Claude Code CLI (`claude -p ... --output-format stream-json`).
--
-- Event shape (verified against CLI v2.1.x):
--   Every stdout line is a JSON object. We extract text from:
--     { type = "stream_event",
--       event = { type = "content_block_delta",
--                 delta = { type = "text_delta", text = "..." } } }
--   and surface errors from { type = "result", is_error = true }.
-- Everything else (system/rate_limit_event/assistant/message_stop) is
-- metadata we don't need.
--
-- Auth: inherits the local Claude Code session (subscription or API key —
-- whatever the CLI has). No key handling here.

local streaming = require("smart_actions.streaming")

local M = {
	id               = "claude_code",
	display_name     = "Claude Code (local CLI)",
	handles_natively = { "claude_md", "agents_md" },
}

function M.probe()
	if vim.fn.executable("claude") == 1 then return true end
	return false, "`claude` not on $PATH"
end

local function parse_line(line)
	if line == "" then return nil end
	local ok, evt = pcall(vim.json.decode, line)
	if not ok or type(evt) ~= "table" then return nil end
	if evt.type == "stream_event" and evt.event
		and evt.event.type == "content_block_delta"
		and evt.event.delta and evt.event.delta.type == "text_delta" then
		return evt.event.delta.text
	end
	if evt.type == "result" and evt.is_error then
		return nil, evt.result or ("CLI error (subtype=" .. tostring(evt.subtype) .. ")")
	end
	return nil
end

function M.stream(req, cb)
	local prompt_parts = {}
	for _, m in ipairs(req.messages or {}) do
		prompt_parts[#prompt_parts + 1] = m.content or ""
	end
	local cmd = {
		"claude", "-p", table.concat(prompt_parts, "\n\n"),
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
	}
	if req.system and req.system ~= "" then
		table.insert(cmd, "--append-system-prompt")
		table.insert(cmd, req.system)
	end
	for _, a in ipairs((req.opts or {}).extra_args or {}) do
		table.insert(cmd, a)
	end

	return streaming.run_subprocess({
		cmd        = cmd,
		stdin      = false,
		parse_line = parse_line,
		name       = "claude",
		timeout_ms = req.timeout_ms,
	}, cb)
end

return M
