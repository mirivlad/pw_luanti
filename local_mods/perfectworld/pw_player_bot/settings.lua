-- pw_player_bot/settings.lua
--
-- Every tunable, each with a hard ceiling. The bot thinks on a timer, and the
-- limits below are what keep thinking from becoming a server load.

local P = pw_player_bot
local settings = {}
P.impl.settings = settings

local function get_bool(name, default)
  local raw = minetest.settings:get_bool(name)
  if raw == nil then return default end
  return raw
end

local function get_number(name, default, min, max)
  local value = tonumber(minetest.settings:get(name))
  if not value then return default end
  if min and value < min then return min end
  if max and value > max then return max end
  return value
end

local function get_int(name, default, min, max)
  return math.floor(get_number(name, default, min, max))
end

local function get_enum(name, default, allowed)
  local raw = minetest.settings:get(name)
  if raw and allowed[raw] then return raw end
  return default
end

settings.HARD = {
  memory_cells = 65536,
  memory_features = 8192,
  memory_entities = 2048,
  route_expansions = 50000,
  route_length = 1024,
  -- Wall-clock budget for one decision tick, in microseconds. A brain that
  -- overruns it publishes what it has rather than stalling the server step.
  tick_budget_us = 25000,
  -- Candidate goals scored per tick.
  max_candidates = 24,
  -- Frontier targets considered per tick.
  max_frontier_targets = 12,
  -- Intents allowed to wait in the spool before the oldest are dropped. A
  -- runtime that is not claiming them must not be able to fill a disk.
  pending_intents = 64,
}

function settings.reload()
  local H = settings.HARD
  settings.enabled = get_bool("pw_player_bot.enabled", true)
  settings.tick_interval = get_number("pw_player_bot.tick_interval", 1.0, 0.2, 30)
  settings.observation_profile = get_enum("pw_player_bot.observation_profile", "navigation",
    {minimal = true, navigation = true, detailed = true})
  settings.memory_max_cells = get_int("pw_player_bot.memory_max_cells", 4096, 128, H.memory_cells)
  settings.memory_max_features = get_int("pw_player_bot.memory_max_features", 512, 16, H.memory_features)
  settings.memory_max_entities = get_int("pw_player_bot.memory_max_entities", 128, 8, H.memory_entities)
  settings.memory_stale_ticks = get_int("pw_player_bot.memory_stale_ticks", 600, 10, 100000)
  settings.route_max_expansions = get_int("pw_player_bot.route_max_expansions", 4000, 100, H.route_expansions)
  settings.route_max_length = get_int("pw_player_bot.route_max_length", 128, 8, H.route_length)
  settings.route_max_step_up = get_int("pw_player_bot.route_max_step_up", 1, 1, 3)
  settings.route_max_step_down = get_int("pw_player_bot.route_max_step_down", 3, 1, 8)
  settings.intent_ttl_ticks = get_int("pw_player_bot.intent_ttl_ticks", 10, 1, 1000)
  settings.log_intents = get_bool("pw_player_bot.log_intents", false)
  -- Off by default, like the bridge's own transport. A spool is a channel to
  -- something outside the server, and a server operator turns those on
  -- deliberately or not at all.
  settings.intent_transport = get_bool("pw_player_bot.intent_transport", false)
  settings.transport_poll_interval = get_number("pw_player_bot.transport_poll_interval",
    0.2, 0.05, 10)
  settings.transport_max_pending_intents = get_int("pw_player_bot.transport_max_pending_intents",
    8, 1, H.pending_intents)
  return settings
end

function settings.snapshot()
  return {
    enabled = settings.enabled,
    tick_interval = settings.tick_interval,
    observation_profile = settings.observation_profile,
    memory_max_cells = settings.memory_max_cells,
    memory_max_features = settings.memory_max_features,
    memory_max_entities = settings.memory_max_entities,
    memory_stale_ticks = settings.memory_stale_ticks,
    route_max_expansions = settings.route_max_expansions,
    route_max_length = settings.route_max_length,
    route_max_step_up = settings.route_max_step_up,
    route_max_step_down = settings.route_max_step_down,
    intent_ttl_ticks = settings.intent_ttl_ticks,
    log_intents = settings.log_intents,
    intent_transport = settings.intent_transport,
    transport_poll_interval = settings.transport_poll_interval,
    transport_max_pending_intents = settings.transport_max_pending_intents,
    tick_budget_us = settings.HARD.tick_budget_us,
  }
end

settings.reload()

return settings
