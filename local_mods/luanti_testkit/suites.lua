-- luanti_testkit/suites.lua
-- Suite and test registry

local suites = luanti_testkit._suites

--- Register a test suite
-- @param suite_name string  Unique suite name (e.g. "smoke", "perfectworld")
-- @param suite_def table    Optional: {description = string}
function luanti_testkit.register_suite(suite_name, suite_def)
	if suites[suite_name] then
		minetest.log("warning", "[luanti_testkit] suite '" .. suite_name .. "' already registered, overwriting")
	end
	suites[suite_name] = {
		name = suite_name,
		description = (suite_def and suite_def.description) or "",
		tests = {},
	}
	minetest.log("action", "[luanti_testkit] registered suite: " .. suite_name)
end

--- Register a test within a suite
-- @param suite_name string  Must already exist via register_suite, or auto-created
-- @param test_name string   Unique test name within suite (e.g. "player_online")
-- @param fn function        Test function: fn(ctx)
-- @param opts table|nil     Optional: {description = string, depends = {suite.test, ...}}
function luanti_testkit.register_test(suite_name, test_name, fn, opts)
	if not suites[suite_name] then
		-- Auto-create suite
		suites[suite_name] = {
			name = suite_name,
			description = "",
			tests = {},
		}
	end
	local full = suite_name .. "." .. test_name
	if suites[suite_name].tests[test_name] then
		minetest.log("warning", "[luanti_testkit] test '" .. full .. "' already registered, overwriting")
	end
	suites[suite_name].tests[test_name] = {
		full_name = full,
		suite = suite_name,
		name = test_name,
		fn = fn,
		description = (opts and opts.description) or "",
		depends = (opts and opts.depends) or {},
	}
	minetest.log("action", "[luanti_testkit] registered test: " .. full)
end

--- List all registered suites
-- @return table Array of suite summary tables
function luanti_testkit.list_suites()
	local res = {}
	for _, s in pairs(suites) do
		local count = 0
		for _, _ in pairs(s.tests) do
			count = count + 1
		end
		table.insert(res, {
			name = s.name,
			description = s.description,
			test_count = count,
		})
	end
	table.sort(res, function(a, b) return a.name < b.name end)
	return res
end

--- List all registered tests
-- @return table Array of test summary tables
function luanti_testkit.list_tests()
	local res = {}
	for _, s in pairs(suites) do
		for _, t in pairs(s.tests) do
			table.insert(res, {
				full_name = t.full_name,
				suite = t.suite,
				name = t.name,
				description = t.description,
			})
		end
	end
	table.sort(res, function(a, b) return a.full_name < b.full_name end)
	return res
end

--- Find a test by full name ("suite.test")
-- @param full_name string
-- @return test_def|nil
function luanti_testkit._find_test(full_name)
	local suite_name, test_name = full_name:match("^([^%.]+)%.(.+)$")
	if suite_name and test_name then
		local s = suites[suite_name]
		if s then
			return s.tests[test_name], suite_name, test_name
		end
	end
	return nil, nil, nil
end

--- Find a suite by name
function luanti_testkit._find_suite(suite_name)
	return suites[suite_name]
end
