-- tests/accessibility.lua
-- Can a villager get from the street to the door?
--
-- The defect these were written for: a straight line from a door to its kerb
-- crosses a neighbour's footprint, the way stops at the obstruction, and the
-- house is one nobody can enter or leave. The fix routes round a corner — and,
-- more importantly, plans a candidate route in full before building any of it,
-- so a rejected candidate leaves nothing behind.
--
-- Both tests build their own ground. Nothing here depends on where the world
-- put the test player or on what a particular seed generated.

local T = luanti_testkit

local GROUND_Y = 24

--- Flat ground with a walled block sitting on it.
local function lay_scene(origin, width, depth)
  local ground = perfectworld.compat.get_material("ground", {required = false})
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 2, y = GROUND_Y - 4, z = origin.z - 2},
      {x = origin.x + width + 2, y = GROUND_Y + 10, z = origin.z + depth + 2})
  end
  for x = origin.x - 2, origin.x + width + 2 do
    for z = origin.z - 2, origin.z + depth + 2 do
      minetest.set_node({x = x, y = GROUND_Y - 1, z = z}, {name = ground})
      for y = GROUND_Y, GROUND_Y + 8 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end

local function clear_scene(origin, width, depth)
  for x = origin.x - 2, origin.x + width + 2 do
    for z = origin.z - 2, origin.z + depth + 2 do
      for y = GROUND_Y - 2, GROUND_Y + 8 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end

--- Everything in a box, as node names, so two moments can be compared exactly.
local function snapshot(minp, maxp)
  local seen = {}
  for x = minp.x, maxp.x do
    for y = minp.y, maxp.y do
      for z = minp.z, maxp.z do
        seen[x .. ":" .. y .. ":" .. z] = minetest.get_node({x = x, y = y, z = z}).name
      end
    end
  end
  return seen
end

local function differences(before, after)
  local changed = {}
  for key, name in pairs(before) do
    if after[key] ~= name then changed[#changed + 1] = key end
  end
  return changed
end

T.register_test("perfectworld", "a_door_behind_a_neighbour_is_reached_round_the_corner", function(ctx)
  local plan_walkway = perfectworld.planner._plan_walkway
  local lay_walkway = perfectworld.planner._lay_walkway
  if not plan_walkway or not lay_walkway then
    ctx.assert.not_nil(plan_walkway, "the planner must plan a way before building it")
    return
  end

  -- A door, its kerb ten nodes away on the diagonal, and a neighbour's
  -- footprint square across the straight line between them. One corner of the
  -- rectangle is inside the neighbour; the other is clear.
  local origin = {x = 27400, z = -27400}
  lay_scene(origin, 16, 16)

  local door = {x = origin.x, y = GROUND_Y, z = origin.z}
  local kerb = {x = origin.x + 12, z = origin.z + 12}
  local neighbour = {min_x = origin.x + 3, max_x = origin.x + 9,
    min_z = origin.z + 3, max_z = origin.z + 9}
  local function blocked(x, z)
    return x >= neighbour.min_x and x <= neighbour.max_x
      and z >= neighbour.min_z and z <= neighbour.max_z
  end

  -- The straight line is the defect: it runs into the neighbour and stops.
  local straight = plan_walkway(door, kerb, blocked, {keep_destination = true})
  ctx.assert.is_false(straight.connected,
    "the straight line must be refused: it crosses the neighbour's footprint")
  ctx.assert.is_true(straight.blocked_cells > 0,
    "and the refusal must be because of the building, not for want of ground")

  -- One of the two corners is clear, and a way through it reaches.
  local corner = {x = door.x, z = kerb.z}
  local first = plan_walkway(door, corner, blocked, {keep_destination = false})
  ctx.assert.is_true(first.connected,
    "the leg along z past the neighbour must be clear")
  local second = plan_walkway(
    {x = corner.x, y = first.end_y, z = corner.z}, kerb, blocked,
    {keep_destination = true})
  ctx.assert.is_true(second.connected, "and the leg along x to the kerb must be clear")

  -- Build it, and check the walker can actually get there.
  lay_walkway(first, perfectworld.compat.get_material("road", {required = false}), {})
  lay_walkway(second, perfectworld.compat.get_material("road", {required = false}), {})

  if minetest.find_path then
    local from = perfectworld.planner._standing_spot(kerb.x, kerb.z, GROUND_Y)
    local to = perfectworld.planner._standing_spot(door.x, door.z, GROUND_Y)
    ctx.assert.not_nil(from, "the kerb must be somewhere a walker can stand")
    ctx.assert.not_nil(to, "and so must the doorstep")
    if from and to then
      local route = minetest.find_path(from, to, 64, 1, 2, "A*_noprefetch")
      ctx.assert.not_nil(route,
        "after building the way round the corner there must be a walkable route")
    end
  end

  -- The neighbour is untouched. A way that reaches a door by cutting through
  -- the house next to it has not solved anything.
  local intact = true
  for x = neighbour.min_x, neighbour.max_x do
    for z = neighbour.min_z, neighbour.max_z do
      local name = minetest.get_node({x = x, y = GROUND_Y, z = z}).name
      if name ~= "air" then intact = false end
    end
  end
  ctx.assert.is_true(intact, "nothing may be laid inside the neighbour's footprint")

  clear_scene(origin, 16, 16)
end)

T.register_test("perfectworld", "a_rejected_route_leaves_nothing_behind", function(ctx)
  local plan_walkway = perfectworld.planner._plan_walkway
  if not plan_walkway then
    ctx.assert.not_nil(plan_walkway, "the planner must plan a way before building it")
    return
  end

  -- Planning a way that cannot reach must not change one node. This is the
  -- property the whole restructure exists for: candidates used to write
  -- themselves as they went, so a rejected one left cut head-room, felled trees
  -- and levelled ground for the next candidate to stand on — and the route that
  -- finally passed might be passing on the sum of two failures.
  local origin = {x = 27600, z = -27600}
  lay_scene(origin, 16, 16)

  local box_min = {x = origin.x - 2, y = GROUND_Y - 2, z = origin.z - 2}
  local box_max = {x = origin.x + 18, y = GROUND_Y + 6, z = origin.z + 18}
  local before = snapshot(box_min, box_max)

  local door = {x = origin.x, y = GROUND_Y, z = origin.z}
  local kerb = {x = origin.x + 12, z = origin.z + 12}
  -- Walled in: no route of any shape can reach.
  local function blocked() return true end

  local attempts = {
    plan_walkway(door, kerb, blocked, {keep_destination = true}),
    plan_walkway(door, {x = door.x, z = kerb.z}, blocked, {}),
    plan_walkway(door, {x = kerb.x, z = door.z}, blocked, {}),
  }
  for index, attempt in ipairs(attempts) do
    ctx.assert.is_false(attempt.connected,
      "candidate " .. index .. " cannot reach and must say so")
  end

  local changed = differences(before, snapshot(box_min, box_max))
  ctx.assert.equal(#changed, 0,
    "planning changed " .. #changed .. " node(s); it must change none")

  -- And planning twice gives the same answer, so a second materialization does
  -- not carve a little further than the first.
  local again = plan_walkway(door, kerb, blocked, {keep_destination = true})
  ctx.assert.equal(again.connected, attempts[1].connected,
    "the same question must get the same answer")
  ctx.assert.equal(again.blocked_cells, attempts[1].blocked_cells,
    "including how much of it was refused")

  clear_scene(origin, 16, 16)
end)

T.register_test("perfectworld", "building_a_planned_way_twice_builds_the_same_way", function(ctx)
  local plan_walkway = perfectworld.planner._plan_walkway
  local lay_walkway = perfectworld.planner._lay_walkway
  if not plan_walkway or not lay_walkway then
    ctx.assert.not_nil(plan_walkway, "the planner must plan a way before building it")
    return
  end

  -- Materializing a settlement twice must not cut a wider or deeper way the
  -- second time. Same plan, same cells, same result.
  local origin = {x = 27800, z = -27800}
  lay_scene(origin, 16, 4)

  local door = {x = origin.x, y = GROUND_Y, z = origin.z}
  local kerb = {x = origin.x + 12, z = origin.z}
  local surface = perfectworld.compat.get_material("road", {required = false})

  local first = plan_walkway(door, kerb, nil, {keep_destination = true})
  lay_walkway(first, surface, {})
  local after_once = snapshot(
    {x = origin.x - 2, y = GROUND_Y - 2, z = origin.z - 2},
    {x = origin.x + 16, y = GROUND_Y + 6, z = origin.z + 6})

  local second = plan_walkway(door, kerb, nil, {keep_destination = true})
  lay_walkway(second, surface, {})
  local after_twice = snapshot(
    {x = origin.x - 2, y = GROUND_Y - 2, z = origin.z - 2},
    {x = origin.x + 16, y = GROUND_Y + 6, z = origin.z + 6})

  ctx.assert.equal(#differences(after_once, after_twice), 0,
    "building the same way a second time must change nothing")
  ctx.assert.equal(#first.cells, #second.cells,
    "and the plan must be the same length both times")

  clear_scene(origin, 16, 4)
end)
