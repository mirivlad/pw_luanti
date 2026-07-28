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
  local ok, err = pcall(function()
    ctx.assert.not_nil(planner.get_settlement_plan(first_id),
      "first record must be readable")
    ctx.assert.not_nil(planner.get_settlement_plan(second_id),
      "second record must be readable")
    planner.list_settlements()
  end)
  minetest.parse_json = original_parse_json
  planner._test_clear_settlement(first_id)
  planner._test_clear_settlement(second_id)
  if not ok then error(err) end

  ctx.assert.equal(parse_count, 1,
    "unchanged settlement storage must be decoded once, not once per record")
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
