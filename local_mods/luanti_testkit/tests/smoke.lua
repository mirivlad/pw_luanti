-- luanti_testkit/tests/smoke.lua
-- Basic smoke test: testkit loaded, minetest running

local T = luanti_testkit

T.register_suite("smoke", {
	description = "Basic TestKit smoke tests",
})

T.register_test("smoke", "testkit_loaded", function(ctx)
	ctx.assert.not_nil(luanti_testkit, "luanti_testkit global must exist")
	ctx.assert.is_true(luanti_testkit._loaded, "luanti_testkit must be fully loaded")
	ctx.assert.not_nil(luanti_testkit.register_test, "register_test must exist")
	ctx.assert.not_nil(luanti_testkit.run_test, "run_test must exist")
end)

T.register_test("smoke", "minetest_running", function(ctx)
	ctx.assert.not_nil(minetest, "minetest global must exist")
	ctx.assert.not_nil(minetest.get_modpath, "get_modpath must exist")
	local modpath = minetest.get_modpath("luanti_testkit")
	ctx.assert.not_nil(modpath, "luanti_testkit modpath must exist")
end)

T.register_test("smoke", "suites_registry", function(ctx)
	local suites = luanti_testkit.list_suites()
	ctx.assert.not_nil(suites, "list_suites must return a table")
	ctx.assert.is_true(#suites > 0, "at least one suite must be registered (smoke)")
end)

T.register_test("smoke", "list_tests", function(ctx)
	local tests = luanti_testkit.list_tests()
	ctx.assert.not_nil(tests, "list_tests must return a table")
	-- smoke tests should be present
	local found = false
	for _, t in ipairs(tests) do
		if t.full_name == "smoke.testkit_loaded" then
			found = true
			break
		end
	end
	ctx.assert.is_true(found, "smoke.testkit_loaded must appear in list_tests")
end)

T.register_test("smoke", "assertions_work", function(ctx)
	-- These should all pass
	ctx.assert.is_true(true, "true is true")
	ctx.assert.is_false(false, "false is false")
	ctx.assert.equal(1, 1, "1 == 1")
	ctx.assert.not_nil("hello", "string is not nil")
	ctx.assert.near(1.0, 1.0, 0.01, "near self")
	ctx.assert.contains("hello world", "world", "contains works")
	ctx.assert.table_has_key({a = 1}, "a", "table has key")
	-- Verify fail mechanism
	local fail_called = false
	local A = luanti_testkit._make_assertions(function(status, msg)
		fail_called = true
	end)
	A.equal(1, 2, "should fail")
	ctx.assert.is_true(fail_called, "assertion fail callback must be called on mismatch")
end)

T.register_test("smoke", "report_roundtrip", function(ctx)
	-- Save and test reset/record cycle, then restore
	local old_report = luanti_testkit.get_report()
	luanti_testkit.reset_report()
	ctx.assert.equal(luanti_testkit.get_report().summary.total, 0, "empty report has 0 total")
	-- Record a result
	luanti_testkit._record_result({
		suite = "smoke", name = "dummy", status = "PASS",
		message = "roundtrip test", duration_ms = 0,
	})
	ctx.assert.equal(luanti_testkit.get_report().summary.total, 1, "after record, total = 1")
	ctx.assert.equal(luanti_testkit.get_report().summary.passed, 1, "after record, passed = 1")
	-- Restore old report state — use internal table swap
	luanti_testkit._restore_report(old_report)
	ctx.log("report_roundtrip: OK")
end)
