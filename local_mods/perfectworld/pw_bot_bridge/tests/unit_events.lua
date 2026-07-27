-- pw_bot_bridge/tests/unit_events.lua
--
-- The bounded event queue: ordering, the polling cursor, overflow accounting
-- and the rule that the bridge stores changes, not a world model.

local B = pw_bot_bridge
local support = B.impl.test_support
local canonical = B.impl.canonical
local events = B.impl.events

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function emit(n, event_type)
  for i = 1, n do
    B.emit_event(support.SCRATCH_BOT, event_type or "bridge_warning",
      {index = i}, B.SERVER_ACTOR)
  end
end

test("events_are_sequenced_timestamped_and_typed", function(ctx)
  support.scratch_bot("player")
  emit(3)
  local envelope = B.poll_events(support.SCRATCH_BOT, {max = 10})
  ctx.assert.is_false(envelope.ok, "an unconnected bot cannot poll through observe")
  ctx.assert.equal(envelope.error.code, "player_not_connected", "code")

  -- The queue itself is readable without a connection; only the protocol path
  -- requires one, because a response describes a live player.
  local polled = events.poll(support.SCRATCH_BOT, {max = 10})
  ctx.assert.equal(#polled.events, 3, "three events queued")
  for index, event in ipairs(polled.events) do
    ctx.assert.equal(event.sequence, index, "sequence " .. index)
    ctx.assert.equal(event.type, "bridge_warning", "type")
    ctx.assert.is_true(event.timestamp > 0, "timestamped")
    ctx.assert.equal(event.payload.index, index, "payload survived")
  end
  support.drop_scratch_bot()
end)

test("event_cursor_advances_and_does_not_repeat", function(ctx)
  support.scratch_bot("player")
  emit(5)
  local first = events.poll(support.SCRATCH_BOT, {max = 2})
  ctx.assert.equal(#first.events, 2, "limit honoured")
  ctx.assert.equal(first.cursor, 2, "cursor moved to 2")
  ctx.assert.equal(first.remaining, 3, "three still waiting")

  local second = events.poll(support.SCRATCH_BOT, {max = 10})
  ctx.assert.equal(#second.events, 3, "the rest arrive once")
  ctx.assert.equal(second.events[1].sequence, 3, "continues where it stopped")

  local third = events.poll(support.SCRATCH_BOT, {max = 10})
  ctx.assert.equal(third.events, canonical.EMPTY_ARRAY, "nothing is delivered twice")
  support.drop_scratch_bot()
end)

test("event_poll_after_a_sequence_does_not_move_the_cursor", function(ctx)
  support.scratch_bot("player")
  emit(4)
  local explicit = events.poll(support.SCRATCH_BOT, {after = 0, max = 10})
  ctx.assert.equal(#explicit.events, 4, "explicit cursor reads from the start")
  local again = events.poll(support.SCRATCH_BOT, {after = 0, max = 10})
  ctx.assert.equal(#again.events, 4, "an explicit read is repeatable")
  local cursor_read = events.poll(support.SCRATCH_BOT, {max = 10})
  ctx.assert.equal(#cursor_read.events, 4, "the session cursor was never advanced")
  support.drop_scratch_bot()
end)

test("event_queue_overflows_by_dropping_the_oldest_and_counting_them", function(ctx)
  support.scratch_bot("player", {event_queue_size = 16})
  emit(40)
  local polled = events.poll(support.SCRATCH_BOT, {max = 256})
  ctx.assert.is_true(polled.queue_capacity <= 16, "the per-bot capacity applies")
  ctx.assert.is_true(polled.queue_size <= 16, "the queue never grows past capacity")
  ctx.assert.equal(polled.dropped, 40 - polled.queue_size, "every dropped event is counted")
  ctx.assert.equal(polled.events[1].sequence, 41 - polled.queue_size,
    "the survivors are the newest ones")
  ctx.assert.is_true(polled.events[#polled.events].sequence == 40, "the newest event survived")
  support.drop_scratch_bot()
end)

test("event_cursor_survives_an_overflow_without_looping", function(ctx)
  support.scratch_bot("player", {event_queue_size = 16})
  emit(4)
  events.poll(support.SCRATCH_BOT, {max = 2})   -- cursor at 2
  emit(60)                                       -- everything up to 2 is long gone
  local polled = events.poll(support.SCRATCH_BOT, {max = 256})
  ctx.assert.is_true(#polled.events > 0, "the poll returns the survivors")
  local after = events.poll(support.SCRATCH_BOT, {max = 256})
  ctx.assert.equal(after.events, canonical.EMPTY_ARRAY,
    "a second poll is empty rather than looping forever")
  support.drop_scratch_bot()
end)

test("unknown_event_types_are_refused", function(ctx)
  support.scratch_bot("player")
  local ok, code = B.emit_event(support.SCRATCH_BOT, "teleport_the_player", {}, B.SERVER_ACTOR)
  ctx.assert.is_false(ok, "an unknown type is not queued")
  ctx.assert.equal(code, "invalid_request", "code")
  ctx.assert.is_true(events.is_known_type("position_changed"), "known types are accepted")
  support.drop_scratch_bot()
end)

test("emitting_an_event_requires_authorisation", function(ctx)
  support.scratch_bot("player")
  local ok, code = B.emit_event(support.SCRATCH_BOT, "bridge_warning", {}, nil)
  ctx.assert.is_false(ok, "no actor, no event")
  ctx.assert.equal(code, "permission_denied", "code")
  support.drop_scratch_bot()
end)

test("event_types_cover_the_documented_model", function(ctx)
  local doc = B.get_capabilities()
  local seen = {}
  for _, name in ipairs(doc.event_types) do seen[name] = true end
  for _, wanted in ipairs({"player_connected", "player_disconnected", "position_changed",
    "attachment_changed", "hp_changed", "entered_liquid", "left_liquid", "node_changed",
    "visible_entity_appeared", "visible_entity_disappeared", "observation_invalidated",
    "bridge_warning", "chat_message"}) do
    ctx.assert.is_true(seen[wanted] == true, "event type " .. wanted .. " is declared")
  end
end)

test("bridge_stores_no_world_model", function(ctx)
  -- The bridge is senses, not memory. A session may hold ids, a cursor, a rate
  -- bucket and a queue; a map, a goal or a route would make it something else.
  support.scratch_bot("player")
  local info = B.get_session_info(support.SCRATCH_BOT)
  local allowed = {
    session_id = true, started_at = true, sequence = true, event_sequence = true,
    event_cursor = true, events_queued = true, events_dropped = true,
    requests_served = true, requests_rejected = true, connected = true,
  }
  for key in pairs(info) do
    ctx.assert.is_true(allowed[key] == true, "session field '" .. key .. "' is permitted")
  end
  support.drop_scratch_bot()
end)
