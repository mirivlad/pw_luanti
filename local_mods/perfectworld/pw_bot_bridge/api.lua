-- pw_bot_bridge/api.lua
--
-- The public, versioned Lua API. This is the whole surface a future pw_bot mod
-- is allowed to depend on; everything under pw_bot_bridge.impl is private and
-- may change without a protocol bump.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local protocol = B.impl.protocol
local permissions = B.impl.permissions
local registry = B.impl.registry
local settings = B.impl.settings
local validation = B.impl.validation
local capabilities = B.impl.capabilities
local events = B.impl.events
local perception = B.impl.perception
local player_perception = B.impl.player_perception
local oracle = B.impl.oracle_perception

-- === Discovery ===

--- Protocol id this build speaks, e.g. "pw_bot_bridge/v1".
function B.get_version()
  return protocol.ID
end

function B.get_implementation_version()
  return protocol.IMPLEMENTATION_VERSION
end

--- Full capability document.
function B.get_capabilities()
  return capabilities.build()
end

function B.get_settings()
  return settings.snapshot()
end

--- Re-read server settings. Only an administrator may do this: the settings
--- decide how much of the world a bot is allowed to ask about.
function B.reload_settings(actor)
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  settings.reload()
  registry.reclamp_all()
  return true, settings.snapshot()
end

-- === Registry ===

--- Register a bot. `options` accepts {mode, enabled, limits, note}.
-- `actor` is the administering player name, or pw_bot_bridge.SERVER_ACTOR for a
-- trusted server-side caller.
function B.register_bot(player_name, options, actor)
  return registry.register(player_name, options, actor)
end

function B.unregister_bot(player_name, actor)
  return registry.unregister(player_name, actor)
end

function B.get_bot(player_name)
  return registry.get(player_name)
end

function B.list_bots()
  return registry.list()
end

function B.get_mode(player_name)
  local bot = registry.raw(player_name)
  if not bot then return nil end
  return bot.mode
end

--- Change a bot's mode. There is no protocol operation for this on purpose:
--- mode is granted by the server, never requested by the observed player.
function B.set_mode(player_name, mode, actor)
  return registry.set_mode(player_name, mode, actor)
end

function B.set_enabled(player_name, enabled, actor)
  return registry.set_enabled(player_name, enabled, actor)
end

function B.set_limits(player_name, limits, actor)
  return registry.set_limits(player_name, limits, actor)
end

function B.get_limits(player_name)
  return validation.limits_for(player_name)
end

--- Ephemeral session facts: id, sequence, queue depth. Never persisted.
function B.get_session_info(player_name)
  if not registry.raw(player_name) then return nil end
  local session = registry.get_session(player_name, true)
  local queued, dropped = events.queue_length(player_name)
  return {
    session_id = session.session_id,
    started_at = session.started_at,
    sequence = session.sequence,
    event_sequence = session.event_sequence,
    event_cursor = session.event_cursor,
    events_queued = queued,
    events_dropped = dropped,
    requests_served = session.requests_served,
    requests_rejected = session.requests_rejected,
    connected = minetest.get_player_by_name(player_name) ~= nil,
  }
end

-- === Observation ===

--- Validate a request without executing it.
--
-- A dry run judges the request, not the world, so it does not require the
-- player to be connected: a client should be able to check a request it intends
-- to send before the bot has even joined. Everything else — protocol, mode,
-- operation, parameters, limits — is checked exactly as observe would.
function B.validate_request(player_name, request)
  local context, code, detail = validation.resolve(player_name, request,
    {skip_player_check = true})
  if not context then
    local request_id = type(request) == "table" and request.request_id or ""
    return false, protocol.error(request_id, code, nil, detail)
  end
  return true, protocol.ok(context.request.request_id, context.mode, 0, {
    operation = context.request.operation,
    parameters_accepted = true,
    player_connected = context.player ~= nil,
    estimated_cost = validation.request_cost(context.request.operation,
      context.request.parameters, context.bot.limits),
  })
end

--- Run one observation and return a protocol envelope.
--
-- This is the single entry point every channel goes through: the Lua API, the
-- chatcommands and the external transport all end up here, so there is exactly
-- one place where a mode is enforced and one place where a response is shaped.
function B.observe(player_name, request, options)
  options = options or {}
  local context, code, detail = validation.resolve(player_name, request, options)
  if not context then
    local request_id = type(request) == "table" and request.request_id or ""
    return protocol.error(request_id, code, detail and detail.message or nil, detail)
  end

  local operation = context.request.operation
  local params = context.request.parameters
  local sequence = registry.next_sequence(player_name)

  if operation == "poll_events" then
    context.session.requests_served = context.session.requests_served + 1
    return protocol.ok(context.request.request_id, context.mode, sequence,
      events.poll(player_name, params))
  end

  -- Player mode reads far fewer nodes than an oracle sweep, but a dense feature
  -- fan across open sky still adds up, so the allowance scales with how far the
  -- bot may see.
  local node_allowance = context.mode == "oracle"
    and context.bot.limits.oracle_max_nodes
    or math.max(8192, context.bot.limits.view_distance * 240)
  local budget = perception.new_budget(node_allowance, settings.HARD.request_budget_us)

  local ok, data
  if context.mode == "oracle" and oracle.OPERATIONS[operation] then
    ok, data = pcall(oracle.dispatch, operation, context.player, context.session,
      context.bot, params, budget)
  else
    ok, data = pcall(player_perception.dispatch, operation, context.player, context.session,
      context.bot, params, budget)
  end

  if not ok then
    -- A Lua error is a bug in the bridge, not information for the caller. It
    -- goes to the server log in full and leaves as a bare code.
    minetest.log("error", "[pw_bot_bridge] operation " .. operation
      .. " failed for " .. player_name .. ": " .. tostring(data))
    context.session.requests_rejected = context.session.requests_rejected + 1
    return protocol.error(context.request.request_id, "internal_error", nil,
      {operation = operation})
  end
  if data == nil then
    return protocol.error(context.request.request_id, "unsupported_operation", nil,
      {operation = operation})
  end

  context.session.requests_served = context.session.requests_served + 1
  return protocol.ok(context.request.request_id, context.mode, sequence, data)
end

--- Observe and hand back canonical JSON, honouring the response size limit.
function B.observe_json(player_name, request, options)
  local envelope = B.observe(player_name, request, options)
  local bot = registry.raw(player_name)
  local limit = (bot and bot.limits and bot.limits.max_response_bytes) or settings.max_response_bytes
  local text, final = protocol.encode(envelope, limit)
  return text, final
end

--- Read pending events.
function B.poll_events(player_name, options)
  return B.observe(player_name, {
    operation = "poll_events",
    parameters = options or {},
  })
end

--- Push an event into a bot's queue. Available to other server-side mods so
--- PerfectWorld subsystems can tell a bot something changed.
function B.emit_event(player_name, event_type, payload, actor)
  local allowed, reason = permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  local event = events.emit(player_name, event_type, payload)
  if not event then return false, "invalid_request", "unknown_event_type_or_bot" end
  return true, event.sequence
end

-- === Semantics ===
--
-- Re-exported so PerfectWorld subsystems can teach the bridge about their own
-- materials without reaching into the private module.

function B.register_node_semantics(node_name, tags)
  return B.impl.semantics.register_node_semantics(node_name, tags)
end

function B.register_group_semantics(group_name, tags)
  return B.impl.semantics.register_group_semantics(group_name, tags)
end

function B.register_entity_semantics(entity_name, tags)
  return B.impl.semantics.register_entity_semantics(entity_name, tags)
end

function B.describe_node(node_name, param2, pos)
  return B.impl.semantics.describe_node(node_name, param2, pos)
end

function B.get_node_semantics(node_name)
  return B.impl.semantics.tags_for_node_name(node_name)
end

-- === Constants a caller may branch on ===

B.PROTOCOL = protocol.ID
B.SERVER_ACTOR = permissions.SERVER_ACTOR
B.ADMIN_PRIV = permissions.PRIV
B.MODES = permissions.list_modes()
B.ERROR_CODES = protocol.list_error_codes()
B.NULL = canonical.NULL
B.EMPTY_ARRAY = canonical.EMPTY_ARRAY

--- Canonical JSON of any value. Exposed because a consumer that writes a report
--- should produce the same bytes the bridge would.
function B.encode_canonical(value)
  return canonical.encode(value)
end

return B
