-- Provider: OpenAI-compatible /chat/completions endpoints via curl + SSE.
--
-- This single module covers a long list of services that all speak OpenAI's
-- chat-completions wire format:
--
--   OpenAI        base_url = "https://api.openai.com/v1"
--   Ollama        base_url = "http://localhost:11434/v1"
--   LM Studio     base_url = "http://localhost:1234/v1"
--   OpenRouter    base_url = "https://openrouter.ai/api/v1"
--   Groq          base_url = "https://api.groq.com/openai/v1"
--   Together      base_url = "https://api.together.xyz/v1"
--   DeepInfra     base_url = "https://api.deepinfra.com/v1/openai"
--   xAI (Grok)    base_url = "https://api.x.ai/v1"
--   Gemini-compat base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
--
-- SSE event shape (OpenAI):
--   data: {"choices":[{"delta":{"content":"..."}}]}
--   ...
--   data: [DONE]
--
-- API key resolution order for each request:
--   1. req.opts.api_key (inline — e.g. from lua/secrets.lua via provider_config)
--   2. os.getenv(req.opts.api_key_env)   (default env var = OPENAI_API_KEY)
--   3. (none) -> probe fails
--
-- Multiple endpoints simultaneously: require("smart_actions.providers.openai").define({
--   id = "ollama", base_url = "http://localhost:11434/v1", model = "qwen3-coder",
-- }) returns a provider you can then pass to providers.register().

local streaming = require("smart_actions.streaming")

local function resolve_key(opts)
	if opts.api_key and opts.api_key ~= "" then return opts.api_key end
	local env = opts.api_key_env
	if env and env ~= "" then
		local v = os.getenv(env)
		if v and v ~= "" then return v end
	end
	return nil
end

--- True when the user expects the endpoint to require a bearer token. A
--- user who sets `api_key_env = ""` AND leaves inline `api_key` empty is
--- explicitly opting out of auth (local Ollama / LM Studio / LocalAI /
--- llama.cpp — none require a real token). Everyone else gets the
--- "missing key" error from probe.
local function needs_auth(opts)
	if opts.api_key_env == "" and (opts.api_key == nil or opts.api_key == "") then
		return false
	end
	return true
end

--- OpenAI SSE parser. Returns (text_chunk, error) matching streaming.lua's
--- contract. Non-text events (role-only deltas, tool_calls, finish_reason)
--- are silently dropped.
local function parse_line(line)
	local data = line:match("^data:%s*(.*)$")
	if not data or data == "" or data == "[DONE]" then return nil end
	local ok, evt = pcall(vim.json.decode, data)
	if not ok or type(evt) ~= "table" then return nil end
	local ch = evt.choices and evt.choices[1]
	if ch and ch.delta and type(ch.delta.content) == "string" then
		return ch.delta.content
	end
	if evt.error then
		local e = evt.error
		return nil, (e.type or "error") .. ": " .. (e.message or "unknown")
	end
	return nil
end

local function build_provider(spec)
	spec = vim.tbl_deep_extend("keep", spec or {}, {
		id            = "openai",
		display_name  = nil,
		base_url      = "https://api.openai.com/v1",
		model         = "gpt-5",
		api_key_env   = "OPENAI_API_KEY",
		max_tokens    = 4096,
		extra_headers = {},
	})
	spec.display_name = spec.display_name or ("OpenAI-compatible (" .. spec.id .. ")")

	local provider = {
		id               = spec.id,
		display_name     = spec.display_name,
		handles_natively = {},
	}

	--- Merge order: spec (factory defaults) <- user provider_config[id] <- req.opts.
	local function effective(req_opts)
		local cfg = require("smart_actions.config").get()
		local user = (cfg.provider_config or {})[spec.id] or {}
		local m = vim.tbl_deep_extend("force", spec, user)
		if req_opts then m = vim.tbl_deep_extend("force", m, req_opts) end
		return m
	end

	function provider.probe()
		local m = effective(nil)
		if needs_auth(m) and not resolve_key(m) then
			local hint = (m.api_key_env and m.api_key_env ~= "")
				and ("$" .. m.api_key_env) or "inline api_key"
			return false, string.format(
				"%s: no API key (%s not set, and provider_config.%s.api_key is empty)",
				spec.id, hint, spec.id)
		end
		if vim.fn.executable("curl") == 0 then
			return false, "curl not on $PATH"
		end
		return true
	end

	function provider.stream(req, cb)
		local m = effective(req.opts)
		local key = resolve_key(m)
		if needs_auth(m) and not key then
			vim.schedule(function()
				if cb and cb.on_error then cb.on_error(spec.id .. ": no API key") end
			end)
			return function() end
		end

		-- Merge `system` into the messages list the OpenAI way (role="system"
		-- at the start). Anthropic has a dedicated `system` field; OpenAI
		-- does not.
		local messages = {}
		if req.system and req.system ~= "" then
			messages[#messages + 1] = { role = "system", content = req.system }
		end
		for _, msg in ipairs(req.messages or {}) do
			messages[#messages + 1] = msg
		end

		local body = vim.json.encode({
			model      = m.model,
			messages   = messages,
			stream     = true,
			max_tokens = m.max_tokens,
		})

		local url = (m.base_url or ""):gsub("/+$", "") .. "/chat/completions"
		local cmd = {
			"curl", "-sSN", "--no-buffer",
			url,
			"-H", "Content-Type: application/json",
			"--data-binary", "@-",
		}
		if key then
			cmd[#cmd + 1] = "-H"
			cmd[#cmd + 1] = "Authorization: Bearer " .. key
		end
		for h, v in pairs(m.extra_headers or {}) do
			cmd[#cmd + 1] = "-H"
			cmd[#cmd + 1] = tostring(h) .. ": " .. tostring(v)
		end

		return streaming.run_subprocess({
			cmd        = cmd,
			stdin      = body,
			parse_line = parse_line,
			name       = spec.id,
			timeout_ms = req.timeout_ms,
		}, cb)
	end

	return provider
end

-- Default module export = the canonical "openai" provider (points at
-- api.openai.com, reads $OPENAI_API_KEY). Extra `.define(spec)` factory
-- returns a new provider instance for any other OpenAI-compatible endpoint.
local M = build_provider({})
M.define = function(spec) return build_provider(spec or {}) end

return M
