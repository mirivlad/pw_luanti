-- tests/planner.lua
-- PerfectWorld planner tests

local T = luanti_testkit

local function prepare_candidate_area(candidate, ground_y)
  -- For composite candidates (__village__), use a reasonable footprint for terrain prep.
  -- We don't materialize here — just clear the area so materialize_chunk can work.
  local structure_name = candidate.structure_name
  local def = perfectworld.structures.get(structure_name)
  local footprint_radius = 8
  if def then
    local minp, maxp = perfectworld.structures.get_footprint(def, {x = candidate.x, y = ground_y, z = candidate.z}, candidate.rotation or 0)
    footprint_radius = math.max(math.abs(maxp.x - candidate.x), math.abs(maxp.z - candidate.z),
                                math.abs(minp.x - candidate.x), math.abs(minp.z - candidate.z)) + 2
  end
  local minp = {x = candidate.x - footprint_radius, y = ground_y - 8, z = candidate.z - footprint_radius}
  local maxp = {x = candidate.x + footprint_radius, y = 256, z = candidate.z + footprint_radius}
  if minetest.load_area then
    pcall(minetest.load_area, minp, maxp)
  end
  for x = minp.x, maxp.x do
    for z = minp.z, maxp.z do
      minetest.set_node({x = x, y = ground_y - 1, z = z}, {name = perfectworld.compat.resolve("dirt")})
      for y = ground_y, 256 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  return minp, maxp
end

T.register_test("perfectworld", "planner_deterministic", function(ctx)
  local p1 = perfectworld.planner.plan_region(0, 0)
  local p2 = perfectworld.planner.plan_region(0, 0)
  ctx.assert.equal(p1.id, p2.id, "plan id must match across calls")
  ctx.assert.equal(
    p1.planner_version,
    p2.planner_version,
    "planner_version must match across calls"
  )
  ctx.assert.equal(
    #(p1.settlement_candidates or {}),
    #(p2.settlement_candidates or {}),
    "candidate count must be deterministic"
  )
  for i, c1 in ipairs(p1.settlement_candidates or {}) do
    local c2 = p2.settlement_candidates[i]
    ctx.assert.equal(c1.id, c2.id, "candidate id must be deterministic")
    ctx.assert.equal(c1.x, c2.x, "candidate x must be deterministic")
    ctx.assert.equal(c1.z, c2.z, "candidate z must be deterministic")
    ctx.assert.equal(c1.type, c2.type, "candidate type must be deterministic")
  end
end)

T.register_test("perfectworld", "planner_candidates_not_nil", function(ctx)
  local plan = perfectworld.planner.plan_region(0, 0)
  ctx.assert.not_nil(plan, "plan must not be nil")
  ctx.assert.not_nil(plan.settlement_candidates, "plan.candidates must not be nil")
  ctx.assert.is_true(type(plan.settlement_candidates) == "table", "candidates must be a table")
end)

T.register_test("perfectworld", "planner_candidate_structure", function(ctx)
  local plan = perfectworld.planner.plan_region(0, 0)
  for i, c in ipairs(plan.settlement_candidates or {}) do
    ctx.assert.not_nil(c.id, "candidate " .. i .. " must have id")
    ctx.assert.not_nil(c.type, "candidate " .. i .. " must have type")
    ctx.assert.not_nil(c.priority, "candidate " .. i .. " must have priority")
    ctx.assert.is_true(c.priority >= 1 and c.priority <= 5, "priority must be 1-5, got " .. tostring(c.priority))
    ctx.assert.is_true(c.connection_required == true, "candidate " .. i .. " must require connection")
    ctx.assert.equal(c.status, "candidate", "candidate " .. i .. " status must be candidate")
    ctx.assert.not_nil(c.x, "candidate " .. i .. " x must exist")
    ctx.assert.not_nil(c.z, "candidate " .. i .. " z must exist")
  end
end)

T.register_test("perfectworld", "planner_candidates_in_region", function(ctx)
  local REGION_SIZE = perfectworld.REGION_SIZE or 1024
  local margin = 80
  for rx = -1, 1 do
    for rz = -1, 1 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      local r_min_x = rx * REGION_SIZE
      local r_min_z = rz * REGION_SIZE
      for i, c in ipairs(plan.settlement_candidates or {}) do
        local local_x = c.x - r_min_x
        local local_z = c.z - r_min_z
        ctx.assert.is_true(
          local_x >= margin,
          "candidate " .. i .. " in region (" .. rx .. "," .. rz .. ") local_x=" .. local_x .. " < margin=" .. margin
        )
        ctx.assert.is_true(
          local_x < REGION_SIZE - margin,
          "candidate " .. i .. " in region (" .. rx .. "," .. rz .. ") local_x=" .. local_x .. " >= " .. (REGION_SIZE - margin)
        )
        ctx.assert.is_true(
          local_z >= margin,
          "candidate " .. i .. " in region (" .. rx .. "," .. rz .. ") local_z=" .. local_z .. " < margin=" .. margin
        )
        ctx.assert.is_true(
          local_z < REGION_SIZE - margin,
          "candidate " .. i .. " in region (" .. rx .. "," .. rz .. ") local_z=" .. local_z .. " >= " .. (REGION_SIZE - margin)
        )
      end
    end
  end
end)

T.register_test("perfectworld", "planner_min_distance", function(ctx)
  for rx = -1, 1 do
    for rz = -1, 1 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      local candidates = plan.settlement_candidates or {}
      for i, a in ipairs(candidates) do
        for j, b in ipairs(candidates) do
          if i < j then
            local dx = math.abs(a.x - b.x)
            local dz = math.abs(a.z - b.z)
            local dist = math.sqrt(dx * dx + dz * dz)
            ctx.assert.is_true(
              dist >= 200 - 1,
              "candidates too close in region (" .. rx .. "," .. rz .. "): " .. a.id .. " and " .. b.id .. " distance=" .. dist
            )
          end
        end
      end
    end
  end
end)

T.register_test("perfectworld", "planner_isolation", function(ctx)
  local plan = perfectworld.planner.plan_region(5, -3)
  local candidates_before = #(plan.settlement_candidates or {})
  if plan.settlement_candidates[1] then
    plan.settlement_candidates[1].id = "mutated"
  end
  local plan2 = perfectworld.planner.plan_region(5, -3)
  ctx.assert.equal(
    candidates_before,
    #(plan2.settlement_candidates or {}),
    "second plan must return identical data"
  )
  if plan2.settlement_candidates[1] then
    ctx.assert.is_true(plan2.settlement_candidates[1].id ~= "mutated", "plan_region must return copies")
  end
end)

T.register_test("perfectworld", "planner_request_order_independent", function(ctx)
  local a1 = perfectworld.planner.plan_region(2, -2)
  local b1 = perfectworld.planner.plan_region(-3, 4)
  local b2 = perfectworld.planner.plan_region(-3, 4)
  local a2 = perfectworld.planner.plan_region(2, -2)
  ctx.assert.equal(a1.id, a2.id, "region A id must be independent from request order")
  ctx.assert.equal(b1.id, b2.id, "region B id must be independent from request order")
  ctx.assert.equal(#(a1.settlement_candidates or {}), #(a2.settlement_candidates or {}), "region A candidate count must match")
  ctx.assert.equal(#(b1.settlement_candidates or {}), #(b2.settlement_candidates or {}), "region B candidate count must match")
end)

T.register_test("perfectworld", "planner_stable_after_cache_reset", function(ctx)
  local p1 = perfectworld.planner.plan_region(-2, 3)
  perfectworld.planner._test_clear_cache()
  local p2 = perfectworld.planner.plan_region(-2, 3)
  ctx.assert.equal(p1.id, p2.id, "plan id must survive cache reset")
  ctx.assert.equal(#(p1.settlement_candidates or {}), #(p2.settlement_candidates or {}), "candidate count must survive cache reset")
  if p1.settlement_candidates[1] then
    ctx.assert.equal(p1.settlement_candidates[1].id, p2.settlement_candidates[1].id, "candidate id must survive cache reset")
    ctx.assert.equal(p1.settlement_candidates[1].structure_id, p2.settlement_candidates[1].structure_id, "structure id must survive cache reset")
    ctx.assert.equal(p1.settlement_candidates[1].rotation, p2.settlement_candidates[1].rotation, "rotation must survive cache reset")
  end
end)

T.register_test("perfectworld", "planner_decodes_each_storage_map_once_between_writes", function(ctx)
  local planner = perfectworld.planner
  local first_id = "pw_test_storage_cache_first"
  local second_id = "pw_test_storage_cache_second"
  planner._test_clear_settlement(first_id)
  planner._test_clear_settlement(second_id)
  planner.save_settlement_plan(first_id, {
    settlement = {settlement_id = first_id, status = "failed"},
  })
  planner.save_settlement_plan(second_id, {
    settlement = {settlement_id = second_id, status = "failed"},
  })
  planner._test_clear_cache()

  local original_parse_json = minetest.parse_json
  local parse_count = 0
  minetest.parse_json = function(...)
    parse_count = parse_count + 1
    return original_parse_json(...)
  end
  -- Reading two records from the same region must decode that region once.
  --
  -- This used to say "decoded once, not once per record" about the whole world,
  -- because settlements lived in one flat map. They are sharded by region now,
  -- so enumerating every settlement legitimately decodes every region — that is
  -- what asking about the whole world costs, and it is not a caching failure.
  -- The guarantee worth keeping is the per-shard one, so `list_settlements` is
  -- no longer inside the counted section. Both ids here carry no region tag and
  -- therefore share a shard.
  local ok, err = pcall(function()
    ctx.assert.not_nil(planner.get_settlement_plan(first_id),
      "first record must be readable")
    ctx.assert.not_nil(planner.get_settlement_plan(second_id),
      "second record must be readable")
  end)
  minetest.parse_json = original_parse_json
  planner._test_clear_settlement(first_id)
  planner._test_clear_settlement(second_id)
  if not ok then error(err) end

  ctx.assert.equal(parse_count, 1,
    "a region's storage must be decoded once, not once per record read from it")
end)

T.register_test("perfectworld", "planner_road_anchors_match_candidates", function(ctx)
  local plan = perfectworld.planner.plan_region(0, 0)
  ctx.assert.equal(#(plan.road_anchors or {}), #(plan.settlement_candidates or {}), "road anchor count must match candidate count")
  ctx.assert.equal(#(plan.reserved_areas or {}), #(plan.settlement_candidates or {}), "reserved area count must match candidate count")
end)

T.register_test("perfectworld", "materialize_chunk_places_complete_farmstead_across_chunk_boundary", function(ctx)
  local selected_plan, selected_candidate
  for rx = -2, 2 do
    for rz = -2, 2 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      for _, c in ipairs(plan.settlement_candidates or {}) do
        if c.structure_name ~= "__village__" then
          selected_plan = plan
          selected_candidate = c
          break
        end
      end
    end
    if selected_candidate then break end
  end

  if not selected_candidate then
    ctx.skip("no non-village settlement candidate in scanned deterministic regions")
    return
  end

  local c = selected_candidate
  local ground_y = 0
  local prep_minp, prep_maxp = prepare_candidate_area(c, ground_y)
  if minetest.load_area then
    pcall(minetest.load_area, prep_minp, prep_maxp)
  end
  if minetest.get_node({x = c.x, y = ground_y, z = c.z}).name == "ignore" then
    minetest.emerge_area(prep_minp, prep_maxp)
    ctx.skip("candidate boundary test area requested for emerge")
    return
  end

  perfectworld.planner._test_unmark_placed(c.id)
  perfectworld.planner._test_clear_structure(c.structure_id)

  local owner_minp = {x = c.x, y = ground_y - 8, z = c.z}
  local owner_maxp = {x = c.x, y = ground_y + 8, z = c.z}
  local materialize_result = perfectworld.planner.materialize_chunk(owner_minp, owner_maxp)
  local record = perfectworld.planner.get_structure(c.structure_id)
  ctx.assert.not_nil(
    record,
    "boundary-owned materialization record must exist; result=" .. minetest.write_json(materialize_result)
  )
  if not record then return end

  -- The point of this test is that the structure is built whole even though
  -- the owning mini-chunk is a single column: check a corner of the building
  -- that lies well outside it, whatever the current model happens to be.
  local def = perfectworld.structures.get(record.structure_name)
  local fp_min, fp_max = perfectworld.structures.get_footprint(
    def, record.position, record.rotation or 0)
  ctx.assert.is_true(fp_max.x - record.position.x >= 2,
    "the structure must extend beyond the owning column")
  local built = 0
  for x = fp_min.x, fp_max.x do
    for z = fp_min.z, fp_max.z do
      for y = record.position.y, record.position.y + def.size.y do
        local name = minetest.get_node({x = x, y = y, z = z}).name
        if name ~= "air" and name ~= "ignore" then built = built + 1 end
      end
    end
  end
  ctx.assert.is_true(built > 40, string.format(
    "the whole structure must be present outside the owner mini-chunk, found %d nodes", built))

  local placed_before = #perfectworld.planner.list_structures()
  perfectworld.planner.materialize_chunk(owner_minp, owner_maxp)
  local placed_after = #perfectworld.planner.list_structures()
  ctx.assert.equal(placed_before, placed_after, "second boundary materialization must not duplicate structure records")

  perfectworld.planner._test_unmark_placed(c.id)
  perfectworld.planner._test_clear_structure(c.structure_id)
  ctx.log("boundary materialized candidate " .. c.id .. " as " .. c.structure_id .. " from plan " .. selected_plan.id)
end)

T.register_test("perfectworld", "materialize_chunk_places_farmstead_once", function(ctx)
  local selected_plan, selected_candidate
  for rx = -2, 2 do
    for rz = -2, 2 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      for _, c in ipairs(plan.settlement_candidates or {}) do
        if c.structure_name ~= "__village__" then
          selected_plan = plan
          selected_candidate = c
          break
        end
      end
    end
    if selected_candidate then break end
  end

  if not selected_candidate then
    ctx.skip("no non-village settlement candidate in scanned deterministic regions")
    return
  end

  local c = selected_candidate
  local ground_y = 0
  local prep_minp, prep_maxp = prepare_candidate_area(c, ground_y)
  if minetest.get_node({x = c.x, y = ground_y, z = c.z}).name == "ignore" then
    minetest.emerge_area(prep_minp, prep_maxp)
    ctx.skip("candidate test area requested for emerge")
    return
  end

  perfectworld.planner._test_unmark_placed(c.id)
  perfectworld.planner._test_clear_structure(c.structure_id)

  local materialize_result = perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  ctx.assert.is_true(
    perfectworld.planner.is_placed(c.id),
    "candidate must be marked placed after materialization; result=" .. minetest.write_json(materialize_result)
  )

  local record = perfectworld.planner.get_structure(c.structure_id)
  ctx.assert.not_nil(
    record,
    "farmstead materialization record must exist; result=" .. minetest.write_json(materialize_result)
  )
  if not record then return end
  ctx.assert.equal(record.structure_name, "pw_farmstead_v1", "farmstead structure name")
  ctx.assert.is_true(#(record.entrances or {}) >= 1,
    "materialized structure record must persist its actual entrance")
  if record.entrances and record.entrances[1] then
    local entrance = record.entrances[1].position
    ctx.assert.not_nil(entrance, "persisted entrance must have a position")
    ctx.assert.equal(entrance.y, record.position.y,
      "persisted entrance must retain the materialized floor height")
  end

  local placed_before = #perfectworld.planner.list_placed()
  perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  local placed_after = #perfectworld.planner.list_placed()
  ctx.assert.equal(placed_before, placed_after, "second materialize_chunk call must not add duplicate placement records")

  ctx.log("materialized candidate " .. c.id .. " as " .. c.structure_id .. " from plan " .. selected_plan.id)
end)

T.register_test("perfectworld", "materialize_chunk_queues_village_candidates", function(ctx)
  -- A village spans more terrain than the mapchunk that contains its centre,
  -- so materialize_chunk must queue it for emerge-then-build instead of
  -- planning it against terrain that does not exist yet.
  local found_rx, found_rz, village_candidate
  for rx = 0, 9 do
    for rz = 0, 9 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      for _, c in ipairs(plan.settlement_candidates or {}) do
        if c.structure_name == perfectworld.planner.COMPOSITE_MARKER then
          found_rx, found_rz, village_candidate = rx, rz, c
          break
        end
      end
      if village_candidate then break end
    end
    if village_candidate then break end
  end
  ctx.assert.not_nil(village_candidate, "plan_region must produce a village candidate in regions 0..9")

  perfectworld.planner._test_unmark_placed(village_candidate.id)
  perfectworld.planner._test_clear_settlement(village_candidate.id)
  -- A previous run may still have this village in flight; queuing is
  -- deliberately a no-op while that is true, so clear the marker first.
  perfectworld.planner._test_clear_pending_village(village_candidate.id)

  local prep_minp, prep_maxp = prepare_candidate_area(village_candidate, 0)
  local result = perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)

  ctx.assert.equal(result.queued, 1,
    "the village must be queued, not built inline; result=" .. minetest.write_json(result))
  ctx.assert.is_false(perfectworld.planner.is_placed(village_candidate.id),
    "queuing must not mark the candidate placed before it is actually built")

  -- Queuing is idempotent: a second pass over the same chunk must not enqueue
  -- the same village again.
  local second = perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  ctx.assert.equal(second.queued, 0, "the same village must not be queued twice")

  -- Leave nothing in flight for the next run.
  perfectworld.planner._test_clear_pending_village(village_candidate.id)
  ctx.log("village candidate " .. village_candidate.id
    .. " at rx=" .. found_rx .. " rz=" .. found_rz .. " queued")
end)

T.register_test("perfectworld", "materialize_chunk_idempotent_across_calls", function(ctx)
  -- Select a non-village candidate and verify idempotency
  local selected_candidate = nil
  for rx = -2, 2 do
    for rz = -2, 2 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      for _, c in ipairs(plan.settlement_candidates or {}) do
        if c.structure_name ~= "__village__" then
          selected_candidate = c
          break
        end
      end
    end
    if selected_candidate then break end
  end

  if not selected_candidate then
    ctx.skip("no non-village candidate found")
    return
  end

  local ground_y = 0
  local prep_minp, prep_maxp = prepare_candidate_area(selected_candidate, ground_y)
  if minetest.get_node({x = selected_candidate.x, y = ground_y, z = selected_candidate.z}).name == "ignore" then
    minetest.emerge_area(prep_minp, prep_maxp)
    ctx.skip("idempotency test area requested for emerge")
    return
  end

  perfectworld.planner._test_unmark_placed(selected_candidate.id)
  perfectworld.planner._test_clear_structure(selected_candidate.structure_id)

  -- First materialization
  local result1 = perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  ctx.assert.is_true(result1.materialized >= 1, "first call must materialize")
  local count_after_first = #perfectworld.planner.list_structures()

  -- Second materialization
  local result2 = perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  local count_after_second = #perfectworld.planner.list_structures()
  ctx.assert.equal(count_after_first, count_after_second, "second call must not add structure records")
  ctx.assert.equal(result2.materialized, 0, "second call must not materialize new structures")

  perfectworld.planner._test_unmark_placed(selected_candidate.id)
  perfectworld.planner._test_clear_structure(selected_candidate.structure_id)
  ctx.log("idempotency verified for " .. selected_candidate.id)
end)

T.register_test("perfectworld", "materialize_region_candidate_rejects_unknown_special", function(ctx)
  -- Verify that an unregistered structure name produces a diagnostic error,
  -- not a Lua exception, when passed through the placement pipeline.
  local ground_y = 0
  local fake_pos = {x = -5000, y = ground_y, z = -5000}
  -- Prepare a small flat area so the placement attempt doesn't fail on terrain.
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = fake_pos.x - 8, y = ground_y - 8, z = fake_pos.z - 8},
      {x = fake_pos.x + 8, y = 256, z = fake_pos.z + 8})
  end
  for dx = -8, 8 do
    for dz = -8, 8 do
      minetest.set_node({x = fake_pos.x + dx, y = ground_y - 1, z = fake_pos.z + dz}, {name = perfectworld.compat.resolve("dirt")})
      for y = ground_y, 256 do
        minetest.set_node({x = fake_pos.x + dx, y = y, z = fake_pos.z + dz}, {name = "air"})
      end
    end
  end

  local placed, reason = perfectworld.structures.place("__invalid_special__", {
    structure_id = "structure_v1_test_unknown_0",
    pos = fake_pos,
    rotation = 0,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test_unknown_0",
  })
  ctx.assert.is_false(placed, "unknown structure name must be rejected")
  ctx.assert.contains(reason.reason, "not_registered", "diagnostic reason for unregistered structure")
  ctx.log("unknown structure correctly rejected: " .. tostring(reason.reason))
end)

T.register_test("perfectworld", "roads_api_persists_and_reads_back", function(ctx)
  local test_road = {
    id = "test_road_v1",
    type = "local_road",
    from_settlement = "settlement_test",
    to_farm = "settlement_test_farm",
    path = {
      {x = 100, y = 0, z = 200},
      {x = 105, y = 0, z = 205},
      {x = 110, y = 0, z = 210},
    },
    length = 3,
  }

  perfectworld.planner.save_road(test_road)

  local read_back = perfectworld.roads.get("test_road_v1")
  if not read_back then
    ctx.skip("roads.get returned nil — planner storage not available")
    return
  end
  ctx.assert.equal(read_back.id, "test_road_v1", "road id match")
  ctx.assert.equal(read_back.type, "local_road", "road type match")
  ctx.assert.equal(read_back.length, 3, "road length match")
  ctx.assert.equal(#read_back.path, 3, "road path point count match")

  local ids = perfectworld.roads.list_ids()
  ctx.assert.is_true(#ids > 0, "list_ids must return at least the test road")

  local routes = perfectworld.roads.list_routes()
  ctx.assert.is_true(#routes > 0, "list_routes must return at least the test road")

  local network = perfectworld.roads.get_network()
  local road_in_network = network["test_road_v1"]
  if road_in_network then
    ctx.assert.equal(road_in_network.length, 3, "network road length match")
  else
    ctx.assert.is_true(false, "get_network must contain test road")
  end

  ctx.log("road API roundtrip verified")
end)

-- === A lone building does not stand in the sea ===
--
-- `analyze_terrain` looks down a column for the first node that is not air and
-- not cover. Water is `buildable_to`, which makes it cover, so a lake reads as
-- its own bed: perfectly flat, perfectly acceptable ground. A farmstead went up
-- in it. Villages have refused flooded sites for a while; a lone building never
-- asked, and the result is in every screenshot of this world.

local WATER_SCENE_Y = 26

--- A basin of standing water with dry land on one side.
--
-- The water goes in on a second pass, after the whole basin exists. Filling
-- column by column pours into the neighbours that have not been dug yet and
-- the scene drains before it is finished.
--- A lake with a bank standing above it.
--
-- The bank has to be *above* the water, not merely beside it: ground level with
-- the water is refused too, and rightly — cut a foundation into it and the lake
-- comes in. A scene whose every offset is refused proves only that the search
-- can say no.
local function lay_flooded_scene(centre, reach, span)
  local ground = perfectworld.compat.get_material("ground", {required = false})
  local bank_y = WATER_SCENE_Y - 1
  local water_y = WATER_SCENE_Y - 3
  local minp = {x = centre.x - span, y = WATER_SCENE_Y - 8, z = centre.z - span}
  local maxp = {x = centre.x + span, y = WATER_SCENE_Y + 8, z = centre.z + span}
  if minetest.load_area then pcall(minetest.load_area, minp, maxp) end

  -- Solid to the top of the bank, then the basin carved strictly inside it, so
  -- the rim holds the water in.
  for x = minp.x, maxp.x do
    for z = minp.z, maxp.z do
      for y = minp.y, maxp.y do
        minetest.set_node({x = x, y = y, z = z},
          {name = y <= bank_y and ground or "air"})
      end
    end
  end
  for x = centre.x - reach, centre.x + reach do
    for z = centre.z - reach, centre.z + reach do
      for y = water_y, bank_y do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  -- The water goes in on a second pass, once the whole basin exists: filling
  -- as you dig pours each column into the neighbour that has not been dug yet.
  for x = centre.x - reach, centre.x + reach do
    for z = centre.z - reach, centre.z + reach do
      minetest.set_node({x = x, y = water_y, z = z},
        {name = "mcl_core:water_source"})
    end
  end
end

T.register_test("perfectworld", "a_lone_building_is_not_offered_a_site_in_the_water",
  function(ctx)
    ctx.assert.not_nil(perfectworld.planner._ranked_sites,
      "the site search must be reachable from a test")
    if not perfectworld.planner._ranked_sites then return end

    -- Far from anything the world planned, so the scene is the only thing
    -- under test.
    -- A lake ten nodes across the middle, with a bank standing above it: the
    -- search reaches sixteen nodes out, so there is dry ground for it to find
    -- and wet ground for it to refuse.
    local centre = {x = 24000, z = 24000}
    lay_flooded_scene(centre, 10, 30)
    perfectworld.planner._world_terrain.reset()

    ctx.assert.equal(
      minetest.get_node({x = centre.x, y = WATER_SCENE_Y - 3, z = centre.z}).name,
      "mcl_core:water_source", "the flooded scene must hold its water")

    -- Without this the test is vacuous, and it was: while a liquid counted as
    -- loose cover the sampler read the lake as its own bed, `is_liquid` was
    -- false everywhere, and an assertion that no offered site is wet passed
    -- because no site anywhere could ever be wet.
    ctx.assert.is_true(
      perfectworld.planner._world_terrain.is_liquid(centre.x, centre.z),
      "the middle of the lake must read as water, or this test proves nothing")

    local def = perfectworld.structures.get("pw_farmstead_v1")
    local ranked = perfectworld.planner._ranked_sites(
      {x = centre.x, z = centre.z, id = "test_wet_site"}, def)
    ctx.assert.is_true(#ranked > 0,
      "there is dry land at the edge of this scene and it must be offered")

    for _, site in ipairs(ranked) do
      local x = centre.x + site.offset.x
      local z = centre.z + site.offset.z
      ctx.assert.is_false(
        perfectworld.planner._world_terrain.is_liquid(x, z),
        string.format("offered a site standing in water at (%d,%d)", x, z))
    end
  end)

T.register_test("perfectworld", "the_site_search_offers_the_flattest_ground_first",
  function(ctx)
    if not perfectworld.planner._ranked_sites then return end

    -- A shelf: flat on one side of the candidate, stepped on the other. The
    -- search must prefer the shelf, whatever order the offsets were generated
    -- in.
    local centre = {x = 24200, z = 24200}
    local ground = perfectworld.compat.get_material("ground", {required = false})
    local base = WATER_SCENE_Y
    local minp = {x = centre.x - 30, y = base - 20, z = centre.z - 30}
    local maxp = {x = centre.x + 30, y = base + 20, z = centre.z + 30}
    if minetest.load_area then pcall(minetest.load_area, minp, maxp) end
    for x = minp.x, maxp.x do
      for z = minp.z, maxp.z do
        -- West of the candidate: level. East: a staircase climbing away.
        local top = base
        if x > centre.x then top = base + math.min(math.floor((x - centre.x) / 2), 12) end
        for y = minp.y, maxp.y do
          minetest.set_node({x = x, y = y, z = z},
            {name = y <= top and ground or "air"})
        end
      end
    end
    perfectworld.planner._world_terrain.reset()

    local def = perfectworld.structures.get("pw_farmstead_v1")
    local ranked = perfectworld.planner._ranked_sites(
      {x = centre.x, z = centre.z, id = "test_shelf_site"}, def)
    ctx.assert.is_true(#ranked > 0, "the search must offer something on dry land")
    if #ranked == 0 then return end
    ctx.assert.is_true(ranked[1].relief <= 1, string.format(
      "the flattest site must come first, got relief %d", ranked[1].relief))
    ctx.assert.is_true(ranked[1].offset.x <= 0, string.format(
      "the flat ground is west of the candidate, was offered x offset %d",
      ranked[1].offset.x))

    -- Determinism: the same ground answered twice gives the same order.
    perfectworld.planner._world_terrain.reset()
    local again = perfectworld.planner._ranked_sites(
      {x = centre.x, z = centre.z, id = "test_shelf_site"}, def)
    ctx.assert.equal(#again, #ranked, "the search must offer the same sites again")
    for index = 1, math.min(#again, #ranked) do
      ctx.assert.equal(
        again[index].offset.x .. ":" .. again[index].offset.z,
        ranked[index].offset.x .. ":" .. ranked[index].offset.z,
        "the search must not depend on table order at position " .. index)
    end
  end)

-- === Nobody builds a house at the waterline ===
--
-- The lot test refused a footprint with water *in* it, and a beach beside an
-- ocean has no water in it. So a settlement went up level with the sea, the
-- placer cut its foundations, and the sea came in: five lots, three of them
-- standing knee-deep in the ocean, every one of which had passed the liquid
-- test because on the day it was asked the ground was dry.

T.register_test("perfectworld", "a_lot_level_with_the_sea_is_refused", function(ctx)
  ctx.assert.not_nil(perfectworld.planner._terrain_verdict,
    "the lot ground test must be reachable from a test")
  if not perfectworld.planner._terrain_verdict then return end

  local ground = perfectworld.compat.get_material("ground", {required = false})
  local centre = {x = 24400, z = 24400}
  local shore_y = 30
  -- Dry, flat land west of x = centre; open water east of it, its surface at
  -- exactly the height of the land. Nothing about the land itself is wrong.
  local minp = {x = centre.x - 24, y = shore_y - 8, z = centre.z - 24}
  local maxp = {x = centre.x + 40, y = shore_y + 10, z = centre.z + 24}
  if minetest.load_area then pcall(minetest.load_area, minp, maxp) end
  -- Solid ground everywhere first, then the basin carved strictly inside it.
  -- A basin dug out to the edge of the scene has no walls and drains into
  -- whatever the world put next to it; the rim is what holds the water.
  for x = minp.x, maxp.x do
    for z = minp.z, maxp.z do
      for y = minp.y, maxp.y do
        minetest.set_node({x = x, y = y, z = z},
          {name = y < shore_y and ground or "air"})
      end
    end
  end
  for x = centre.x + 7, maxp.x - 1 do
    for z = minp.z + 1, maxp.z - 1 do
      for y = shore_y - 3, shore_y - 1 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  -- The water goes in after the basin exists, not column by column while it is
  -- still being dug.
  for x = centre.x + 7, maxp.x - 1 do
    for z = minp.z + 1, maxp.z - 1 do
      for y = shore_y - 3, shore_y - 1 do
        minetest.set_node({x = x, y = y, z = z}, {name = "mcl_core:water_source"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()

  local terrain = perfectworld.planner._world_terrain
  local probe = {x = centre.x + 12, y = shore_y - 1, z = centre.z}
  ctx.assert.is_true(terrain.is_liquid(probe.x, probe.z), string.format(
    "the shore scene must hold its water: at (%d,%d,%d) the node is %s, "
      .. "the column reads %s at y=%s",
    probe.x, probe.y, probe.z,
    minetest.get_node(probe).name,
    minetest.get_node({x = probe.x, y = shore_y, z = probe.z}).name,
    tostring(terrain.surface_y(probe.x, probe.z))))
  if not terrain.is_liquid(probe.x, probe.z) then return end

  -- A plot on the dry land, close enough to the water that cutting into it
  -- would let the sea in. The ground is flat, solid and liquid-free.
  local fp_min = {x = centre.x - 3, z = centre.z - 3}
  local fp_max = {x = centre.x + 3, z = centre.z + 3}
  local ok, reason = perfectworld.planner._terrain_verdict(fp_min, fp_max, 3, terrain)
  ctx.assert.is_false(ok,
    "a plot level with the sea beside it must be refused, got ok=" .. tostring(ok))
  ctx.assert.equal(reason, "waterline",
    "the refusal must name the waterline, got " .. tostring(reason))

  -- The same ground, raised two nodes above the water, is fine.
  for x = centre.x - 10, centre.x + 4 do
    for z = minp.z, maxp.z do
      minetest.set_node({x = x, y = shore_y, z = z}, {name = ground})
      minetest.set_node({x = x, y = shore_y + 1, z = z}, {name = ground})
    end
  end
  perfectworld.planner._world_terrain.reset()
  local dry_ok, dry_reason = perfectworld.planner._terrain_verdict(
    fp_min, fp_max, 3, terrain)
  ctx.assert.is_true(dry_ok, string.format(
    "ground standing above the water must still be buildable, refused: %s",
    tostring(dry_reason)))
end)
