-- luanti_testkit/reporter.lua
-- Test reporter: collects results, prints ASCII-safe reports, saves to file

local report = {
	results = {},
	started_at = nil,
	finished_at = nil,
	summary = {
		total = 0,
		passed = 0,
		failed = 0,
		skipped = 0,
		errors = 0,
	},
}

--- Reset the accumulated report
function luanti_testkit.reset_report()
	local old_started = report.started_at
	report = {
		results = {},
		started_at = old_started,  -- preserve started_at so print_report works
		finished_at = nil,
		summary = { total = 0, passed = 0, failed = 0, skipped = 0, errors = 0 },
	}
end

--- Restore a previously saved report (for test isolation)
function luanti_testkit._restore_report(saved)
	if not saved then return end
	report = saved
end

--- Get current report (read-only reference)
function luanti_testkit.get_report()
	return report
end

--- Record a single test result
-- @param result table {suite, name, status, message, details, duration_ms}
function luanti_testkit._record_result(result)
	table.insert(report.results, result)
	report.summary.total = report.summary.total + 1
	if result.status == "PASS" then
		report.summary.passed = report.summary.passed + 1
	elseif result.status == "FAIL" then
		report.summary.failed = report.summary.failed + 1
	elseif result.status == "SKIP" then
		report.summary.skipped = report.summary.skipped + 1
	else
		report.summary.errors = report.summary.errors + 1
	end
end

--- Print report to server console (ASCII-safe)
function luanti_testkit.print_report()
	local r = report
	if not r.started_at then
		minetest.log("action", "[luanti_testkit] No test report available.")
		return
	end

	minetest.log("action", string.rep("=", 60))
	minetest.log("action", "[luanti_testkit] TEST REPORT")
	minetest.log("action", "[luanti_testkit] Started: " .. (r.started_at or "?"))
	minetest.log("action", "[luanti_testkit] Finished: " .. (r.finished_at or "?"))
	minetest.log("action", string.rep("-", 60))

	for _, res in ipairs(r.results) do
		local icon = ""
		if res.status == "PASS"  then icon = "[PASS]"
		elseif res.status == "FAIL"  then icon = "[FAIL]"
		elseif res.status == "SKIP"  then icon = "[SKIP]"
		else icon = "[ERROR]"
		end

		local line = string.format("  %s %-40s %s",
			icon, res.suite .. "." .. res.name,
			res.message or "")
		minetest.log("action", "[luanti_testkit] " .. line)

		if res.details and #res.details > 0 then
			for _, d in ipairs(res.details) do
				minetest.log("action", "[luanti_testkit]    | " .. tostring(d))
			end
		end
	end

	minetest.log("action", string.rep("-", 60))
	local s = r.summary
	minetest.log("action", string.format("[luanti_testkit] Summary: %d total | %d PASS | %d FAIL | %d SKIP | %d ERROR",
		s.total, s.passed, s.failed, s.skipped, s.errors))
	minetest.log("action", string.rep("=", 60))
end

--- Save report to artifacts file if minetest.get_worldpath() exists
function luanti_testkit.save_report_if_possible()
	local worldpath = minetest.get_worldpath()
	if not worldpath then
		minetest.log("action", "[luanti_testkit] save_report_if_possible: no worldpath")
		return false
	end

	local r = report
	if not r.started_at then
		minetest.log("action", "[luanti_testkit] save_report_if_possible: no report to save")
		return false
	end

	-- Try standard artifacts path first, fall back to worldpath
	-- Try to save JSON report within the world directory
	-- Using worldpath is safe (mod security allows writes inside the world dir)
	local timestamp = os.date("%Y%m%d_%H%M%S")
	local json_path = worldpath .. "/ltk_report_" .. timestamp .. ".json"
	local ok, err = pcall(function()
		local f = io.open(json_path, "w")
		if f then
			local data = minetest.write_json({
				started_at = r.started_at,
				finished_at = r.finished_at,
				summary = r.summary,
				results = r.results,
			})
			f:write(data)
			f:close()
			minetest.log("action", "[luanti_testkit] report saved to " .. json_path)
		end
	end)
	if not ok then
		minetest.log("warning", "[luanti_testkit] could not save report: " .. tostring(err))
		return false
	end
	return true
end

-- Chat commands for test reporting

minetest.register_chatcommand("ltk_report", {
	params = "",
	description = "Show last test report from Luanti TestKit",
	privs = {server = true},
	func = function()
		luanti_testkit.print_report()
		return true, "Test report printed to server console."
	end,
})

minetest.register_chatcommand("ltk_list", {
	params = "",
	description = "List all registered test suites and tests",
	privs = {server = true},
	func = function()
		local suites = luanti_testkit.list_suites()
		local tests = luanti_testkit.list_tests()

		minetest.log("action", "[luanti_testkit] === SUITES ===")
		for _, s in ipairs(suites) do
			minetest.log("action", string.format("  %s (%d tests)", s.name, s.test_count))
		end

		minetest.log("action", "[luanti_testkit] === TESTS ===")
		for _, t in ipairs(tests) do
			minetest.log("action", string.format("  %s", t.full_name))
		end

		return true, string.format("Listed %d suites, %d tests. See server console.", #suites, #tests)
	end,
})

minetest.register_chatcommand("ltk_reset_report", {
	params = "",
	description = "Clear the current test report",
	privs = {server = true},
	func = function()
		luanti_testkit.reset_report()
		return true, "Report cleared."
	end,
})

minetest.register_chatcommand("ltk_json_report", {
	params = "",
	description = "Print compact JSON report to server console",
	privs = {server = true},
	func = function()
		local r = luanti_testkit.get_report()
		local json = minetest.write_json({
			started_at = r.started_at,
			finished_at = r.finished_at,
			summary = r.summary,
			results = r.results,
		})
		minetest.log("action", "[luanti_testkit] JSON REPORT:")
		minetest.log("action", json)
		return true, "JSON report printed to server console."
	end,
})

minetest.log("action", "[luanti_testkit] reporter loaded")
