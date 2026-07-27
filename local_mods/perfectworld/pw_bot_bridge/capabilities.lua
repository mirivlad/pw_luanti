-- pw_bot_bridge/capabilities.lua
--
-- What this build can do, in a form a future pw_bot can read at runtime instead
-- of assuming.
--
-- The capability document is the negotiation surface. A client that finds
-- `pw_bot_bridge/v1` in `protocols` knows exactly which operations, profiles,
-- features, event types and error codes exist, and can refuse to start if the
-- server is older than it expects.

local B = pw_bot_bridge
local protocol = B.impl.protocol
local permissions = B.impl.permissions
local settings = B.impl.settings
local semantics = B.impl.semantics
local player_perception = B.impl.player_perception
local oracle = B.impl.oracle_perception
local events = B.impl.events
local validation = B.impl.validation
local capabilities = {}
B.impl.capabilities = capabilities

capabilities.ID = protocol.ID

function capabilities.build()
  return {
    capability = protocol.ID,
    protocols = {protocol.ID},
    implementation_version = protocol.IMPLEMENTATION_VERSION,
    perfectworld_version = perfectworld and perfectworld.VERSION or "unknown",
    enabled = settings.enabled,

    modes = permissions.list_modes(),
    reserved_modes = permissions.RESERVED_MODES,
    admin_privilege = permissions.PRIV,

    operations = {
      player = validation.operations_for("player"),
      oracle = validation.operations_for("oracle"),
    },
    ray_profiles = player_perception.list_profiles(),
    features = semantics.FEATURES,
    event_types = events.TYPES,
    error_codes = protocol.list_error_codes(),

    -- The two sentences that decide what this mod is.
    contract = {
      principle = "the bridge observes and explains; the real client acts",
      player_mode = "deterministic server-side approximation of the programmatic "
        .. "perception available to a player, bounded by position, look direction, "
        .. "field of view, view distance and line of sight",
      oracle_mode = "exact world data within configured limits, for the test kit "
        .. "and diagnostics; still read-only",
      never = {
        "move the player",
        "change yaw or pitch",
        "press keys",
        "teleport",
        "open doors",
        "interact with entities",
        "attach the player to a vehicle",
        "change speed or collisions",
        "decide anything for the bot",
      },
      not_provided = {
        "screenshot based perception",
        "image recognition",
        "client control",
        "navigation or pathfinding",
        "bot memory or behaviour",
      },
    },

    determinism = {
      rounding_decimal_places = B.impl.canonical.ROUND_PLACES,
      canonical_json = "object keys sorted lexicographically; arrays in producer order; "
        .. "tags, groups and rays sorted",
      volatile_fields = {"timestamp", "sequence", "observation_id", "session_id", "budget"},
    },

    persistence = {
      persisted = {"player_name", "mode", "enabled", "registered_by", "created_at", "limits"},
      not_persisted = {"sessions", "sequence", "event_queue", "observation_ids", "rate_limit_state"},
      sequence_contract = "per session, starts at 1, strictly increasing, reset on server start",
    },

    transport = {
      external_enabled = settings.external_transport,
      kind = "file_spool",
      requires_insecure_environment = false,
      encoding = "json",
    },

    limits = settings.snapshot(),
  }
end

--- Compact form for chat and logs.
function capabilities.summary()
  local doc = capabilities.build()
  return {
    capability = doc.capability,
    implementation_version = doc.implementation_version,
    enabled = doc.enabled,
    modes = table.concat(doc.modes, ","),
    player_operations = #doc.operations.player,
    oracle_operations = #doc.operations.oracle,
    ray_profiles = table.concat(doc.ray_profiles, ","),
    event_types = #doc.event_types,
    external_transport = doc.transport.external_enabled,
  }
end

return capabilities
