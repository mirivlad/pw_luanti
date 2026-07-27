-- pw_player_bot/tests/integration.lua
--
-- The whole loop, on a live server, through the real bridge, with a real
-- connected player.
--
-- The guarantee these tests exist to protect is that the bot decides and never
-- acts. Everything else is a feature; that one is the contract.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local support = P.impl.test_support
local memory = P.impl.memory
local brain = P.impl.brain
local intent = P.impl.intent

local SUITE = "pw_player_bot"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

test("brain_requires_the_bridge_to_have_granted_perception", function(ctx)
  bridge.unregister_bot(support.SCRATCH_BOT, support.ACTOR)
  local mind, code = P.start(support.SCRATCH_BOT, support.ACTOR)
  ctx.assert.is_nil(mind, "no senses, no thinking")
  ctx.assert.equal(code, "bot_not_registered",
    "perception is granted by the server; this mod is not a second way to get it")
end)

test("brain_lifecycle_requires_authorisation", function(ctx)
  local mind, code = P.start(support.SCRATCH_BOT, nil)
  ctx.assert.is_nil(mind, "no actor, no start")
  ctx.assert.equal(code, "permission_denied", "code")

  local stopped, stop_code = P.stop(support.SCRATCH_BOT, "pw_no_such_admin")
  ctx.assert.is_false(stopped, "an unprivileged actor cannot stop a brain")
  ctx.assert.equal(stop_code, "permission_denied", "code")

  local forgot, forget_code = P.forget(support.SCRATCH_BOT, "pw_no_such_admin")
  ctx.assert.is_false(forgot, "nor wipe its memory")
  ctx.assert.equal(forget_code, "permission_denied", "code")
end)

test("brain_only_ever_asks_for_player_mode_perception", function(ctx)
  -- The brain must not think with oracle data even when it could. A bot that
  -- plans using facts it could not have seen is a puppet, and the entire point
  -- of the split is lost.
  for _, operation in ipairs({"get_nodes", "get_area", "get_entities", "get_collision",
    "get_surface", "get_structure", "get_road", "get_road_topology", "get_settlement",
    "get_lots", "inspect_position", "validate_access_point", "validate_area"}) do
    ctx.assert.is_false(brain.is_allowed_operation(operation),
      "the brain refuses to use " .. operation)
  end
  for _, operation in ipairs({"observe", "scan_forward", "get_self_state",
    "find_visible_entity", "find_visible_feature", "poll_events"}) do
    ctx.assert.is_true(brain.is_allowed_operation(operation),
      "the brain may use " .. operation)
  end
end)

test("brain_thinks_end_to_end_against_the_real_bridge", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    local mind = P.start(name, support.ACTOR)
    ctx.assert.not_nil(mind, "the brain started")

    local document, info = P.think(name, support.ACTOR)
    ctx.assert.not_nil(document, "a decision was made")
    ctx.assert.is_true(intent.validate(document), "and it is a valid intent")
    ctx.assert.equal(document.player_name, name, "for the right player")
    ctx.assert.is_true(document.issued_tick >= 1, "with a tick number")

    -- One observation must have taught it something about the world it is in.
    local summary = P.get_memory_summary(name)
    ctx.assert.is_true(summary.cells > 0,
      "the bot learned some ground, got " .. summary.cells)
    ctx.assert.equal(summary.stats.observations, 1, "from exactly one observation")
    ctx.assert.is_true(summary.visited >= 1, "and knows where it is standing")

    if type(info) == "table" and info.drives then
      for _, need in ipairs(P.impl.needs.NAMES) do
        ctx.assert.not_nil(info.drives[need], "drive " .. need .. " was evaluated")
      end
    end
  end)
end)

test("brain_never_moves_turns_or_damages_the_player", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)

    local position = player:get_pos()
    local yaw = player:get_look_horizontal()
    local pitch = player:get_look_vertical()
    local hp = player:get_hp()

    -- Think hard, repeatedly. Whatever it decides, nothing may happen.
    for _ = 1, 12 do
      P.think(name, support.ACTOR)
    end

    local after = player:get_pos()
    ctx.assert.near(after.x, position.x, 0.0001, "x unchanged")
    ctx.assert.near(after.y, position.y, 0.0001, "y unchanged")
    ctx.assert.near(after.z, position.z, 0.0001, "z unchanged")
    ctx.assert.near(player:get_look_horizontal(), yaw, 0.0001, "yaw unchanged")
    ctx.assert.near(player:get_look_vertical(), pitch, 0.0001, "pitch unchanged")
    ctx.assert.equal(player:get_hp(), hp, "hp unchanged")
    ctx.assert.is_nil(player:get_attach(), "not attached to anything")

    -- And the intent it produced is a description, not an act.
    local document = P.get_intent(name)
    ctx.assert.not_nil(document, "an intent exists")
    ctx.assert.is_true(intent.validate(document), "and validates")
    for _, step in ipairs(document.plan.steps == canonical.EMPTY_ARRAY and {} or document.plan.steps) do
      ctx.assert.is_true(intent.is_known_action(step.action),
        "every step is something a player could do: " .. tostring(step.action))
    end
  end)
end)

test("brain_holds_a_fresh_intent_instead_of_dithering", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)

    local first = P.think(name, support.ACTOR)
    local reused = 0
    for _ = 1, 5 do
      local document, info = P.think(name, support.ACTOR)
      if type(info) == "table" and info.reused then reused = reused + 1 end
      ctx.assert.equal(document.intent_id, first.intent_id,
        "the same plan is kept while it is fresh")
    end
    ctx.assert.is_true(reused >= 4,
      "a bot that re-decides every tick never gets anywhere, reused=" .. reused)

    local status = P.get_status(name)
    ctx.assert.is_true(status.stats.skipped_fresh_intent >= 4,
      "and it says how often it held the plan")
  end)
end)

test("brain_survives_a_bridge_refusal_without_inventing_a_world", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player"}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    P.think(name, support.ACTOR)

    -- Take its senses away mid-session.
    bridge.set_enabled(name, false, support.ACTOR)
    local document, info = P.think(name, support.ACTOR)
    ctx.assert.not_nil(document, "it still answers")
    ctx.assert.equal(document.goal.kind, "stand_still",
      "with no perception it decides to do nothing")
    ctx.assert.is_true(intent.validate(document), "and the answer is still a valid intent")
    ctx.assert.not_nil(info.failure, "the refusal is reported: " .. tostring(info.failure))

    local status = P.get_status(name)
    ctx.assert.is_true(status.stats.observation_failures >= 1, "and counted")
    bridge.set_enabled(name, true, support.ACTOR)
  end)
end)

test("brain_memory_grows_across_ticks_and_survives_a_restart", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)

    for _ = 1, 5 do P.think(name, support.ACTOR) end
    local before = P.get_memory_summary(name)
    ctx.assert.is_true(before.cells > 0, "the bot learned something")

    ctx.assert.is_true(P.save_memory(name, support.ACTOR), "memory saved")

    -- Exactly what a restart does to this module: stop, forget in RAM, load.
    P.stop(name, support.ACTOR)
    ctx.assert.is_nil(P.get_status(name), "the brain is gone")

    P.start(name, support.ACTOR)
    local after = P.get_memory_summary(name)
    ctx.assert.equal(after.cells, before.cells, "every remembered column came back")
    ctx.assert.equal(after.visited, before.visited, "and everywhere it had stood")

    -- Beliefs, drives and the current intent are derived, and are not restored.
    local status = P.get_status(name)
    ctx.assert.equal(status.ticks, 0, "the tick counter starts over")
    ctx.assert.equal(status.last_intent, canonical.NULL, "with no intent in hand")
    ctx.assert.equal(status.beliefs, canonical.NULL, "and no beliefs until it looks again")

    P.forget(name, support.ACTOR)
    ctx.assert.equal(P.get_memory_summary(name).cells, 0, "forgetting really forgets")
  end)
end)

test("brain_routes_only_over_ground_it_has_observed", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    P.think(name, support.ACTOR)

    local position = player:get_pos()
    local far = {
      x = math.floor(position.x) + 500,
      y = math.floor(position.y),
      z = math.floor(position.z) + 500,
    }
    local route, route_reason = P.plan_route(name, position, far)
    ctx.assert.is_nil(route, "the bot cannot route to somewhere it has never seen")
    ctx.assert.equal(route_reason, "goal_not_remembered",
      "and says so plainly rather than guessing")

    -- Somewhere it has just looked at *and can step to* is a different matter.
    --
    -- Any traversable cell will not do. Memory is a set of glimpses, and two
    -- traversable columns twenty nodes apart with unseen ground between them
    -- are genuinely unroutable — refusing that is the planner working, not
    -- failing. So the target is a neighbour of the bot's own column, which by
    -- construction is one remembered step away.
    local mind = brain.get(name)
    local origin = mind.memory.last_position
    local here = origin and memory.get_cell(mind.memory, origin.x, origin.z)
    local reachable
    if here then
      for _, offset in ipairs(P.impl.beliefs.NEIGHBOURS) do
        local cell = memory.get_cell(mind.memory, here.x + offset[1], here.z + offset[2])
        if cell and P.impl.beliefs.can_step(here, cell) then
          reachable = cell
          break
        end
      end
    end
    if not reachable then
      -- Standing somewhere with no remembered step out of it is a legitimate
      -- state, and asserting nothing about it beats asserting something false.
      return
    end
    local near = P.plan_route(name, origin,
      {x = reachable.x, y = reachable.ground_y + 1, z = reachable.z})
    ctx.assert.not_nil(near,
      string.format("but it can route to the ground beside it: %d,%d -> %d,%d",
        here.x, here.z, reachable.x, reachable.z))
  end)
end)

test("brain_explains_itself", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    P.think(name, support.ACTOR)

    local explanation, why = P.explain(name)
    ctx.assert.not_nil(explanation, "the bot can be asked why: " .. tostring(why))
    ctx.assert.not_nil(explanation.drives, "the drives are shown")
    ctx.assert.not_nil(explanation.dominant, "the strongest one is named")
    ctx.assert.is_true(#explanation.candidates > 0, "every option it weighed is listed")

    local document = P.get_intent(name)
    ctx.assert.is_true(#document.rationale > 0,
      "and the issued intent carries its own reasoning")
  end)
end)

test("brain_stays_inside_its_tick_budget", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)

    local worst = 0
    for _ = 1, 8 do
      local started = minetest.get_us_time()
      P.think(name, support.ACTOR)
      worst = math.max(worst, minetest.get_us_time() - started)
    end
    ctx.log(string.format("worst decision tick: %d us", worst))
    ctx.assert.is_true(worst < 200000,
      "a decision must not stall the server step, worst was " .. worst .. " us")

    local status = P.get_status(name)
    ctx.assert.is_true(status.memory.cells <= status.memory.limits.max_cells,
      "and memory stayed inside its ceiling")
  end)
end)

test("capabilities_declare_what_the_bot_does_and_does_not_do", function(ctx)
  local doc = P.get_capabilities()
  ctx.assert.equal(doc.capability, "pw_player_bot/v1", "versioned capability")
  ctx.assert.equal(doc.requires.bridge, "pw_bot_bridge/v1", "it names the bridge it needs")
  ctx.assert.equal(doc.requires.bridge_mode, "player", "and the mode it thinks in")
  ctx.assert.is_true(#doc.goal_kinds >= 5, "the goals are listed")
  ctx.assert.is_true(#doc.actions >= 6, "the action vocabulary is listed")
  ctx.assert.equal(doc.determinism.randomness, "none: math.random is never called",
    "and it states that decisions are reproducible")

  local never = table.concat(doc.contract.never, "|")
  for _, forbidden in ipairs({"move the player", "turn the head", "press a key",
    "place or remove a node", "read the map directly", "use oracle-mode data to decide"}) do
    ctx.assert.is_true(never:find(forbidden, 1, true) ~= nil,
      "the contract states it never will: " .. forbidden)
  end
end)
