-- pw_player_bot/tests/init.lua
--
-- The bot's tests register into the shared TestKit, so one `pw_test_all` run
-- covers perception, decisions and the world they describe, and the project
-- keeps a single baseline number.

local modpath = minetest.get_modpath("pw_player_bot")

luanti_testkit.register_suite("pw_player_bot", {
  description = "PerfectWorld player bot: memory, beliefs, routing, utility, intents",
})

local FILES = {
  "support",
  "unit_memory",
  "unit_navigation",
  "unit_decisions",
  "integration",
}

for _, file in ipairs(FILES) do
  local ok, err = pcall(dofile, modpath .. "/tests/" .. file .. ".lua")
  if ok then
    minetest.log("action", "[pw_player_bot] loaded tests/" .. file .. ".lua")
  else
    minetest.log("error", "[pw_player_bot] could not load tests/" .. file .. ".lua: " .. tostring(err))
  end
end
