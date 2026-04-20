-- Provider registry + selection. Built-ins (claude_code, anthropic) are
-- preloaded by smart_actions.setup(). Third-party plugins can call
-- M.register() to add their own.
--
-- Provider contract:
--   { id, display_name, handles_natively? = {...},
--     probe() -> ok: boolean, err: string|nil,
--     stream(req, cb) -> cancel_fn
--       -- req: { system, messages, opts }
--       --   opts = config.provider_config[id] (or {})
--       -- cb:  { on_text(chunk), on_done(), on_error(err) }
--   }

local M = require("smart_actions.registry").new({
	module_prefix = "smart_actions.providers",
	kind          = "provider",
})

local active_cancel = nil

function M.preload_builtins()
	M.preload({ "claude_code", "anthropic", "openai" })
end

--- Resolve the provider to use right now. Honors config.provider override,
--- else walks config.probe_order (default = registration order), returning
--- the first that probes ok.
function M.active()
	local config = require("smart_actions.config").get()
	if config.provider then
		local p = M.get(config.provider)
		if not p then return nil, "provider not registered: " .. config.provider end
		local ok, err = p.probe()
		if not ok then return nil, err end
		return p
	end
	local order = config.probe_order or M.ids()
	local last_err
	for _, id in ipairs(order) do
		local p = M.get(id)
		if p then
			local ok, err = p.probe()
			if ok then return p end
			last_err = err
		end
	end
	return nil, last_err or "no provider available"
end

--- Stream from the active provider. Returns the cancel fn.
function M.stream(req, callbacks)
	local p, err = M.active()
	if not p then
		if callbacks and callbacks.on_error then callbacks.on_error(err) end
		return function() end
	end
	local config = require("smart_actions.config").get()
	req.opts = (config.provider_config or {})[p.id] or {}
	-- Threaded through to streaming.run_subprocess so hangs auto-cancel
	-- instead of leaving the busy spinner stuck forever.
	req.timeout_ms = config.provider_timeout_ms
	active_cancel = p.stream(req, callbacks)
	return active_cancel
end

function M.cancel_active()
	if active_cancel then
		pcall(active_cancel)
		active_cancel = nil
	end
end

return M
