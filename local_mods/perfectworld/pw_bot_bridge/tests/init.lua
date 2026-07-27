-- pw_bot_bridge/tests/init.lua
--
-- Test loader. The bridge registers into the shared TestKit so `pw_test_all`
-- covers it without a second harness, and so the project's single baseline
-- number stays meaningful.
--
-- Unit files exercise logic that needs no world. Scene and integration files
-- need a real server and the connected test player; they SKIP with a stated
-- reason rather than pretending to pass when that player is absent.

local modpath = minetest.get_modpath("pw_bot_bridge")

luanti_testkit.register_suite("pw_bot_bridge", {
  description = "PerfectWorld bot bridge: protocol, perception, semantics, transport",
})

local FILES = {
  "support",
  "unit_core",
  "unit_semantics",
  "unit_events",
  "unit_transport",
  "scenes",
  "integration",
}

for _, file in ipairs(FILES) do
  local ok, err = pcall(dofile, modpath .. "/tests/" .. file .. ".lua")
  if ok then
    minetest.log("action", "[pw_bot_bridge] loaded tests/" .. file .. ".lua")
  else
    minetest.log("error", "[pw_bot_bridge] could not load tests/" .. file .. ".lua: " .. tostring(err))
  end
end
