-- luanti_testkit/assertions.lua
-- Assertion functions injected into test ctx

local function make_assertions(report_callback)
	local A = {}

	--- Aliases for Lua-reserved-word-safe naming
	function A.is_true(value, message)
		if not value then
			report_callback("FAIL", message or "expected true, got false/nil")
		end
	end

	function A.is_false(value, message)
		if value then
			report_callback("FAIL", message or "expected false/nil, got truthy")
		end
	end

	--- Backward compat aliases (underscore suffix works around Lua reserved words)
	A.true_ = A.is_true
	A.false_ = A.is_false

	function A.equal(actual, expected, message)
		if actual ~= expected then
			local msg = string.format("%s: expected %s, got %s",
				message or "assert.equal",
				tostring(expected), tostring(actual))
			report_callback("FAIL", msg)
		end
	end

	function A.not_nil(value, message)
		if value == nil then
			report_callback("FAIL", message or "expected non-nil value, got nil")
		end
	end

	function A.is_nil(value, message)
		if value ~= nil then
			local msg = string.format("%s: expected nil, got %s",
				message or "assert.is_nil",
				tostring(value))
			report_callback("FAIL", msg)
		end
	end

	function A.near(actual, expected, tolerance, message)
		tolerance = tolerance or 0.001
		if math.abs(actual - expected) > tolerance then
			local msg = string.format("%s: expected ~%s (tol=%s), got %s",
				message or "assert.near",
				tostring(expected), tostring(tolerance), tostring(actual))
			report_callback("FAIL", msg)
		end
	end

	function A.contains(text, needle, message)
		if not text or not text:find(needle, 1, true) then
			local msg = string.format("%s: expected text containing '%s'",
				message or "assert.contains", tostring(needle))
			if text then
				msg = msg .. ", got '" .. text:sub(1, 80) .. "'"
			else
				msg = msg .. ", got nil"
			end
			report_callback("FAIL", msg)
		end
	end

	function A.table_has_key(tbl, key, message)
		if type(tbl) ~= "table" then
			report_callback("FAIL", message or string.format("expected table, got %s", type(tbl)))
			return
		end
		if tbl[key] == nil then
			-- Also check rawget in case of metatables
			local has = false
			for k, _ in pairs(tbl) do
				if k == key then
					has = true
					break
				end
			end
			if not has then
				report_callback("FAIL", message or string.format("table missing key '%s'", tostring(key)))
			end
		end
	end

	return A
end

luanti_testkit._make_assertions = make_assertions
