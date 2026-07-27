-- pw_bot_bridge/settings.lua
--
-- Every tunable in one place, each with a hard ceiling the server operator
-- cannot raise. A setting decides how much work the bridge will do; the hard
-- limit decides how much work it *can* be asked to do.

local B = pw_bot_bridge
local settings = {}
B.impl.settings = settings

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

--- Ceilings no configuration may exceed.
settings.HARD = {
  view_distance = 128,
  horizontal_fov = 180,
  vertical_fov = 170,
  oracle_radius = 256,
  oracle_nodes = 262144,
  requests_per_second = 100,
  request_burst = 200,
  event_queue = 4096,
  response_bytes = 4194304,
  transport_request_bytes = 1048576,
  -- Wall-clock budget for a single observation, in microseconds. An
  -- observation that blows through this is truncated rather than allowed to
  -- stall the server step.
  request_budget_us = 40000,
  -- Largest number of entities any single response may describe.
  max_entities = 64,
  -- Radius of the tactile probe. It is deliberately tiny: it models the space
  -- the player's body occupies, not sight.
  tactile_radius = 2,
  -- Length of the local surface profile, in nodes.
  surface_profile_length = 12,
}

--- Re-read every setting. Called at load and by the reload chatcommand.
function settings.reload()
  local H = settings.HARD
  settings.enabled = get_bool("pw_bot_bridge.enabled", true)
  settings.external_transport = get_bool("pw_bot_bridge.external_transport", false)
  settings.default_mode = get_enum("pw_bot_bridge.default_mode", "player",
    {player = true, oracle = true})
  settings.player_view_distance = get_int("pw_bot_bridge.player_view_distance", 48, 4, H.view_distance)
  settings.player_horizontal_fov = get_int("pw_bot_bridge.player_horizontal_fov", 100, 20, H.horizontal_fov)
  settings.player_vertical_fov = get_int("pw_bot_bridge.player_vertical_fov", 80, 20, H.vertical_fov)
  settings.player_ray_profile = get_enum("pw_bot_bridge.player_ray_profile", "navigation",
    {minimal = true, navigation = true, detailed = true})
  settings.oracle_max_radius = get_int("pw_bot_bridge.oracle_max_radius", 64, 8, H.oracle_radius)
  settings.oracle_max_nodes = get_int("pw_bot_bridge.oracle_max_nodes", 32768, 512, H.oracle_nodes)
  settings.max_requests_per_second = get_number("pw_bot_bridge.max_requests_per_second", 10, 0.5, H.requests_per_second)
  settings.max_request_burst = get_int("pw_bot_bridge.max_request_burst", 20, 1, H.request_burst)
  settings.event_queue_size = get_int("pw_bot_bridge.event_queue_size", 256, 16, H.event_queue)
  settings.event_tick_interval = get_number("pw_bot_bridge.event_tick_interval", 0.5, 0.1, 10)
  settings.event_position_epsilon = get_number("pw_bot_bridge.event_position_epsilon", 1.0, 0.1, 16)
  settings.event_chat = get_bool("pw_bot_bridge.event_chat", false)
  settings.max_response_bytes = get_int("pw_bot_bridge.max_response_bytes", 262144, 4096, H.response_bytes)
  settings.transport_poll_interval = get_number("pw_bot_bridge.transport_poll_interval", 0.2, 0.05, 10)
  settings.transport_max_request_bytes = get_int("pw_bot_bridge.transport_max_request_bytes", 65536, 512, H.transport_request_bytes)
  return settings
end

--- Snapshot for capability discovery and the status command.
function settings.snapshot()
  return {
    enabled = settings.enabled,
    external_transport = settings.external_transport,
    default_mode = settings.default_mode,
    player_view_distance = settings.player_view_distance,
    player_horizontal_fov = settings.player_horizontal_fov,
    player_vertical_fov = settings.player_vertical_fov,
    player_ray_profile = settings.player_ray_profile,
    oracle_max_radius = settings.oracle_max_radius,
    oracle_max_nodes = settings.oracle_max_nodes,
    max_requests_per_second = settings.max_requests_per_second,
    max_request_burst = settings.max_request_burst,
    event_queue_size = settings.event_queue_size,
    event_tick_interval = settings.event_tick_interval,
    event_chat = settings.event_chat,
    max_response_bytes = settings.max_response_bytes,
    max_entities = settings.HARD.max_entities,
    request_budget_us = settings.HARD.request_budget_us,
  }
end

settings.reload()

return settings
