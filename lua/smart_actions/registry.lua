-- Generic id-keyed registry with lazy require-loading.
--
-- Used by providers, categories, and context so each has a consistent
-- surface: register / get / list / preload. `get` first checks what's
-- already registered, then falls back to `require(module_prefix .. "." .. id)`
-- and auto-registers what that module returned.

local M = {}

function M.new(cfg)
	assert(cfg and cfg.module_prefix and cfg.kind,
		"registry.new requires { module_prefix, kind }")
	local items = {}
	local order = {}
	local self = {}

	function self.register(item)
		assert(type(item) == "table" and item.id,
			cfg.kind .. " must be a table with an id")
		if items[item.id] then return end
		items[item.id] = item
		order[#order + 1] = item.id
	end

	function self.get(id)
		if items[id] then return items[id] end
		local ok, item = pcall(require, cfg.module_prefix .. "." .. id)
		if ok and type(item) == "table" then
			self.register(item)
			return item
		end
		return nil, item
	end

	function self.list()
		local out = {}
		for _, id in ipairs(order) do out[#out + 1] = items[id] end
		return out
	end

	function self.ids() return order end

	function self.preload(ids)
		for _, id in ipairs(ids or {}) do self.get(id) end
	end

	return self
end

return M
