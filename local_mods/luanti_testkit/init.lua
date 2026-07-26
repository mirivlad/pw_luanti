-- luanti_testkit/init.lua
-- Universal server-side test framework for Luanti mods
-- Load order: suites -> assertions -> player -> reporter -> api

luanti_testkit = rawget(_G, "luanti_testkit") or {}
_G.luanti_testkit = luanti_testkit

local modpath = minetest.get_modpath("luanti_testkit")

-- Internal state
luanti_testkit._suites = {}
luanti_testkit._report = nil
luanti_testkit._loaded = false

-- Load submodules
dofile(modpath .. "/suites.lua")
dofile(modpath .. "/assertions.lua")
dofile(modpath .. "/player.lua")
dofile(modpath .. "/reporter.lua")
dofile(modpath .. "/api.lua")

-- Auto-load test files from tests/ directory
local function load_test_files()
	local files = minetest.get_dir_list(modpath .. "/tests") or {}
	table.sort(files)
	for _, file in ipairs(files) do
		if file:match("%.lua$") then
			local ok, err = pcall(dofile, modpath .. "/tests/" .. file)
			if ok then
				minetest.log("action", "[luanti_testkit] loaded test file: " .. file)
			else
				minetest.log("warning", "[luanti_testkit] error loading " .. file .. ": " .. tostring(err))
			end
		end
	end
end

local ok, err = pcall(load_test_files)
if not ok then
	minetest.log("warning", "[luanti_testkit] could not scan tests/: " .. tostring(err))
end

luanti_testkit._loaded = true
minetest.log("action", "[luanti_testkit] loaded")
