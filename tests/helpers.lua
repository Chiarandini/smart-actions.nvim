-- Minimal test helpers: a failure-counting check() and a scratch-buffer
-- scope helper. Keep this file deliberately small — tests should read like
-- specifications, not exercise their own framework.

local H = {}

H.failures = 0

function H.check(name, got, expected)
	local mismatch
	if type(got) ~= type(expected) then
		mismatch = true
	elseif type(got) == "table" then
		mismatch = vim.inspect(got) ~= vim.inspect(expected)
	else
		mismatch = got ~= expected
	end
	if mismatch then
		H.failures = H.failures + 1
		print("FAIL  " .. name)
		print("  expected: " .. vim.inspect(expected))
		print("  got:      " .. vim.inspect(got))
	else
		print("OK    " .. name)
	end
end

--- Create a scratch buffer with the given lines, call fn(buf), then delete it.
function H.with_buf(lines, fn)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local ok, err = pcall(fn, buf)
	vim.api.nvim_buf_delete(buf, { force = true })
	if not ok then error(err) end
end

function H.summary()
	print(string.rep("-", 40))
	if H.failures == 0 then
		print("all ok")
	else
		print(string.format("%d failure(s)", H.failures))
		vim.cmd("cq") -- non-zero exit when run via :qa!
	end
end

return H
