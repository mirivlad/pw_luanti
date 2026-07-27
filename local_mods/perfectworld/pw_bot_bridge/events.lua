-- pw_bot_bridge/events.lua
--
-- A bounded, ordered mailbox per bot.
--
-- The bridge does not remember the world; it remembers what changed since the
-- bot last looked, and only for a bounded number of changes. When the queue
-- overflows, the oldest events go and a counter says how many were lost —
-- losing events silently would let a bot believe it had seen everything.
--
-- Nothing here runs per server step. A throttled sampler ticks at
-- `pw_bot_bridge.event_tick_interval` and only for bots that are registered,
-- enabled and connected.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local settings = B.impl.settings
local registry = B.impl.registry
local perception = B.impl.perception
local entities_mod = B.impl.entities
local events = {}
B.impl.events = events

events.TYPES = {
  "attachment_changed",
  "bridge_warning",
  "chat_message",
  "entered_liquid",
  "hp_changed",
  "left_liquid",
  "node_changed",
  "observation_invalidated",
  "player_connected",
  "player_disconnected",
  "position_changed",
  "visible_entity_appeared",
  "visible_entity_disappeared",
}

local TYPE_SET = {}
for _, name in ipairs(events.TYPES) do TYPE_SET[name] = true end

function events.is_known_type(name)
  return TYPE_SET[name] == true
end

--- Append an event to a bot's queue.
--
-- Sequence numbers are per session and strictly increasing, so a consumer can
-- resume from a cursor and detect a gap. They start at 1 on every server start.
function events.emit(player_name, event_type, payload)
  if not TYPE_SET[event_type] then
    minetest.log("warning", "[pw_bot_bridge] unknown event type " .. tostring(event_type))
    return nil
  end
  local bot = registry.raw(player_name)
  if not bot or not bot.enabled then return nil end
  local session = registry.get_session(player_name, true)
  session.event_sequence = session.event_sequence + 1
  local event = {
    sequence = session.event_sequence,
    timestamp = os.time(),
    type = event_type,
    payload = payload or {},
  }
  session.events[#session.events + 1] = event

  local capacity = (bot.limits and bot.limits.event_queue_size) or settings.event_queue_size
  local overflow = #session.events - capacity
  if overflow > 0 then
    for _ = 1, overflow do table.remove(session.events, 1) end
    session.events_dropped = session.events_dropped + overflow
    -- The cursor must never point behind the oldest surviving event, or a
    -- consumer would loop forever asking for events that no longer exist.
    local oldest = session.events[1]
    if oldest and session.event_cursor < oldest.sequence - 1 then
      session.event_cursor = oldest.sequence - 1
    end
  end
  return event
end

--- Read events. Two ways to say where to start:
--   after   -- explicit sequence number, cursor untouched
--   default -- the session cursor, which this call advances
function events.poll(player_name, options)
  options = options or {}
  local session = registry.get_session(player_name, true)
  local after = tonumber(options.after)
  local use_cursor = after == nil
  if use_cursor then after = session.event_cursor end
  local limit = math.floor(tonumber(options.max) or 64)
  if limit < 1 then limit = 1 end
  if limit > 256 then limit = 256 end

  local out = {}
  local highest = after
  for _, event in ipairs(session.events) do
    if event.sequence > after and #out < limit then
      out[#out + 1] = {
        sequence = event.sequence,
        timestamp = event.timestamp,
        type = event.type,
        payload = event.payload,
      }
      highest = event.sequence
    end
  end
  if use_cursor then session.event_cursor = highest end

  local remaining = 0
  for _, event in ipairs(session.events) do
    if event.sequence > highest then remaining = remaining + 1 end
  end

  local dropped = session.events_dropped
  if options.reset_dropped then session.events_dropped = 0 end

  return {
    events = #out > 0 and out or canonical.EMPTY_ARRAY,
    cursor = highest,
    remaining = remaining,
    dropped = dropped,
    queue_size = #session.events,
    queue_capacity = (registry.raw(player_name) and registry.raw(player_name).limits
      and registry.raw(player_name).limits.event_queue_size) or settings.event_queue_size,
  }
end

function events.queue_length(player_name)
  local session = registry.get_session(player_name, true)
  return #session.events, session.events_dropped
end

function events.clear(player_name)
  local session = registry.get_session(player_name, true)
  session.events = {}
  session.events_dropped = 0
  session.event_cursor = session.event_sequence
end

-- === Sources ===

minetest.register_on_joinplayer(function(player)
  local name = player:get_player_name()
  if not registry.raw(name) then return end
  -- A new connection is a new session: old entity ids and the old queue
  -- describe a world state the bot can no longer reason about.
  registry.new_session(name)
  events.emit(name, "player_connected", {player_name = name})
end)

minetest.register_on_leaveplayer(function(player)
  local name = player:get_player_name()
  if not registry.raw(name) then return end
  events.emit(name, "player_disconnected", {player_name = name})
end)

minetest.register_on_dieplayer(function(player)
  local name = player:get_player_name()
  if not registry.raw(name) then return end
  events.emit(name, "observation_invalidated", {reason = "player_died"})
end)

local function node_event(pos, node, actor, action)
  local px, py, pz = pos.x, pos.y, pos.z
  local radius = settings.HARD.tactile_radius + 4
  for _, name in ipairs(registry.list_names()) do
    local bot = registry.raw(name)
    if bot and bot.enabled then
      local player = minetest.get_player_by_name(name)
      if player then
        local ppos = player:get_pos()
        if math.abs(ppos.x - px) <= radius
          and math.abs(ppos.y - py) <= radius + 2
          and math.abs(ppos.z - pz) <= radius then
          events.emit(name, "node_changed", {
            action = action,
            position = canonical.node_vector(pos),
            node_name = node and node.name or "air",
            actor = actor and actor.get_player_name and actor:get_player_name() or canonical.NULL,
          })
        end
      end
    end
  end
end

minetest.register_on_placenode(function(pos, newnode, placer)
  node_event(pos, newnode, placer, "placed")
end)

minetest.register_on_dignode(function(pos, oldnode, digger)
  node_event(pos, oldnode, digger, "dug")
end)

minetest.register_on_chat_message(function(name, message)
  if not settings.event_chat then return end
  for _, bot_name in ipairs(registry.list_names()) do
    local bot = registry.raw(bot_name)
    if bot and bot.enabled then
      events.emit(bot_name, "chat_message", {
        from = name,
        message = tostring(message):sub(1, 256),
      })
    end
  end
end)

-- === Throttled sampler ===
--
-- One pass over the registered, connected bots. Everything it looks at is
-- bounded: the player's own state, and the objects inside their view distance.

local accumulator = 0

local function liquid_at_feet(player)
  local pos = player:get_pos()
  local sample = perception.node_at({
    x = math.floor(pos.x + 0.5),
    y = math.floor(pos.y + 0.5),
    z = math.floor(pos.z + 0.5),
  })
  local def = minetest.registered_nodes[sample.name]
  local kind = def and def.liquidtype or "none"
  if kind ~= "source" and kind ~= "flowing" then return nil end
  return sample.name
end

local function sample_bot(name)
  local player = minetest.get_player_by_name(name)
  if not player then return end
  local session = registry.get_session(name, true)
  local bot = registry.raw(name)
  local previous = session.last_sample
  local pos = player:get_pos()
  local hp = player:get_hp()
  local attach = player.get_attach and player:get_attach() or nil
  local liquid = liquid_at_feet(player)

  local current = {
    position = {x = pos.x, y = pos.y, z = pos.z},
    hp = hp,
    attached = attach ~= nil,
    liquid = liquid,
  }

  if previous then
    local epsilon = settings.event_position_epsilon
    if perception.distance(previous.position, current.position) >= epsilon then
      events.emit(name, "position_changed", {
        from = canonical.vector(previous.position),
        to = canonical.vector(current.position),
        distance = canonical.round(perception.distance(previous.position, current.position)),
      })
      current.position = {x = pos.x, y = pos.y, z = pos.z}
    else
      current.position = previous.position
    end
    if previous.hp ~= current.hp then
      events.emit(name, "hp_changed", {from = previous.hp, to = current.hp})
    end
    if previous.attached ~= current.attached then
      events.emit(name, "attachment_changed", {
        attached = current.attached,
        entity = attach and entities_mod.id_for(session, attach) or canonical.NULL,
      })
    end
    if previous.liquid ~= current.liquid then
      if current.liquid then
        events.emit(name, "entered_liquid", {node_name = current.liquid})
      else
        events.emit(name, "left_liquid", {node_name = previous.liquid})
      end
    end
  end
  session.last_sample = current

  -- Visible-entity tracking. Bounded by the bot's own view distance and entity
  -- cap, and it reuses the same filters an observation would apply, so what the
  -- events announce is exactly what an observation would return.
  local limits = bot.limits or registry.default_limits()
  local budget = perception.new_budget(2048, 8000)
  local ok, visible = pcall(entities_mod.visible_for, player, session, limits, nil, budget, {})
  if not ok then return end
  local now = entities_mod.visible_id_set(visible)
  local before = session.entity_visible or {}
  for id, entity_name in pairs(now) do
    if not before[id] then
      events.emit(name, "visible_entity_appeared", {observation_id = id, name = entity_name})
    end
  end
  for id, entity_name in pairs(before) do
    if not now[id] then
      events.emit(name, "visible_entity_disappeared", {observation_id = id, name = entity_name})
    end
  end
  session.entity_visible = now
end

minetest.register_globalstep(function(dtime)
  if not settings.enabled then return end
  accumulator = accumulator + dtime
  if accumulator < settings.event_tick_interval then return end
  accumulator = 0
  for _, name in ipairs(registry.list_names()) do
    local bot = registry.raw(name)
    if bot and bot.enabled then
      local ok, err = pcall(sample_bot, name)
      if not ok then
        minetest.log("warning", "[pw_bot_bridge] event sampler failed for "
          .. name .. ": " .. tostring(err))
      end
    end
  end
end)

return events
