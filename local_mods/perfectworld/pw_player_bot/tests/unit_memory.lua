-- pw_player_bot/tests/unit_memory.lua
--
-- Memory and the beliefs derived from it: what is learned, what is bounded,
-- what goes stale, what survives a restart, and what must never be persisted.

local P = pw_player_bot
local bridge = pw_bot_bridge
local support = P.impl.test_support
local memory = P.impl.memory
local beliefs = P.impl.beliefs

local SUITE = "pw_player_bot"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

test("memory_learns_only_what_an_observation_reported", function(ctx)
  local memo = memory.new("probe")
  ctx.assert.equal(memo.cell_count, 0, "a new memory knows nothing")

  memory.integrate(memo, support.observation({strip = 5}))
  ctx.assert.equal(memo.tick, 1, "one observation is one tick")
  ctx.assert.is_true(memo.cell_count >= 5, "the surface strip was learned")
  ctx.assert.is_true(memory.knows_cell(memo, 0, 3), "a column the strip covered")
  ctx.assert.is_false(memory.knows_cell(memo, 40, 40),
    "a column no observation mentioned stays unknown")
  ctx.assert.is_true(memory.has_visited(memo, 0, 0), "where the bot stood is visited")
  ctx.assert.is_false(memory.has_visited(memo, 0, 3),
    "somewhere merely seen is not somewhere visited")
end)

test("memory_confidence_falls_with_distance", function(ctx)
  local memo = memory.new("probe")
  memory.integrate(memo, support.observation({strip = 10}))
  local near = memory.get_cell(memo, 0, 1)
  local far = memory.get_cell(memo, 0, 10)
  ctx.assert.not_nil(near, "the near sample was learned")
  ctx.assert.not_nil(far, "the far sample was learned")
  ctx.assert.is_true(near.confidence > far.confidence,
    string.format("a glimpse is worth less than a close look: %.2f vs %.2f",
      near.confidence, far.confidence))
  local underfoot = memory.get_cell(memo, 0, 0)
  ctx.assert.equal(underfoot.confidence, 1.0,
    "standing on a block is the strongest evidence there is")
end)

test("memory_records_features_and_entities_separately", function(ctx)
  local memo = memory.new("probe")
  memory.integrate(memo, support.observation({
    features = {support.feature("door", 2, 11, 4), support.feature("road_surface", 0, 10, 2)},
    entities = {{
      observation_id = "ent-s1-1", kind = "boat", name = "mcl_boats:boat",
      position = {x = 3, y = 10, z = 5}, semantic_tags = {"boat", "vehicle"},
    }},
  }))
  ctx.assert.equal(memo.feature_count, 2, "both features remembered")
  ctx.assert.equal(memo.entity_count, 1, "the object remembered")

  local doors = memory.features_of(memo, "door", memo.last_position)
  ctx.assert.equal(#doors, 1, "the door is findable by feature name")
  ctx.assert.is_false(doors[1].visited, "and has not been visited yet")
  ctx.assert.is_false(doors[1].stale, "and is fresh")

  memory.mark_feature_visited(memo, doors[1].key)
  ctx.assert.is_true(memory.features_of(memo, "door")[1].visited, "visiting is recorded")
end)

test("memory_reports_staleness_rather_than_hiding_it", function(ctx)
  local memo = memory.new("probe")
  memory.integrate(memo, support.observation({features = {support.feature("door", 2, 11, 4)}}))
  local fresh = memory.features_of(memo, "door")[1]
  ctx.assert.is_false(fresh.stale, "just seen")

  -- Time passes without the door being seen again.
  memo.tick = memo.tick + P.impl.settings.memory_stale_ticks + 1
  local old = memory.features_of(memo, "door")[1]
  ctx.assert.is_true(old.stale,
    "memory says when it last looked; it does not claim the door is still there")
  ctx.assert.not_nil(old.position, "the remembered position is still offered")
end)

test("memory_is_bounded_and_evicts_the_least_recently_seen", function(ctx)
  local settings = P.impl.settings
  local before = settings.memory_max_cells
  settings.memory_max_cells = 200

  local memo = memory.new("probe")
  for round = 1, 40 do
    memo.tick = round
    for step = 1, 20 do
      memory.learn_cell(memo, round * 20 + step, 0, {
        ground_y = 10, walkable = true, water = false, hazard = false,
        head_clearance = 3, node_name = "test:ground", semantics = {},
      }, 0.8)
    end
    -- Eviction runs inside integrate, so drive it the same way.
    memory.integrate(memo, support.observation({strip = 1}))
  end

  ctx.assert.is_true(memo.cell_count <= settings.memory_max_cells,
    "memory never grows past its ceiling, got " .. memo.cell_count)
  ctx.assert.is_true(memo.stats.cells_evicted > 0, "and it says how much it forgot")
  settings.memory_max_cells = before
end)

test("memory_counts_contradictions_instead_of_hiding_them", function(ctx)
  local memo = memory.new("probe")
  memory.learn_cell(memo, 5, 5, {
    ground_y = 10, walkable = true, water = false, hazard = false,
    head_clearance = 3, node_name = "test:ground", semantics = {},
  }, 0.9)
  ctx.assert.equal(memo.stats.contradictions, 0, "nothing contradicted yet")

  -- The same column, at a different height. The world moved, or the first look
  -- was wrong; either way the bot's belief was.
  memory.learn_cell(memo, 5, 5, {
    ground_y = 14, walkable = true, water = false, hazard = false,
    head_clearance = 3, node_name = "test:ground", semantics = {},
  }, 0.95)
  ctx.assert.equal(memo.stats.contradictions, 1, "the contradiction was noticed")
  ctx.assert.equal(memory.get_cell(memo, 5, 5).ground_y, 14,
    "and the better-supported belief won")
end)

test("memory_survives_a_restart_and_ephemeral_state_does_not", function(ctx)
  local name = "pw_brain_persist_probe"
  memory.forget(name)
  local memo = memory.new(name)
  memory.integrate(memo, support.observation({
    features = {support.feature("door", 2, 11, 4)},
    entities = {{
      observation_id = "ent-s99-7", kind = "boat", name = "mcl_boats:boat",
      position = {x = 3, y = 10, z = 5}, semantic_tags = {"boat"},
    }},
  }))
  local cells_before = memo.cell_count
  ctx.assert.is_true(cells_before > 0, "something was learned")
  ctx.assert.is_true(memory.save(memo), "memory was written")

  local restored = memory.load(name)
  ctx.assert.equal(restored.cell_count, cells_before, "every column came back")
  ctx.assert.equal(restored.feature_count, 1, "the feature came back")
  ctx.assert.is_true(memory.knows_cell(restored, 0, 3), "and it is the same ground")

  local dump = memory.storage_string(name)
  ctx.assert.is_true(#dump > 0, "something was persisted")
  -- Observation ids belong to a bridge session that will not exist after a
  -- restart. Persisting one would be persisting a dangling handle.
  ctx.assert.is_true(dump:find("ent-s99-7", 1, true) == nil,
    "a bridge observation id is not persisted")
  for _, forbidden in ipairs({'"stuck_ticks"', '"drives"', '"last_intent"', '"beliefs"'}) do
    ctx.assert.is_true(dump:find(forbidden, 1, true) == nil,
      forbidden .. " is not persisted")
  end
  memory.forget(name)
end)

test("memory_survives_unreadable_storage_without_inventing_knowledge", function(ctx)
  local name = "pw_brain_corrupt_probe"
  memory._test_write_storage(name, "{ not json")
  local memo, info = memory.load(name)
  ctx.assert.is_false(info.loaded, "corrupt storage is refused")
  ctx.assert.equal(memo.cell_count, 0, "and the bot starts knowing nothing")
  memory.forget(name)
end)

-- === Beliefs ===

test("beliefs_separate_standable_from_traversable", function(ctx)
  local memo = support.flat_memory(3, 10)
  support.set_cell(memo, 1, 0, {water = true})
  support.set_cell(memo, 2, 0, {hazard = true})
  support.set_cell(memo, 3, 0, {head_clearance = 1})

  ctx.assert.is_true(beliefs.is_standable(memory.get_cell(memo, 1, 0)),
    "a body fits in water")
  ctx.assert.is_false(beliefs.is_traversable(memory.get_cell(memo, 1, 0)),
    "but a route should not wade")
  ctx.assert.is_false(beliefs.is_traversable(memory.get_cell(memo, 2, 0)),
    "and should not walk into a hazard")
  ctx.assert.is_false(beliefs.is_standable(memory.get_cell(memo, 3, 0)),
    "a body does not fit under a low ceiling")
end)

test("beliefs_refuse_a_step_that_is_too_high_or_too_deep", function(ctx)
  local settings = P.impl.settings
  local memo = support.flat_memory(3, 10)
  local from = memory.get_cell(memo, 0, 0)

  support.set_cell(memo, 1, 0, {ground_y = 10 + settings.route_max_step_up})
  ctx.assert.is_true(beliefs.can_step(from, memory.get_cell(memo, 1, 0)),
    "a kerb within the step limit is climbable")

  support.set_cell(memo, 1, 0, {ground_y = 10 + settings.route_max_step_up + 1})
  ctx.assert.is_false(beliefs.can_step(from, memory.get_cell(memo, 1, 0)),
    "a ledge above it is not")

  support.set_cell(memo, 1, 0, {ground_y = 10 - settings.route_max_step_down - 1})
  ctx.assert.is_false(beliefs.can_step(from, memory.get_cell(memo, 1, 0)),
    "and a drop past the limit is refused")
end)

test("beliefs_frontier_is_the_edge_of_what_is_known", function(ctx)
  local memo = support.flat_memory(4, 10)
  local model = beliefs.rebuild(memo)

  ctx.assert.is_true(model.frontier_count > 0, "a bounded plateau has an edge")
  for _, cell in ipairs(model.frontier) do
    ctx.assert.is_true(cell.unknown_neighbours > 0,
      "every frontier cell borders on somewhere unseen")
  end

  -- The middle of a fully known plateau is not a frontier: nothing is learned
  -- by standing there.
  local middle_is_frontier = false
  for _, cell in ipairs(model.frontier) do
    if cell.x == 0 and cell.z == 0 then middle_is_frontier = true end
  end
  ctx.assert.is_false(middle_is_frontier,
    "the middle of known ground is not the edge of knowledge")

  -- Carve a hole and the cells around it become frontier.
  support.forget_cell(memo, 2, 2)
  local after = beliefs.rebuild(memo)
  ctx.assert.is_true(after.frontier_count > model.frontier_count,
    "forgetting a column creates new edges around it")
end)

test("beliefs_frontier_order_is_deterministic", function(ctx)
  local memo = support.flat_memory(4, 10)
  local first = beliefs.rebuild(memo)
  local second = beliefs.rebuild(memo)
  ctx.assert.equal(#first.frontier, #second.frontier, "same number of edges")
  for index = 1, #first.frontier do
    ctx.assert.equal(first.frontier[index].key, second.frontier[index].key,
      "frontier order does not depend on Lua's hash walk, index " .. index)
  end
end)

test("beliefs_exploration_ratio_reflects_where_the_bot_has_actually_stood", function(ctx)
  local memo = support.flat_memory(3, 10)
  local model = beliefs.rebuild(memo)
  ctx.assert.equal(beliefs.exploration_ratio(memo, model), 0,
    "having seen ground is not having walked it")

  for x = -3, 3 do
    for z = -3, 3 do
      memo.visited[memory.cell_key(x, z)] = {x = x, z = z, last_tick = 1}
    end
  end
  ctx.assert.equal(beliefs.exploration_ratio(memo, model), 1,
    "walking all of it is full exploration")
end)
