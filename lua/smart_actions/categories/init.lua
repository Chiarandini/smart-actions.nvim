-- Category registry. Each category is a module under smart_actions.categories
-- returning:
--   { id, label, icon?,
--     build = function(scope, ctx) -> request, parser }

local M = require("smart_actions.registry").new({
	module_prefix = "smart_actions.categories",
	kind          = "category",
})

-- Keep the legacy "load" alias for callers that want a non-throwing load.
M.load = M.get

return M
