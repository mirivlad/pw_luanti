-- pw_player_bot/init.lua
--
-- PerfectWorld Player Bot: the memory and the decisions of an automated player.
--
--   pw_bot_bridge     perceives   -- never acts
--   pw_player_bot     decides     -- never acts
--   future controller acts        -- through a real Luanti client, like a player
--
-- This mod is the middle row. It consumes player-mode observations from the
-- bridge, accumulates a bounded memory of what it has seen, derives beliefs
-- from that memory, scores what is worth doing against what it currently lacks,
-- plans a route over remembered ground only, and publishes an intent.
--
-- It does not move anyone. It cannot: nothing here writes a node, sets a
-- position, turns a head or presses a key, and the smoke test fails the build
-- if that ever changes. The intent it publishes is a description of what a real
-- client should do, and executing it is somebody else's job.
--
-- One rule is worth repeating because it is the whole reason the bot is
-- interesting: it plans over what it remembers, never over the map. A route can
-- only go where the bot has already looked. That is why exploration exists.

pw_player_bot = rawget(_G, "pw_player_bot") or {}
_G.pw_player_bot = pw_player_bot

-- Private implementation namespace. A future controller must depend on the
-- public pw_player_bot.* functions only.
pw_player_bot.impl = pw_player_bot.impl or {}

if not rawget(_G, "pw_bot_bridge") then
  error("[pw_player_bot] pw_bot_bridge is required and did not load")
end

local modpath = minetest.get_modpath("pw_player_bot")

local MODULES = {
  "settings",     -- tunables and their ceilings
  "intent",       -- the pw_player_bot/v1 output contract
  "memory",       -- bounded, decaying, persisted record of what was seen
  "beliefs",      -- derived model: traversable ground, frontier, hazards
  "navigation",   -- A* over remembered cells only
  "needs",        -- drives, in [0, 1], with reasons
  "goals",        -- what the bot can want, and how each becomes a plan
  "utility",      -- deterministic scoring and choice
  "brain",        -- one decision, start to finish
  "api",          -- the public API
  "commands",     -- administrative chatcommands
}

for _, name in ipairs(MODULES) do
  local ok, err = pcall(dofile, modpath .. "/" .. name .. ".lua")
  if not ok then
    minetest.log("error", "[pw_player_bot] failed to load " .. name .. ".lua: " .. tostring(err))
    error("[pw_player_bot] cannot load " .. name .. ".lua: " .. tostring(err))
  end
end

--- Bots the server starts thinking for at boot.
--
-- Each must also be registered with the bridge: perception is granted by the
-- server, and this mod consumes that grant rather than being a second way to
-- obtain one.
local function autostart()
  local raw = minetest.settings:get("pw_player_bot.autostart")
  if not raw or raw == "" then return end
  for entry in raw:gmatch("[^,]+") do
    local name = entry:match("^%s*(%S+)%s*$")
    if name then
      local mind, code, reason = pw_player_bot.start(name, pw_bot_bridge.SERVER_ACTOR)
      if mind then
        minetest.log("action", "[pw_player_bot] autostarted " .. name)
      else
        minetest.log("warning", "[pw_player_bot] could not autostart " .. name
          .. ": " .. tostring(code) .. " (" .. tostring(reason) .. ")")
      end
    end
  end
end

minetest.register_on_mods_loaded(function()
  local ok, err = pcall(autostart)
  if not ok then
    minetest.log("error", "[pw_player_bot] autostart failed: " .. tostring(err))
  end

  if luanti_testkit and luanti_testkit.register_suite then
    local test_ok, test_err = pcall(dofile, modpath .. "/tests/init.lua")
    if not test_ok then
      minetest.log("warning", "[pw_player_bot] tests not loaded: " .. tostring(test_err))
    end
  end
end)

perfectworld = rawget(_G, "perfectworld") or {}
perfectworld.player_bot = pw_player_bot

minetest.log("action", "[pw_player_bot] loaded " .. pw_player_bot.get_version()
  .. " (implementation " .. pw_player_bot.get_implementation_version() .. ")")
