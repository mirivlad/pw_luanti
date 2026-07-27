local modpath = minetest.get_modpath("pw_tests")

if not luanti_testkit then
  minetest.log("error", "[pw_tests] luanti_testkit not loaded!")
  return
end

luanti_testkit.register_suite("perfectworld", {
  description = "PerfectWorld integration tests",
})

local test_files = {
  "core",
  "planner",
  "structures",
  "variation",
  "fingerprints",
  "village",
  "village_diversity",
}

for _, file in ipairs(test_files) do
  local path = modpath .. "/tests/" .. file .. ".lua"
  local ok, err = pcall(dofile, path)
  if ok then
    minetest.log("action", "[pw_tests] loaded tests/" .. file .. ".lua")
  else
    minetest.log("warning", "[pw_tests] could not load tests/" .. file .. ".lua: " .. tostring(err))
  end
end

-- Register admin command to run all PerfectWorld tests via TestKit
minetest.register_chatcommand("pw_test_all", {
  params = "",
  description = "Run all PerfectWorld tests via TestKit",
  privs = {interact = true},
  func = function(name)
    if not luanti_testkit or not luanti_testkit.run_all then
      return false, "luanti_testkit not available"
    end
    local ok, err = pcall(luanti_testkit.run_all, {player_name = name})
    if not ok then
      return false, "test run failed: " .. tostring(err)
    end
    return true, "Tests triggered. See server log and ltk_report_*.json for results."
  end,
})

-- Auto-run tests after a delay if test player is connected
local function try_auto_run()
  if luanti_testkit and luanti_testkit.run_all then
    local test_player = minetest.settings:get("perfectworld.test_player") or "pwbot"
    local players = minetest.get_connected_players()
    for _, player in ipairs(players) do
      local name = player:get_player_name()
      if name == test_player then
        pcall(luanti_testkit.run_all, {player_name = test_player})
        minetest.log("action", "[pw_tests] auto-triggered test run for " .. test_player)
        return true
      end
    end
  end
  return false
end

-- Try multiple times with increasing delays
minetest.after(5, function()
  if not try_auto_run() then
    minetest.after(10, function()
      if not try_auto_run() then
        minetest.after(15, try_auto_run)
      end
    end)
  end
end)

minetest.log("action", "[pw_tests] loaded")
