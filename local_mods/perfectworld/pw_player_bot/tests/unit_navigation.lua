-- pw_player_bot/tests/unit_navigation.lua
--
-- Routing. The property that matters most is negative: a route may never pass
-- through a column the bot has not observed, however obviously walkable that
-- column is in the real world.

local P = pw_player_bot
local support = P.impl.test_support
local memory = P.impl.memory
local navigation = P.impl.navigation
local settings = P.impl.settings

local SUITE = "pw_player_bot"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function route_contains(route, x, z)
  for _, cell in ipairs(route or {}) do
    if cell.x == x and cell.z == z then return true end
  end
  return false
end

test("navigation_routes_across_remembered_ground", function(ctx)
  local memo = support.flat_memory(6, 10)
  local route, reason, info = navigation.plan(memo, {x = -5, z = 0}, {x = 5, z = 0})
  ctx.assert.not_nil(route, "a route was found: " .. tostring(reason))
  ctx.assert.is_true(#route >= 11, "the route spans the plateau, got " .. #route)
  ctx.assert.equal(route[1].x, -5, "it starts where asked")
  ctx.assert.equal(route[#route].x, 5, "and ends where asked")
  ctx.assert.equal(route[1].y, 11, "route cells stand on the ground, not in it")
  ctx.assert.is_true(info.expansions > 0, "the planner reports its work")
end)

test("navigation_refuses_to_route_through_unseen_ground", function(ctx)
  -- A plateau split by a column the bot has never looked at. In the real world
  -- there may well be a path there; the bot has no way to know that, and a
  -- planner that assumed it would be planning with the server's knowledge.
  local memo = support.flat_memory(6, 10)
  support.forget_column(memo, 0, -6, 6)

  local route, reason = navigation.plan(memo, {x = -5, z = 0}, {x = 5, z = 0})
  ctx.assert.is_nil(route, "no route across a gap in knowledge")
  ctx.assert.equal(reason, "no_route", "and the reason names the failure")

  -- Look at one column of the gap, and the way opens.
  memory.learn_cell(memo, 0, 0, {
    ground_y = 10, walkable = true, water = false, hazard = false,
    head_clearance = 3, node_name = "test:ground", semantics = {},
  }, 0.9)
  local second = navigation.plan(memo, {x = -5, z = 0}, {x = 5, z = 0})
  ctx.assert.not_nil(second, "observing the gap makes it routable")
  ctx.assert.is_true(route_contains(second, 0, 0), "and the route uses what was learned")
end)

test("navigation_distinguishes_an_unknown_goal_from_an_unreachable_one", function(ctx)
  local memo = support.flat_memory(4, 10)

  local unknown, unknown_reason = navigation.plan(memo, {x = 0, z = 0}, {x = 100, z = 100})
  ctx.assert.is_nil(unknown, "a goal outside memory is not routable")
  ctx.assert.equal(unknown_reason, "goal_not_remembered",
    "'I have never seen that place' is a different answer from 'I cannot get there'")

  support.set_cell(memo, 3, 3, {hazard = true})
  local blocked, blocked_reason = navigation.plan(memo, {x = 0, z = 0}, {x = 3, z = 3})
  ctx.assert.is_nil(blocked, "a hazard is not a destination")
  ctx.assert.equal(blocked_reason, "goal_not_traversable", "and the reason says so")
end)

test("navigation_avoids_water_and_hazards", function(ctx)
  local memo = support.flat_memory(5, 10)
  -- A wall of water across the direct line, with dry ground around the ends.
  for z = -3, 3 do
    support.set_cell(memo, 0, z, {water = true})
  end
  local route = navigation.plan(memo, {x = -4, z = 0}, {x = 4, z = 0})
  ctx.assert.not_nil(route, "there is a way round")
  for _, cell in ipairs(route) do
    if cell.x == 0 then
      ctx.assert.is_true(cell.z < -3 or cell.z > 3,
        "the route crossed at z=" .. cell.z .. " instead of going round the water")
    end
  end
end)

test("navigation_respects_the_step_limits", function(ctx)
  local memo = support.flat_memory(5, 10)
  -- A wall one node too tall to climb, with a gap at the far end.
  for z = -5, 3 do
    support.set_cell(memo, 0, z, {ground_y = 10 + settings.route_max_step_up + 1})
  end
  local route = navigation.plan(memo, {x = -4, z = 0}, {x = 4, z = 0})
  ctx.assert.not_nil(route, "the bot goes round the wall")
  for _, cell in ipairs(route) do
    if cell.x == 0 then
      ctx.assert.is_true(cell.z > 3, "it crossed at the gap, not over the wall")
    end
  end
end)

test("navigation_prefers_a_road_over_bare_ground", function(ctx)
  local memo = support.flat_memory(6, 10)
  -- A road that runs the long way round. It is further, and cheap enough per
  -- cell that a walker should still take it.
  for z = -6, 6 do
    support.set_cell(memo, -3, z, {semantics = {"ground", "road_surface"}})
  end
  local route = navigation.plan(memo, {x = -3, z = -6}, {x = -3, z = 6})
  ctx.assert.not_nil(route, "a route exists")
  local on_road = 0
  for _, cell in ipairs(route) do
    if cell.x == -3 then on_road = on_road + 1 end
  end
  ctx.assert.is_true(on_road >= #route - 1,
    "the route stayed on the road, " .. on_road .. " of " .. #route .. " cells")
end)

test("navigation_is_bounded_by_its_expansion_limit", function(ctx)
  local memo = support.flat_memory(12, 10)
  local route, reason, info = navigation.plan(memo, {x = -12, z = -12}, {x = 12, z = 12},
    {max_expansions = 10})
  ctx.assert.is_nil(route, "a tight budget stops the search")
  ctx.assert.equal(reason, "expansion_limit", "and says why")
  ctx.assert.is_true(info.expansions <= 12, "without running away, got " .. info.expansions)
end)

test("navigation_is_deterministic", function(ctx)
  local memo = support.flat_memory(6, 10)
  local first = navigation.plan(memo, {x = -5, z = -5}, {x = 5, z = 5})
  ctx.assert.not_nil(first, "a route was found")
  for _ = 1, 5 do
    local again = navigation.plan(memo, {x = -5, z = -5}, {x = 5, z = 5})
    ctx.assert.equal(#again, #first, "the same route length every time")
    for index = 1, #first do
      ctx.assert.equal(again[index].x, first[index].x, "same cell x at " .. index)
      ctx.assert.equal(again[index].z, first[index].z, "same cell z at " .. index)
    end
  end
end)

test("navigation_simplify_keeps_the_turns_and_drops_the_straights", function(ctx)
  local straight = {}
  for z = 0, 9 do straight[#straight + 1] = {x = 0, y = 11, z = z} end
  local simplified = navigation.simplify(straight)
  ctx.assert.equal(#simplified, 2, "a straight run is two waypoints")
  ctx.assert.equal(simplified[1].z, 0, "start kept")
  ctx.assert.equal(simplified[2].z, 9, "end kept")

  local bend = {
    {x = 0, y = 11, z = 0}, {x = 0, y = 11, z = 1}, {x = 0, y = 11, z = 2},
    {x = 1, y = 11, z = 2}, {x = 2, y = 11, z = 2},
  }
  local bent = navigation.simplify(bend)
  ctx.assert.equal(#bent, 3, "a single corner is three waypoints")
  ctx.assert.equal(bent[2].z, 2, "and the corner is the one kept")
end)

test("navigation_approach_cell_finds_the_doorstep_not_the_door", function(ctx)
  local memo = support.flat_memory(4, 10)
  -- The door itself is a place a body cannot stand.
  support.set_cell(memo, 2, 0, {walkable = false})
  local approach = navigation.approach_cell(memo, {x = 2, y = 11, z = 0})
  ctx.assert.not_nil(approach, "an approach exists")
  ctx.assert.is_false(approach.x == 2 and approach.z == 0,
    "the approach is beside the target, not on it")
  ctx.assert.is_true(math.abs(approach.x - 2) <= 1 and math.abs(approach.z) <= 1,
    "and it is adjacent to it")
end)

test("navigation_route_steps_face_before_walking", function(ctx)
  local memo = support.flat_memory(5, 10)
  local route = navigation.plan(memo, {x = 0, z = 0}, {x = 4, z = 0})
  local steps = navigation.route_to_steps(navigation.simplify(route), {x = 0, y = 11, z = 0})
  ctx.assert.equal(steps[1].action, "face",
    "a controller that walks before it turns walks into a wall")
  ctx.assert.equal(steps[2].action, "follow_route", "then it walks")
  ctx.assert.is_true(steps[2].length >= 2, "with a route to follow")
end)
