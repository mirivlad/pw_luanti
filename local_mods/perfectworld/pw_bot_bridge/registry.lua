-- pw_bot_bridge/registry.lua
--
-- The server-side list of bots, and the ephemeral session that belongs to each
-- of them while the server is up.
--
-- Persistence contract (see docs/pw-bot/protocol-v1.md):
--   persisted   -- player name, mode, enabled flag, who registered it, when,
--                  and any per-bot limit overrides
--   not persisted -- sessions, sequence numbers, event queues, entity ids,
--                  rate-limit buckets, cached observations
--
-- After a restart the registry is read back verbatim and every bot gets a new
-- session: a fresh session id, sequence restarting at 1, an empty event queue,
-- and an entity id space in which yesterday's ids mean nothing.

local B = pw_bot_bridge
local permissions = B.impl.permissions
local settings = B.impl.settings
local registry = {}
B.impl.registry = registry

local STORAGE_KEY = "pw_bot_bridge_registry_v1"
local STORAGE_VERSION = 1

local storage = minetest.get_mod_storage()

-- player_name -> persisted entry
local bots = {}
-- player_name -> ephemeral session
local sessions = {}
-- Monotonic within one server run; makes session ids unique per boot.
local session_counter = 0

--- Player names the bridge will accept.
--
-- Luanti itself only allows [A-Za-z0-9_-], so anything else is either a typo
-- or an attempt to smuggle a path separator into the spool layout.
local NAME_PATTERN = "^[A-Za-z0-9_%-]+$"
registry.NAME_PATTERN = NAME_PATTERN
registry.MAX_NAME_LENGTH = 20

function registry.is_valid_player_name(name)
  if type(name) ~= "string" then return false end
  if #name == 0 or #name > registry.MAX_NAME_LENGTH then return false end
  if name == permissions.SERVER_ACTOR then return false end
  return name:match(NAME_PATTERN) ~= nil
end

-- === Per-bot limits ===

--- Limits a bot gets unless an administrator narrows them.
-- A per-bot override may only make a limit *smaller*; nothing registered
-- through this module can widen the server-wide ceiling.
function registry.default_limits()
  return {
    view_distance = settings.player_view_distance,
    horizontal_fov = settings.player_horizontal_fov,
    vertical_fov = settings.player_vertical_fov,
    oracle_max_radius = settings.oracle_max_radius,
    oracle_max_nodes = settings.oracle_max_nodes,
    max_requests_per_second = settings.max_requests_per_second,
    max_request_burst = settings.max_request_burst,
    event_queue_size = settings.event_queue_size,
    max_response_bytes = settings.max_response_bytes,
    max_entities = settings.HARD.max_entities,
  }
end

local NUMERIC_LIMITS = {
  "view_distance", "horizontal_fov", "vertical_fov",
  "oracle_max_radius", "oracle_max_nodes",
  "max_requests_per_second", "max_request_burst",
  "event_queue_size", "max_response_bytes", "max_entities",
}

local function clamp_limits(overrides)
  local limits = registry.default_limits()
  if type(overrides) ~= "table" then return limits end
  for _, key in ipairs(NUMERIC_LIMITS) do
    local value = tonumber(overrides[key])
    if value and value > 0 and value < limits[key] then
      limits[key] = value
    end
  end
  return limits
end

registry.clamp_limits = clamp_limits

-- === Persistence ===

local function serialise()
  local entries = {}
  local names = registry.list_names()
  for _, name in ipairs(names) do
    local bot = bots[name]
    entries[#entries + 1] = {
      player_name = bot.player_name,
      mode = bot.mode,
      enabled = bot.enabled,
      registered_by = bot.registered_by,
      created_at = bot.created_at,
      updated_at = bot.updated_at,
      limits = bot.limits,
      note = bot.note,
    }
  end
  return {version = STORAGE_VERSION, bots = entries}
end

function registry.save()
  local ok, err = pcall(function()
    storage:set_string(STORAGE_KEY, minetest.write_json(serialise()))
  end)
  if not ok then
    minetest.log("error", "[pw_bot_bridge] could not persist registry: " .. tostring(err))
    return false
  end
  return true
end

--- Read the registry back. Malformed or unknown-version storage is refused
--- rather than half-applied: a bot silently coming back in the wrong mode is
--- worse than a bot that is not registered at all.
function registry.load()
  bots = {}
  local raw = storage:get_string(STORAGE_KEY)
  if not raw or raw == "" then
    return true, {loaded = 0}
  end
  local ok, data = pcall(minetest.parse_json, raw)
  if not ok or type(data) ~= "table" then
    minetest.log("error", "[pw_bot_bridge] registry storage is malformed; starting empty")
    return false, {reason = "malformed_storage"}
  end
  if tonumber(data.version) ~= STORAGE_VERSION then
    minetest.log("error", "[pw_bot_bridge] registry storage version "
      .. tostring(data.version) .. " is not " .. STORAGE_VERSION .. "; starting empty")
    return false, {reason = "unsupported_storage_version"}
  end
  local loaded, rejected = 0, 0
  for _, entry in ipairs(data.bots or {}) do
    if type(entry) == "table"
      and registry.is_valid_player_name(entry.player_name)
      and permissions.is_valid_mode(entry.mode)
    then
      bots[entry.player_name] = {
        player_name = entry.player_name,
        mode = entry.mode,
        enabled = entry.enabled ~= false,
        registered_by = tostring(entry.registered_by or "unknown"),
        created_at = math.floor(tonumber(entry.created_at) or 0),
        updated_at = math.floor(tonumber(entry.updated_at) or 0),
        limits = clamp_limits(entry.limits),
        note = entry.note and tostring(entry.note) or nil,
      }
      loaded = loaded + 1
    else
      rejected = rejected + 1
    end
  end
  if rejected > 0 then
    minetest.log("warning", "[pw_bot_bridge] dropped " .. rejected .. " malformed registry entries")
  end
  return true, {loaded = loaded, rejected = rejected}
end

-- === Sessions (ephemeral) ===

--- Start a fresh session. Everything a session holds is worthless after a
--- restart, which is exactly why none of it is written to storage.
function registry.new_session(player_name)
  session_counter = session_counter + 1
  local session = {
    session_id = string.format("s%d-%s", session_counter, minetest.sha1
      and minetest.sha1(player_name .. ":" .. session_counter):sub(1, 8)
      or tostring(session_counter)),
    player_name = player_name,
    started_at = os.time(),
    sequence = 0,
    event_cursor = 0,
    events = {},
    events_dropped = 0,
    event_sequence = 0,
    entity_ids = setmetatable({}, {__mode = "k"}),
    entity_counter = 0,
    entity_visible = {},
    rate_tokens = nil,
    rate_checked_us = nil,
    last_sample = nil,
    requests_served = 0,
    requests_rejected = 0,
  }
  sessions[player_name] = session
  return session
end

function registry.get_session(player_name, create)
  local session = sessions[player_name]
  if not session and create then
    session = registry.new_session(player_name)
  end
  return session
end

function registry.drop_session(player_name)
  sessions[player_name] = nil
end

--- Next response sequence number for this bot.
-- Documented contract: strictly increasing within a session, starting at 1,
-- reset on every server start. It is not a global clock and not persisted.
function registry.next_sequence(player_name)
  local session = registry.get_session(player_name, true)
  session.sequence = session.sequence + 1
  return session.sequence
end

-- === Bot records ===

function registry.get(player_name)
  local bot = bots[player_name]
  if not bot then return nil end
  return {
    player_name = bot.player_name,
    mode = bot.mode,
    enabled = bot.enabled,
    registered_by = bot.registered_by,
    created_at = bot.created_at,
    updated_at = bot.updated_at,
    limits = perfectworld.core.deep_copy(bot.limits),
    note = bot.note,
  }
end

--- Internal accessor: the live record, not a copy. Callers outside this mod
--- must use registry.get.
function registry.raw(player_name)
  return bots[player_name]
end

function registry.list_names()
  local names = {}
  for name in pairs(bots) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function registry.list()
  local out = {}
  for _, name in ipairs(registry.list_names()) do
    out[#out + 1] = registry.get(name)
  end
  return out
end

function registry.count()
  local n = 0
  for _ in pairs(bots) do n = n + 1 end
  return n
end

--- Register a bot. `actor` must already have been authorised by the caller;
--- this function re-checks anyway, because "the caller checked" is not a
--- property the code can see.
function registry.register(player_name, options, actor)
  options = options or {}
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then
    return nil, "permission_denied", reason
  end
  if not registry.is_valid_player_name(player_name) then
    return nil, "invalid_request", "invalid_player_name"
  end
  local mode = options.mode or settings.default_mode
  if not permissions.is_valid_mode(mode) then
    return nil, "invalid_request", "invalid_mode"
  end
  local now = os.time()
  local existing = bots[player_name]
  bots[player_name] = {
    player_name = player_name,
    mode = mode,
    enabled = options.enabled ~= false,
    registered_by = tostring(actor),
    created_at = existing and existing.created_at or now,
    updated_at = now,
    limits = clamp_limits(options.limits),
    note = options.note and tostring(options.note):sub(1, 120) or nil,
  }
  registry.new_session(player_name)
  registry.save()
  return registry.get(player_name)
end

function registry.unregister(player_name, actor)
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then
    return false, "permission_denied", reason
  end
  if not bots[player_name] then
    return false, "bot_not_registered", "unknown_bot"
  end
  bots[player_name] = nil
  registry.drop_session(player_name)
  registry.save()
  return true
end

function registry.set_mode(player_name, mode, actor)
  local allowed, reason = permissions.can_set_mode(player_name, actor)
  if not allowed then
    return false, "permission_denied", reason
  end
  if not permissions.is_valid_mode(mode) then
    return false, "invalid_request", "invalid_mode"
  end
  local bot = bots[player_name]
  if not bot then
    return false, "bot_not_registered", "unknown_bot"
  end
  bot.mode = mode
  bot.updated_at = os.time()
  registry.save()
  return true, registry.get(player_name)
end

function registry.set_enabled(player_name, enabled, actor)
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then
    return false, "permission_denied", reason
  end
  local bot = bots[player_name]
  if not bot then
    return false, "bot_not_registered", "unknown_bot"
  end
  bot.enabled = enabled and true or false
  bot.updated_at = os.time()
  registry.save()
  return true, registry.get(player_name)
end

function registry.set_limits(player_name, limits, actor)
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then
    return false, "permission_denied", reason
  end
  local bot = bots[player_name]
  if not bot then
    return false, "bot_not_registered", "unknown_bot"
  end
  bot.limits = clamp_limits(limits)
  bot.updated_at = os.time()
  registry.save()
  return true, registry.get(player_name)
end

--- Re-clamp every bot's limits against the current settings. Used after a
--- settings reload so a narrowed server ceiling takes effect immediately.
function registry.reclamp_all()
  for _, bot in pairs(bots) do
    bot.limits = clamp_limits(bot.limits)
  end
end

--- Exactly what is written to mod storage. Exposed so a test can assert what
--- the persistence contract forbids, not just what it promises.
function registry.storage_string()
  return storage:get_string(STORAGE_KEY)
end

--- Test-only: wipe the registry without touching persistence semantics.
function registry._test_reset()
  bots = {}
  sessions = {}
  registry.save()
end

registry.load()

return registry
