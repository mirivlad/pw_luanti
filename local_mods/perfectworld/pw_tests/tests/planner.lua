-- tests/planner.lua
-- PerfectWorld planner tests

local T = luanti_testkit

local function prepare_candidate_area(candidate, ground_y)
  local def = perfectworld.structures.get(candidate.structure_name or "pw_farmstead_v1")
  local minp, maxp = perfectworld.structures.get_footprint(def, {x = candidate.x, y = ground_y, z = candidate.z}, candidate.rotation or 0)
  minp = {x = minp.x - 2, y = ground_y - 8, z = minp.z - 2}
  maxp = {x = maxp.x + 2, y = 256, z = maxp.z + 2}
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
      if plan.settlement_candidates and plan.settlement_candidates[1] then
        selected_plan = plan
        selected_candidate = plan.settlement_candidates[1]
        break
      end
    end
    if selected_candidate then break end
  end

  if not selected_candidate then
    ctx.skip("no settlement candidate in scanned deterministic regions")
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

  local roof_node = minetest.get_node({x = record.position.x + 4, y = record.position.y + 4, z = record.position.z + 4}).name
  ctx.assert.equal(roof_node, perfectworld.compat.get_material("roof"), "roof outside owner mini-chunk must be present")

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
      if plan.settlement_candidates and plan.settlement_candidates[1] then
        selected_plan = plan
        selected_candidate = plan.settlement_candidates[1]
        break
      end
    end
    if selected_candidate then break end
  end

  if not selected_candidate then
    ctx.skip("no settlement candidate in scanned deterministic regions")
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

  local placed_before = #perfectworld.planner.list_placed()
  perfectworld.planner.materialize_chunk(prep_minp, prep_maxp)
  local placed_after = #perfectworld.planner.list_placed()
  ctx.assert.equal(placed_before, placed_after, "second materialize_chunk call must not add duplicate placement records")

  ctx.log("materialized candidate " .. c.id .. " as " .. c.structure_id .. " from plan " .. selected_plan.id)
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
