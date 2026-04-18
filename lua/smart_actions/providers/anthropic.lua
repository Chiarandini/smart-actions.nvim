-- Provider: Anthropic Messages API via curl + streaming SSE.
--
-- SSE event shape:
--   event: content_block_delta
--   data: {"type":"content_block_delta","index":0,
--          "delta":{"type":"text_delta","text":"..."}}
--
-- API key resolution (matches NoetherVim's ai bundle):
--   1. lua/secrets.lua  { anthropic = { api_key = "..." } }
--   2. $ANTHROPIC_API_KEY
--
-- curl is invoked with -H "x-api-key: ..." which is visible in `ps` on the
-- local machine — same surface as env vars used by the official SDK.

local streaming = require("smart_actions.streaming")

local M = {
	id               = "anthropic",
	display_name     = "Anthropic Messages API",
	handles_natively = {},
}

local function resolve_key()
	local ok, secrets = pcall(require, "secrets")
	if ok and secrets and secrets.anthropic and secrets.anthropic.api_key then
		return secrets.anthropic.api_key
	end
	return os.getenv("ANTHROPIC_API_KEY")
end

function M.probe()
	if not resolve_key() then
		return false, "ANTHROPIC_API_KEY not set (and lua/secrets.lua has no anthropic.api_key)"
	end
	if vim.fn.executable("curl") == 0 then
		return false, "curl not on $PATH"
	end
	return true
end

local function parse_line(line)
	local data = line:match("^data:%s*(.*)$")
	if not data or data == "" or data == "[DONE]" then return nil end
	local ok, evt = pcall(vim.json.decode, data)
	if not ok or type(evt) ~= "table" then return nil end
	if evt.type == "content_block_delta" and evt.delta
		and evt.delta.type == "text_delta" then
		return evt.delta.text
	end
	if evt.type == "error" and evt.error then
		return nil, (evt.error.type or "error") .. ": " .. (evt.error.message or "")
	end
	return nil
end

function M.stream(req, cb)
	local key = resolve_key()
	if not key then
		vim.schedule(function()
			if cb and cb.on_error then cb.on_error("anthropic: no API key") end
		end)
		return function() end
	end
	local opts = req.opts or {}

	local body_json = vim.json.encode({
		model      = opts.model      or "claude-opus-4-7",
		max_tokens = opts.max_tokens or 4096,
		stream     = true,
		system     = req.system or "",
		messages   = req.messages or {},
	})

	return streaming.run_subprocess({
		cmd = {
			"curl", "-sSN", "--no-buffer",
			"https://api.anthropic.com/v1/messages",
			"-H", "content-type: application/json",
			"-H", "anthropic-version: 2023-06-01",
			"-H", "x-api-key: " .. key,
			"--data-binary", "@-",
		},
		stdin      = body_json,
		parse_line = parse_line,
		name       = "curl",
		timeout_ms = req.timeout_ms,
	}, cb)
end

return M
