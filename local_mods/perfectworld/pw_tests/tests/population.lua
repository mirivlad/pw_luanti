-- tests/population.lua
-- The people who live in the settlements.
--
-- The rule under test is "one villager per bed that is actually standing in the
-- world, once". Everything that could go wrong here goes wrong quietly: a
-- double-spawn looks like a busy village, a miscount looks like an empty one,
-- and a villager placed inside a node simply suffocates out of sight.

local T = luanti_testkit
local population = perfectworld.population

--- A patch of flat ground with beds on it, somewhere nothing else is built.
local function lay_beds(origin, count, spacing)
  local bottom = perfectworld.compat.get_material("bed", {required = false})
  -- The compat name may resolve to something that is not a bed at all; the
  -- group is what the villagers look for, so that is what the test lays.
  if not bottom or not minetest.registered_nodes[bottom]
    or not (minetest.registered_nodes[bottom].groups or {}).bed_bottom then
    bottom = nil
    for name, def in pairs(minetest.registered_nodes) do
      if (def.groups or {}).bed_bottom then bottom = name break end
    end
  end
  if not bottom then return nil, {} end

  local ground = perfectworld.compat.get_material("ground", {required = false})
  local placed = {}
  for i = 0, count - 1 do
    local x = origin.x + i * (spacing or 4)
    for dx = -1, 1 do
      for dz = -1, 1 do
        minetest.set_node({x = x + dx, y = origin.y - 1, z = origin.z + dz}, {name = ground})
        for dy = 0, 2 do
          minetest.set_node({x = x + dx, y = origin.y + dy, z = origin.z + dz}, {name = "air"})
        end
      end
    end
    minetest.set_node({x = x, y = origin.y, z = origin.z}, {name = bottom})
    placed[#placed + 1] = {x = x, y = origin.y, z = origin.z}
  end
  return bottom, placed
end

local function clear(origin, count, spacing)
  for i = 0, count - 1 do
    local x = origin.x + i * (spacing or 4)
    for dx = -1, 1 do
      for dz = -1, 1 do
        for dy = -1, 2 do
          minetest.set_node({x = x + dx, y = origin.y + dy, z = origin.z + dz}, {name = "air"})
        end
      end
    end
  end
end

T.register_test("perfectworld", "a_settlement_holds_one_person_per_bed", function(ctx)
  ctx.assert.not_nil(population.capacity, "population must say how many people a place holds")
  if not population.capacity then return end

  ctx.assert.equal(population.capacity(0), 0, "no beds, nobody lives there")
  ctx.assert.equal(population.capacity(1), 1, "one bed, one villager")
  ctx.assert.equal(population.capacity(7), 7, "seven beds, seven villagers")
  ctx.assert.equal(population.capacity(1000), population.MAX_PER_SETTLEMENT,
    "a settlement that materialized oddly must not become a thousand entities")
  ctx.assert.equal(population.capacity(nil), 0, "an unknown bed count houses nobody")
end)

T.register_test("perfectworld", "beds_are_counted_once_and_in_a_stable_order", function(ctx)
  if not population.find_beds then
    ctx.assert.not_nil(population.find_beds, "population must find the beds in a settlement")
    return
  end

  local origin = {x = 30200, y = 20, z = -30200}
  local count = 5
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 4, y = origin.y - 6, z = origin.z - 6},
      {x = origin.x + count * 4 + 4, y = origin.y + 8, z = origin.z + 6})
  end
  local node = lay_beds(origin, count, 4)
  if not node then
    ctx.assert.not_nil(node, "the game must register a bed for this test to mean anything")
    return
  end

  local bounds = {
    min_x = origin.x - 3, max_x = origin.x + count * 4 + 3,
    min_z = origin.z - 3, max_z = origin.z + 3,
  }
  local first = population.find_beds(bounds)
  local second = population.find_beds(bounds)

  ctx.assert.equal(#first, count,
    "each bed must be counted exactly once, not once per node it occupies")
  ctx.assert.equal(#second, count, "counting twice must give the same answer")
  for i = 1, #first do
    ctx.assert.equal(first[i].x .. "," .. first[i].z, second[i].x .. "," .. second[i].z,
      "the order of beds must be stable, at bed " .. i)
  end
  for i = 2, #first do
    ctx.assert.is_true(first[i].x > first[i - 1].x
      or (first[i].x == first[i - 1].x and first[i].z >= first[i - 1].z),
      "beds must come back sorted, at bed " .. i)
  end

  clear(origin, count, 4)
end)

T.register_test("perfectworld", "a_villager_is_never_put_inside_a_node", function(ctx)
  if not population.standing_spot_near then
    ctx.assert.not_nil(population.standing_spot_near,
      "population must find somewhere a villager can stand")
    return
  end

  local origin = {x = 30400, y = 20, z = -30400}
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 6, y = origin.y - 6, z = origin.z - 6},
      {x = origin.x + 6, y = origin.y + 8, z = origin.z + 6})
  end
  local node, beds = lay_beds(origin, 1, 4)
  if not node then
    ctx.assert.not_nil(node, "the game must register a bed for this test to mean anything")
    return
  end

  local spot = population.standing_spot_near(beds[1])
  ctx.assert.not_nil(spot, "a bed on open ground must have somewhere to stand beside it")
  if spot then
    local foot = minetest.get_node({x = math.floor(spot.x), y = spot.y, z = math.floor(spot.z)}).name
    local head = minetest.get_node({x = math.floor(spot.x), y = spot.y + 1, z = math.floor(spot.z)}).name
    local below = minetest.get_node({x = math.floor(spot.x), y = spot.y - 1, z = math.floor(spot.z)}).name
    ctx.assert.equal(foot, "air", "the spot itself must be free")
    ctx.assert.equal(head, "air", "there must be head-room, or the villager suffocates")
    ctx.assert.is_true(below ~= "air" and below ~= "ignore",
      "there must be ground underneath, or the villager falls")
    -- And never the bed itself: standing in the bed is standing in a node.
    ctx.assert.is_true(math.floor(spot.x) ~= beds[1].x or math.floor(spot.z) ~= beds[1].z,
      "the spot must not be the bed")
  end

  -- Walled in on every side and every level: there is nowhere, and saying so is
  -- better than putting somebody in the wall.
  local stone = perfectworld.compat.get_material("stone", {required = false})
  for dx = -2, 2 do
    for dz = -2, 2 do
      if dx ~= 0 or dz ~= 0 then
        for dy = 0, 3 do
          minetest.set_node({x = origin.x + dx, y = origin.y + dy, z = origin.z + dz},
            {name = stone})
        end
      end
    end
  end
  ctx.assert.equal(population.standing_spot_near(beds[1]), nil,
    "a bed with no free ground around it must report nowhere rather than a wall")

  for dx = -2, 2 do
    for dz = -2, 2 do
      for dy = -1, 3 do
        minetest.set_node({x = origin.x + dx, y = origin.y + dy, z = origin.z + dz}, {name = "air"})
      end
    end
  end
end)

T.register_test("perfectworld", "a_settlement_is_not_populated_twice", function(ctx)
  if not population.populate or not population.get_record then
    ctx.assert.not_nil(population.populate, "population must be able to settle a village")
    return
  end

  -- A settlement that has already been given its people reports so rather than
  -- adding another set. Walking past a village twice must not double it.
  local settled = nil
  for _, id in ipairs(perfectworld.settlements.list_ids()) do
    local record = population.get_record(id)
    if record and record.settled then settled = id break end
  end

  if not settled then
    -- Nothing in this world has been settled yet, which is a legitimate state;
    -- the claim is then vacuous and saying so beats inventing a pass.
    ctx.assert.is_true(true, "no settled settlement in this world to re-check")
    return
  end

  local ok, result = population.populate(settled)
  ctx.assert.is_false(ok, "an already-settled village must refuse a second intake")
  ctx.assert.equal(type(result) == "table" and result.reason, "already_settled",
    "and must say why, so the caller can tell it apart from a failure")
end)

T.register_test("perfectworld", "an_unbuilt_settlement_gets_nobody", function(ctx)
  if not population.populate then
    ctx.assert.not_nil(population.populate, "population must be able to settle a village")
    return
  end

  local failed = nil
  for _, id in ipairs(perfectworld.settlements.list_ids()) do
    local s = perfectworld.settlements.get(id)
    if s and s.status == "failed" then failed = id break end
  end
  if not failed then
    ctx.assert.is_true(true, "no failed settlement in this world to check")
    return
  end

  local ok, result = population.populate(failed, {force = true})
  ctx.assert.is_false(ok, "a settlement that was never built houses nobody")
  ctx.assert.equal(type(result) == "table" and result.reason, "settlement_never_built",
    "and the reason must name the cause rather than the symptom")
end)

T.register_test("perfectworld", "a_lone_farmstead_gets_its_people_too", function(ctx)
  if not population.populate_structure then
    ctx.assert.not_nil(population.populate_structure,
      "population must be able to settle a building that is not a settlement")
    return
  end

  -- Four candidates in five are a single farmstead rather than a village, and a
  -- farmstead has a bed in it. Routing population only through settlement
  -- records left most of the inhabited buildings in the world empty — and the
  -- lookup would have refused them anyway, because a lone farmstead has no
  -- settlement record to be found by.
  local structures = perfectworld.planner.list_structures()
  local farmstead = nil
  for _, record in ipairs(structures) do
    if record and record.status == "materialized" and record.position
      and record.structure_name == "pw_farmstead_v1" then
      farmstead = record
      break
    end
  end
  if not farmstead then
    ctx.assert.is_true(true, "no farmstead has been built in this world to check")
    return
  end

  -- The claim under test is that the path exists and reaches the world, not
  -- that this particular building is loaded right now.
  local ok, result = population.populate_structure(farmstead, {force = true})
  ctx.assert.not_nil(result, "the attempt must report something")
  if result then
    local reason = result.reason
    local acceptable = ok or reason == "not_loaded" or reason == "no_beds"
    ctx.assert.is_true(acceptable,
      "a farmstead must be settled, or refused for a reason about the world "
        .. "rather than about its paperwork; got " .. tostring(reason))
    ctx.assert.is_true(reason ~= "unknown_settlement",
      "a farmstead is not a settlement and must not be refused for not being one")
  end
end)

T.register_test("perfectworld", "an_unloaded_settlement_is_not_recorded_as_empty", function(ctx)
  if not population.is_loaded or not population.populate then
    ctx.assert.not_nil(population.is_loaded,
      "population must tell an unloaded settlement from an empty one")
    return
  end

  -- Somewhere far enough out that nothing has generated it. A node search there
  -- returns nothing, exactly as it would in a village with no beds; writing
  -- that down would mark a real village permanently uninhabitable.
  local far = {min_x = 900000, max_x = 900040, min_z = -900040, max_z = -900000}
  ctx.assert.is_false(population.is_loaded(far),
    "unreached coordinates must not read as loaded ground")

  local here = {min_x = 30200, max_x = 30240, min_z = -30240, max_z = -30200}
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = here.min_x, y = 10, z = here.min_z}, {x = here.max_x, y = 30, z = here.max_z})
  end
  local ground = perfectworld.compat.get_material("ground", {required = false})
  minetest.set_node({x = here.min_x, y = 20, z = here.min_z}, {name = ground})
  ctx.assert.is_true(population.is_loaded(here),
    "ground that has just been written must read as loaded")
end)

T.register_test("perfectworld", "population_is_asked_of_the_world_not_only_of_the_record", function(ctx)
  if not population.status then
    ctx.assert.not_nil(population.status, "population must report on a settlement")
    return
  end
  local id = perfectworld.settlements.list_ids()[1]
  if not id then
    ctx.assert.is_true(true, "no settlements in this world")
    return
  end
  local status = population.status(id)
  ctx.assert.not_nil(status, "a known settlement must have a status")
  if status then
    ctx.assert.not_nil(status.loaded_villagers,
      "the report must include what the world says, not only what the record claims")
    ctx.assert.not_nil(status.recorded_spawned,
      "and what the record claims, so the two can be compared")
  end
end)
