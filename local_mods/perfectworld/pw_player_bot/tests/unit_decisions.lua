-- pw_player_bot/tests/unit_decisions.lua
--
-- Drives, goals, scoring and the intent document.
--
-- The point of these tests is that the bot's decisions are legible. A utility
-- AI that cannot be asked "why did you do that" is a random number generator
-- with extra steps.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local support = P.impl.test_support
local memory = P.impl.memory
local beliefs = P.impl.beliefs
local needs = P.impl.needs
local goals = P.impl.goals
local utility = P.impl.utility
local intent = P.impl.intent

local SUITE = "pw_player_bot"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function state_of(memo, overrides)
  local base = {
    hp = memo.last_hp or 20,
    in_liquid = memo.last_in_liquid or false,
    on_ground = memo.last_on_ground ~= false,
  }
  for key, value in pairs(overrides or {}) do base[key] = value end
  return base
end

-- === Needs ===

test("needs_are_bounded_named_and_explained", function(ctx)
  local memo = support.flat_memory(4, 10)
  local model = beliefs.rebuild(memo)
  local drives, why = needs.evaluate(state_of(memo), memo, model, {})

  for _, name in ipairs(needs.NAMES) do
    ctx.assert.not_nil(drives[name], "drive " .. name .. " is reported")
    ctx.assert.is_true(drives[name] >= 0 and drives[name] <= 1,
      name .. " is in range, got " .. tostring(drives[name]))
  end
  ctx.assert.is_true(#why > 0, "and the drives come with reasons")
end)

test("needs_safety_dominates_when_something_can_hurt", function(ctx)
  local memo = support.flat_memory(4, 10)
  support.set_cell(memo, 1, 1, {hazard = true})
  local model = beliefs.rebuild(memo)

  local calm = needs.evaluate(state_of(memo, {hp = 20}), memo, model, {})
  local hurt = needs.evaluate(state_of(memo, {hp = 6}), memo, model, {last_hp = 12})

  ctx.assert.is_true(hurt.safety > calm.safety, "losing health raises safety")
  ctx.assert.equal(select(1, needs.dominant(hurt)), "safety",
    "and safety becomes the dominant drive")
end)

test("needs_curiosity_falls_as_the_neighbourhood_is_walked", function(ctx)
  local memo = support.flat_memory(4, 10)
  local model = beliefs.rebuild(memo)
  local unexplored = needs.evaluate(state_of(memo), memo, model, {})

  for x = -4, 4 do
    for z = -4, 4 do
      memo.visited[memory.cell_key(x, z)] = {x = x, z = z, last_tick = 1}
    end
  end
  local explored = needs.evaluate(state_of(memo), memo, model, {})
  ctx.assert.is_true(explored.curiosity < unexplored.curiosity,
    string.format("walking the ground satisfies curiosity: %.2f -> %.2f",
      unexplored.curiosity, explored.curiosity))
end)

test("needs_recovery_rises_when_the_bot_stops_moving", function(ctx)
  local memo = support.flat_memory(4, 10)
  local model = beliefs.rebuild(memo)
  local history = {stuck_ticks = 0, expected_movement = true,
    last_position = {x = 0, y = 11, z = 0}}

  for _ = 1, 4 do
    history = needs.update_history(history, state_of(memo), memo)
  end
  ctx.assert.is_true(history.stuck_ticks >= 3,
    "not moving while a route is active is being stuck, got " .. history.stuck_ticks)

  local drives = needs.evaluate(state_of(memo), memo, model, history)
  ctx.assert.is_true(drives.recovery > 0.4,
    "and that raises recovery, got " .. drives.recovery)
end)

test("needs_do_not_call_the_bot_stuck_when_it_meant_to_stand_still", function(ctx)
  local memo = support.flat_memory(4, 10)
  local history = {stuck_ticks = 0, expected_movement = false,
    last_position = {x = 0, y = 11, z = 0}}
  for _ = 1, 5 do
    history = needs.update_history(history, state_of(memo), memo)
  end
  ctx.assert.equal(history.stuck_ticks, 0,
    "standing still on purpose is not being stuck")
end)

-- === Goals and scoring ===

test("goals_propose_only_what_beliefs_support", function(ctx)
  local memo = support.flat_memory(4, 10)
  local model = beliefs.rebuild(memo)
  local candidates = goals.propose(state_of(memo), memo, model, {})

  local kinds = {}
  for _, candidate in ipairs(candidates) do kinds[candidate.kind] = true end
  ctx.assert.is_true(kinds.stand_still, "doing nothing is always an option")
  ctx.assert.is_true(kinds.look_around, "so is looking around")
  ctx.assert.is_true(kinds.explore_frontier, "a bounded plateau offers a frontier")
  ctx.assert.is_nil(kinds.approach_feature,
    "with nothing recognised there is nothing to approach")
  ctx.assert.is_nil(kinds.retreat_from_hazard,
    "with nothing dangerous there is nothing to flee")

  memo.features["door@2:11:3"] = {
    feature = "door", position = {x = 2, y = 11, z = 3}, node_name = "test:door",
    first_seen_tick = 1, last_seen_tick = memo.tick, times_seen = 1, visited = false,
  }
  memo.feature_count = 1
  local with_door = goals.propose(state_of(memo), memo, model, {})
  local has_approach = false
  for _, candidate in ipairs(with_door) do
    if candidate.kind == "approach_feature" then has_approach = true end
  end
  ctx.assert.is_true(has_approach, "a remembered door is something to approach")
end)

test("goals_are_capped_however_much_is_remembered", function(ctx)
  local memo = support.flat_memory(10, 10)
  for index = 1, 60 do
    memo.features["door@" .. index .. ":11:0"] = {
      feature = "door", position = {x = index, y = 11, z = 0}, node_name = "test:door",
      first_seen_tick = 1, last_seen_tick = memo.tick, times_seen = 1, visited = false,
    }
    memo.feature_count = memo.feature_count + 1
  end
  local model = beliefs.rebuild(memo)
  local candidates = goals.propose(state_of(memo), memo, model, {})
  ctx.assert.is_true(#candidates <= P.impl.settings.HARD.max_candidates,
    "one tick scores a bounded number of options, got " .. #candidates)
end)

test("utility_lets_danger_outrank_curiosity", function(ctx)
  local memo = support.flat_memory(5, 10)
  support.set_cell(memo, 1, 0, {hazard = true})
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo, {hp = 8}), memo, model, {last_hp = 14})
  local candidates = goals.propose(state_of(memo, {hp = 8}), memo, model, {})

  local winner = utility.choose(candidates, drives, memo)
  ctx.assert.equal(winner.kind, "retreat_from_hazard",
    "a burning bot does not go sightseeing, chose " .. winner.kind)
end)

test("utility_prefers_a_near_frontier_to_a_far_one", function(ctx)
  local memo = support.flat_memory(6, 10)
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo), memo, model, {})

  local near = {kind = "explore_frontier", target = {x = 2, y = 11, z = 0},
    distance = 2, unknown_neighbours = 3}
  local far = {kind = "explore_frontier", target = {x = 40, y = 11, z = 0},
    distance = 40, unknown_neighbours = 3}
  local near_score = utility.score_candidate(near, drives, memo)
  local far_score = utility.score_candidate(far, drives, memo)
  ctx.assert.is_true(near_score > far_score,
    string.format("nearer is better: %.3f vs %.3f", near_score, far_score))
  ctx.assert.is_true(far_score > 0,
    "but far is not worthless, or the bot would never leave the block it is on")
end)

test("utility_prefers_the_edge_that_teaches_more", function(ctx)
  local memo = support.flat_memory(6, 10)
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo), memo, model, {})

  local open = {kind = "explore_frontier", target = {x = 3, y = 11, z = 0},
    distance = 3, unknown_neighbours = 7}
  local narrow = {kind = "explore_frontier", target = {x = 3, y = 11, z = 1},
    distance = 3, unknown_neighbours = 1}
  ctx.assert.is_true(utility.score_candidate(open, drives, memo)
    > utility.score_candidate(narrow, drives, memo),
    "the cell surrounded by more unknown is worth more")
end)

test("utility_ranks_a_doorway_above_a_fence", function(ctx)
  local memo = support.flat_memory(5, 10)
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo), memo, model, {})
  drives.interest = 1

  local door = {kind = "approach_feature", feature = "door",
    target = {x = 3, y = 11, z = 0}, distance = 3}
  local fence = {kind = "approach_feature", feature = "fence",
    target = {x = 3, y = 11, z = 1}, distance = 3}
  ctx.assert.is_true(utility.score_candidate(door, drives, memo)
    > utility.score_candidate(fence, drives, memo),
    "a way into a building beats a way round one")
end)

test("utility_is_deterministic_and_uses_no_randomness", function(ctx)
  local memo = support.flat_memory(5, 10)
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo), memo, model, {})
  local candidates = goals.propose(state_of(memo), memo, model, {})

  local first = utility.choose(candidates, drives, memo)
  for _ = 1, 10 do
    local again = utility.choose(candidates, drives, memo)
    ctx.assert.equal(again.label, first.label, "the same state chooses the same goal")
    ctx.assert.equal(again.score, first.score, "with the same score")
  end

  -- Two identical candidates must still be ordered, and ordered stably.
  local twins = {
    {kind = "explore_frontier", target = {x = 1, y = 11, z = 0}, distance = 1, unknown_neighbours = 3},
    {kind = "explore_frontier", target = {x = -1, y = 11, z = 0}, distance = 1, unknown_neighbours = 3},
  }
  local tie = utility.choose(twins, drives, memo)
  for _ = 1, 10 do
    ctx.assert.equal(utility.choose(twins, drives, memo).label, tie.label,
      "an exact tie breaks the same way every time")
  end
end)

test("utility_explains_every_score", function(ctx)
  local memo = support.flat_memory(5, 10)
  local model = beliefs.rebuild(memo)
  local drives = needs.evaluate(state_of(memo), memo, model, {})
  local candidates = goals.propose(state_of(memo), memo, model, {})
  local explanation = utility.explain(candidates, drives, memo)

  ctx.assert.is_true(#explanation > 0, "every candidate is listed")
  for _, entry in ipairs(explanation) do
    ctx.assert.not_nil(entry.score, entry.kind .. " has a score")
    ctx.assert.not_nil(entry.reasons, entry.kind .. " has reasons")
  end
  local sorted = true
  for index = 2, #explanation do
    if explanation[index - 1].score < explanation[index].score then sorted = false end
  end
  ctx.assert.is_true(sorted, "and they come back ranked")
end)

-- === Intents ===

test("intent_documents_are_versioned_and_valid", function(ctx)
  local document = intent.idle("probe", 1, "nothing to do")
  ctx.assert.equal(document.protocol, "pw_player_bot/v1", "versioned")
  local ok, reason = intent.validate(document)
  ctx.assert.is_true(ok, "an idle intent validates: " .. tostring(reason))
  ctx.assert.equal(document.goal.kind, "stand_still", "doing nothing is still a decision")
  ctx.assert.is_true(document.executed_by:find("real Luanti client", 1, true) ~= nil,
    "the document says who is expected to act on it")
end)

test("intent_actions_are_a_closed_vocabulary", function(ctx)
  for _, action in ipairs(intent.list_actions()) do
    ctx.assert.is_true(intent.is_known_action(action), action .. " is known")
  end
  ctx.assert.is_false(intent.is_known_action("teleport"),
    "there is no teleport action, because a player cannot teleport")
  ctx.assert.is_false(intent.is_known_action("set_node"),
    "and no way to write the world")

  local bad = intent.idle("probe", 1, "x")
  bad.plan.steps = {{action = "teleport"}}
  local ok, reason = intent.validate(bad)
  ctx.assert.is_false(ok, "an unknown action is refused")
  ctx.assert.is_true(reason:find("unknown_action", 1, true) == 1, "and named: " .. reason)
end)

test("intent_carries_the_alternatives_it_rejected", function(ctx)
  local document = intent.build("probe", 5, {
    goal = {kind = "explore_frontier", score = 0.8, target = {x = 1, y = 11, z = 2}},
    alternatives = {
      {kind = "approach_feature", score = 0.5, reason = "feature=door"},
      {kind = "look_around", score = 0.2},
    },
    ttl = 10,
  }, {
    kind = "route",
    route = {{x = 0, y = 11, z = 0}, {x = 1, y = 11, z = 2}},
    steps = {intent.step_face(0, 0), intent.step_follow_route({{x = 1, y = 11, z = 2}})},
  }, {"curiosity=0.8", "distance=2.2"})

  ctx.assert.is_true(intent.validate(document), "it validates")
  ctx.assert.equal(#document.alternatives, 2, "the runners-up are recorded")
  ctx.assert.equal(document.plan.route_length, 2, "the route length is stated")
  ctx.assert.is_true(document.constraints.route_is_belief_only,
    "and the document says the route came from memory, not the map")
  ctx.assert.equal(#document.rationale, 2, "with the reasoning attached")
end)

test("intent_yaw_faces_the_way_it_means_to_go", function(ctx)
  local origin = {x = 0, y = 11, z = 0}
  -- Luanti convention: yaw 0 looks along +Z and grows anticlockwise.
  ctx.assert.near(intent.yaw_towards(origin, {x = 0, z = 5}), 0, 0.01, "north is yaw 0")
  ctx.assert.near(intent.yaw_towards(origin, {x = -5, z = 0}), math.pi / 2, 0.01,
    "a quarter turn looks along -x")
  ctx.assert.near(intent.yaw_towards(origin, {x = 0, z = -5}), math.pi, 0.01,
    "half a turn looks back along -z")
end)

test("intent_encoding_is_canonical", function(ctx)
  local document = intent.idle("probe", 1, "nothing to do")
  document.issued_at = 0
  local first = P.encode_canonical(document)
  for _ = 1, 5 do
    ctx.assert.equal(P.encode_canonical(document), first,
      "the same intent always encodes to the same bytes")
  end
  ctx.assert.is_true(first:find('"protocol":"pw_player_bot/v1"', 1, true) ~= nil,
    "and it names its protocol")
end)
