-- pw_bot_bridge/init.lua
--
-- PerfectWorld Bot Bridge: programmatic senses for the future PW Bot.
--
--   Bridge observes and explains.
--   The real client acts.
--
-- The bridge is a server mod. It reads the world and describes it. It never
-- moves a player, never turns a head, never opens a door and never decides
-- anything — those belong to the real Luanti client a future runtime will
-- drive. Oracle mode changes how much may be described; it changes nothing
-- about what is done.
--
-- Data flow:
--
--   bot registration -> permission resolution -> observation request
--     -> player or oracle provider -> PerfectWorld semantic enrichment
--     -> canonical response -> Lua API or external transport
--
-- Nothing lives in this file except wiring. Each concern has its own module,
-- listed below in load order.

pw_bot_bridge = rawget(_G, "pw_bot_bridge") or {}
_G.pw_bot_bridge = pw_bot_bridge

-- Private implementation namespace. A future pw_bot must depend on the public
-- pw_bot_bridge.* functions only; anything under .impl may change without a
-- protocol version bump.
pw_bot_bridge.impl = pw_bot_bridge.impl or {}

local modpath = minetest.get_modpath("pw_bot_bridge")

local MODULES = {
  "canonical",           -- deterministic values and JSON
  "protocol",            -- envelope, versions, closed error-code set
  "permissions",         -- privilege, modes, no self escalation
  "settings",            -- tunables and their hard ceilings
  "registry",            -- bot records, persistence, ephemeral sessions
  "semantics",           -- one place that knows what a node means
  "perception",          -- rays, line of sight, field of view, budgets
  "entities",            -- opaque object ids and visibility filtering
  "events",              -- bounded per-bot event queue
  "player_perception",   -- what a player could plausibly know
  "oracle_perception",   -- exact data for tests and diagnostics
  "validation",          -- the only gate that decides what is allowed
  "capabilities",        -- runtime capability document
  "api",                 -- the public, versioned Lua API
  "transport",           -- optional local file spool, off by default
  "commands",            -- administrative chatcommands
}

for _, name in ipairs(MODULES) do
  local ok, err = pcall(dofile, modpath .. "/" .. name .. ".lua")
  if not ok then
    minetest.log("error", "[pw_bot_bridge] failed to load " .. name .. ".lua: " .. tostring(err))
    error("[pw_bot_bridge] cannot load " .. name .. ".lua: " .. tostring(err))
  end
end

--- Bots the server operator pre-registers in the configuration.
--
-- This is the third way a mode is granted, alongside an administrator and the
-- test harness. It exists so a dev server can come up with its bot already in
-- the right mode, and it is a server setting precisely because the observed
-- player must never be able to choose.
--
--   pw_bot_bridge.autoregister = pwbot:player,inspector:oracle
local function autoregister()
  local raw = minetest.settings:get("pw_bot_bridge.autoregister")
  if not raw or raw == "" then return end
  local registered, refused = 0, 0
  for entry in raw:gmatch("[^,]+") do
    local name, mode = entry:match("^%s*([^:%s]+)%s*:%s*([^:%s]+)%s*$")
    if not name then
      name = entry:match("^%s*(%S+)%s*$")
      mode = pw_bot_bridge.impl.settings.default_mode
    end
    local bot = name and pw_bot_bridge.register_bot(name, {
      mode = mode,
      note = "autoregistered from server configuration",
    }, pw_bot_bridge.SERVER_ACTOR)
    if bot then
      registered = registered + 1
      minetest.log("action", "[pw_bot_bridge] autoregistered " .. bot.player_name
        .. " in " .. bot.mode .. " mode")
    else
      refused = refused + 1
      minetest.log("warning", "[pw_bot_bridge] could not autoregister '" .. tostring(entry) .. "'")
    end
  end
  return registered, refused
end

minetest.register_on_mods_loaded(function()
  local ok, err = pcall(autoregister)
  if not ok then
    minetest.log("error", "[pw_bot_bridge] autoregistration failed: " .. tostring(err))
  end

  -- Tests live inside the mod and register into the shared TestKit suite, so a
  -- normal `pw_test_all` run covers the bridge without a separate harness.
  if luanti_testkit and luanti_testkit.register_suite then
    local test_ok, test_err = pcall(dofile, modpath .. "/tests/init.lua")
    if not test_ok then
      minetest.log("warning", "[pw_bot_bridge] tests not loaded: " .. tostring(test_err))
    end
  end
end)

-- A convenience alias so PerfectWorld code can reach the bridge the same way it
-- reaches every other subsystem.
perfectworld = rawget(_G, "perfectworld") or {}
perfectworld.bot_bridge = pw_bot_bridge

minetest.log("action", "[pw_bot_bridge] loaded " .. pw_bot_bridge.get_version()
  .. " (implementation " .. pw_bot_bridge.get_implementation_version() .. ")")
