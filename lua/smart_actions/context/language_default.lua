-- Per-filetype baseline style nudges. Lowest priority so it's always the
-- first block dropped on budget pressure. gather returns "" for filetypes
-- we don't have rules for, which assemble() treats as "skip".

local RULES = {
	lua        = "Prefer `local` for module tables. No semicolons unless disambiguating. snake_case for locals.",
	python     = "Type hints on public functions. No bare `except:`. PEP 8 naming. f-strings over %.",
	rust       = "Prefer `Result<T,E>` over panic. Iterators over indexing. `?` for error propagation.",
	go         = "Explicit error returns. No panics in library code. Interface names end in -er.",
	javascript = "Prefer `const` over `let`. Strict equality (`===`).",
	typescript = "Prefer `const`. Strict types; avoid `any` unless justified. Readonly where possible.",
	c          = "Avoid unchecked malloc. Prefer `size_t` for sizes. `const` pointers where possible.",
	cpp        = "RAII over manual new/delete. `const` correctness. Prefer std:: containers.",
	sh         = "Quote all variable expansions. `set -euo pipefail`. POSIX where portability matters.",
	bash       = "Quote all variable expansions. `set -euo pipefail`. `[[ ]]` over `[ ]`.",
	tex        = "Keep markup minimal; prefer semantic macros over direct formatting.",
	latex      = "Keep markup minimal; prefer semantic macros over direct formatting.",
}

return {
	id       = "language_default",
	priority = 10,

	detect = function(_root) return true end,

	gather = function(scope)
		local bufnr = scope and scope.bufnr
		if not bufnr then return "" end
		local ft = vim.bo[bufnr].filetype
		local rule = RULES[ft]
		if not rule then return "" end
		return string.format("Language: %s\n%s", ft, rule)
	end,
}
