-- luanti_testkit/api.lua
-- Public API: run tests, register suites/tests, manage context

--- Build a test context for a given test
-- @param suite_name string
-- @param test_name string
-- @param player_name string|nil  Optional player name
-- @param args table|nil         Optional extra args
-- @return table ctx
local function build_context(suite_name, test_name, player_name, args)
	local ctx = {
		suite = suite_name,
		test = test_name,
		player_name = player_name or "",
		player = nil,
		args = args or {},
		_skipped = false,
		_failed = false,
		_done = false,
		_logs = {},
	}

	-- Get player object if online
	if ctx.player_name and ctx.player_name ~= "" then
		ctx.player = minetest.get_player_by_name(ctx.player_name)
	end

	-- Assertions
	ctx.assert = luanti_testkit._make_assertions(function(status, message)
		if status == "FAIL" then
			ctx._failed = true
			ctx._fail_message = message
		end
	end)

	-- Helpers
	ctx.helpers = luanti_testkit._make_helpers(function(status, message)
		if status == "FAIL" then
			ctx._failed = true
			ctx._fail_message = message
		end
	end)

	-- Skip function
	function ctx.skip(reason)
		ctx._skipped = true
		ctx._skip_reason = reason or "skipped"
	end

	-- Log function
	function ctx.log(message)
		table.insert(ctx._logs, tostring(message))
		minetest.log("action", "[luanti_testkit.test." .. suite_name .. "." .. test_name .. "] " .. tostring(message))
	end

	-- Report result (internal)
	function ctx.report(status, message, details)
		luanti_testkit._record_result({
			suite = suite_name,
			name = test_name,
			status = status,
			message = message or "",
			details = details or ctx._logs,
			duration_ms = 0,
		})
	end

	return ctx
end

--- Run a single test by its full name ("suite.test")
-- @param full_name string  e.g. "smoke.testkit_loaded"
-- @param context table|nil  Optional: {player_name = string, args = table}
-- @return table result
function luanti_testkit.run_test(full_name, context)
	context = context or {}
	local player_name = context.player_name
	local args = context.args

	local test_def, suite_name, test_name = luanti_testkit._find_test(full_name)
	if not test_def then
		local res = {
			suite = "?",
			name = full_name,
			status = "ERROR",
			message = "Test not found: " .. full_name,
			details = {},
			duration_ms = 0,
		}
		luanti_testkit._record_result(res)
		return res
	end

	local start_time = minetest.get_us_time()
	local ctx = build_context(suite_name, test_name, player_name, args)

	local ok, err = xpcall(function()
		test_def.fn(ctx)
	end, function(e)
		-- debug.traceback is not available in Luanti sandbox, use tostring
		return tostring(e)
	end)

	local elapsed_ms = math.floor((minetest.get_us_time() - start_time) / 1000)

	local result
	if not ok then
		-- Lua error in test (uncaught exception)
		result = {
			suite = suite_name,
			name = test_name,
			status = "ERROR",
			message = tostring(err or "unknown error"):sub(1, 200),
			details = ctx._logs,
			duration_ms = elapsed_ms,
		}
	elseif ctx._skipped then
		result = {
			suite = suite_name,
			name = test_name,
			status = "SKIP",
			message = ctx._skip_reason or "skipped",
			details = ctx._logs,
			duration_ms = elapsed_ms,
		}
	elseif ctx._failed then
		result = {
			suite = suite_name,
			name = test_name,
			status = "FAIL",
			message = ctx._fail_message or "assertion failed",
			details = ctx._logs,
			duration_ms = elapsed_ms,
		}
	else
		result = {
			suite = suite_name,
			name = test_name,
			status = "PASS",
			message = "OK",
			details = ctx._logs,
			duration_ms = elapsed_ms,
		}
	end

	luanti_testkit._record_result(result)
	return result
end

--- Run all tests in a suite
-- @param suite_name string
-- @param context table|nil
-- @return table Array of results
function luanti_testkit.run_suite(suite_name, context)
	local suite = luanti_testkit._find_suite(suite_name)
	if not suite then
		minetest.log("action", "[luanti_testkit] Suite not found: " .. suite_name)
		return {}
	end

	local results = {}
	local sorted = {}
	for _, t in pairs(suite.tests) do
		table.insert(sorted, t)
	end
	table.sort(sorted, function(a, b) return a.full_name < b.full_name end)

	for _, t in ipairs(sorted) do
		local res = luanti_testkit.run_test(t.full_name, context)
		table.insert(results, res)
	end
	return results
end

--- Run all registered tests
-- @param context table|nil
-- @return table Array of results
function luanti_testkit.run_all(context)
	luanti_testkit.reset_report()
	local rep = luanti_testkit.get_report()
	rep.started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

	local results = {}
	local suites_list = {}
	for _, s in pairs(luanti_testkit._suites) do
		table.insert(suites_list, s)
	end
	table.sort(suites_list, function(a, b) return a.name < b.name end)

	for _, s in ipairs(suites_list) do
		minetest.log("action", "[luanti_testkit] Running suite: " .. s.name)
		local suite_results = luanti_testkit.run_suite(s.name, context)
		for _, r in ipairs(suite_results) do
			table.insert(results, r)
		end
	end

	rep.finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	luanti_testkit.print_report()
	luanti_testkit.save_report_if_possible()

	return results
end

--- Parse a test spec string into suites/tests to run.
-- Supports: "suite", "suite.test", "suite,suite2", "suite.test1,suite.test2"
-- @param spec string
-- @return table {{suite, test}|nil}  nil means run all
function luanti_testkit._parse_spec(spec)
	if not spec or spec == "" or spec == "all" then
		return nil -- run all
	end

	local items = {}
	for part in spec:gmatch("[^,]+") do
		part = part:match("^%s*(.-)%s*$") -- trim
		local sname, tname = part:match("^([^%.]+)%.(.+)$")
		if sname and tname then
			table.insert(items, {suite = sname, test = tname, full = part})
		else
			table.insert(items, {suite = part, test = nil, full = part})
		end
	end
	return items
end

--- Run tests matching a spec
-- @param spec string  "suite.test", "suite", "suite1,suite2.test"
-- @param context table|nil
-- @return table results
function luanti_testkit.run_spec(spec, context)
	context = context or {}
	local player_name = context.player_name
	local args = context.args

	local parsed = luanti_testkit._parse_spec(spec)
	if not parsed then
		return luanti_testkit.run_all(context)
	end

	luanti_testkit.reset_report()
	local rep = luanti_testkit.get_report()
	rep.started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local all_results = {}

	for _, item in ipairs(parsed) do
		if item.test then
			local res = luanti_testkit.run_test(item.full, context)
			table.insert(all_results, res)
		else
			local suite_results = luanti_testkit.run_suite(item.suite, context)
			for _, r in ipairs(suite_results) do
				table.insert(all_results, r)
			end
		end
	end

	rep.finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	luanti_testkit.print_report()
	luanti_testkit.save_report_if_possible()

	return all_results
end

-- Chat commands for running tests

minetest.register_chatcommand("ltk_run", {
	params = "<suite_or_test> [player] [args...]",
	description = "Run a test or suite by name. Examples: ltk_run smoke, ltk_run perfectworld.compat_furniture_fallbacks_are_semantic",
	privs = {server = true},
	func = function(_, param)
		if not param or param == "" then
			return false, "Usage: /ltk_run <suite_or_test> [player]"
		end
		local spec, pname = param:match("^(%S+)%s+(%S+)$")
		if not spec then
			spec = param
			pname = nil
		end

		local context = {}
		if pname then
			context.player_name = pname
		end

		local parsed = luanti_testkit._parse_spec(spec)
		if not parsed then
			luanti_testkit.run_all(context)
			return true, "Running all tests. See server console."
		end

		luanti_testkit.run_spec(spec, context)
		minetest.log("action", "[luanti_testkit] /ltk_run " .. param)
		return true, "Tests running. See server console for results."
	end,
})

minetest.register_chatcommand("ltk_all", {
	params = "[player]",
	description = "Run all registered tests. Optionally provide player name.",
	privs = {server = true},
	func = function(_, param)
		local context = {}
		if param and param ~= "" then
			context.player_name = param
		end
		luanti_testkit.run_all(context)
		return true, "Running all tests with player '" .. (context.player_name or "none") .. "'. See server console."
	end,
})

minetest.register_chatcommand("ltk_suite", {
	params = "<suite_name> [player]",
	description = "Run a specific test suite.",
	privs = {server = true},
	func = function(_, param)
		if not param or param == "" then
			return false, "Usage: /ltk_suite <suite_name> [player]"
		end
		local suite_name, pname = param:match("^(%S+)%s+(%S+)$")
		if not suite_name then
			suite_name = param
			pname = nil
		end
		local context = {}
		if pname then context.player_name = pname end
		luanti_testkit.run_suite(suite_name, context)
		luanti_testkit.print_report()
		return true, "Suite '" .. suite_name .. "' executed. See server console."
	end,
})

minetest.log("action", "[luanti_testkit] api loaded")
