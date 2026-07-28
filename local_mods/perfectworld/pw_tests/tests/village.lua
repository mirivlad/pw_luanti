-- tests/village.lua
-- PerfectWorld village planning and materialization tests (v2 pipeline).

local T = luanti_testkit

local function make_candidate(id, rx, rz, x, z)
  return {
    id = id,
    x = x, z = z,
    rx = rx, rz = rz,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    structure_id = id .. "_struct_0",
    rotation = 0,
    status = "candidate",
    region_id = perfectworld.get_region_id(rx, rz),
  }
end

-- Synthetic terrain keeps layout tests independent of which mapblocks the
-- server happens to have generated.
local function terrain(name)
  for _, spec in ipairs(perfectworld.planner.TERRAIN_SPECS) do
    if spec.name == name then
      local copy = {}
      for k, v in pairs(spec) do copy[k] = v end
      copy.seed_key = "village_test|" .. name
      return perfectworld.planner.make_synthetic_terrain(copy)
    end
  end
  error("unknown terrain spec: " .. tostring(name))
end

local function make_env(family, roughness, water)
  return {
    biome_id = "test:" .. family,
    biome_name = "test:" .. family,
    biome_family = family,
    heat = 50, humidity = 50, elevation = 0,
    roughness = roughness or 0,
    average_slope = roughness or 0,
    water_proximity = water or 999,
    vegetation_density = 50,
    available_material_profile = family,
  }
end

-- === Planning determinism ===

T.register_test("perfectworld", "village_plan_is_deterministic_across_calls", function(ctx)
  local candidate = make_candidate("det_village_v2", 0, 0, 1000, 1000)
  local a = perfectworld.planner.plan_village(candidate, nil, terrain("rolling"))
  local b = perfectworld.planner.plan_village(candidate, nil, terrain("rolling"))
  ctx.assert.equal(a.archetype, b.archetype, "archetype")
  ctx.assert.equal(a.size_class, b.size_class, "size class")
  ctx.assert.equal(#a.lots, #b.lots, "lot count")
  ctx.assert.equal(#a.roads, #b.roads, "road count")
  ctx.assert.equal(a.exact_plan_fingerprint, b.exact_plan_fingerprint, "exact fingerprint")
  ctx.assert.equal(a.road_graph_fingerprint, b.road_graph_fingerprint, "road graph fingerprint")
  ctx.assert.equal(a.structural_fingerprint, b.structural_fingerprint, "structural fingerprint")
end)

T.register_test("perfectworld", "village_different_candidates_produce_different_plans", function(ctx)
  -- Real assertion, not a tautology: distinct candidates in distinct regions
  -- must yield distinct exact fingerprints.
  local fingerprints = {}
  local unique = 0
  for i = 1, 12 do
    local candidate = make_candidate("diff_v2_" .. i, i, i, 1500 + i * 260, 1500 - i * 240)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("gentle_slope"))
    if not fingerprints[plan.exact_plan_fingerprint] then
      fingerprints[plan.exact_plan_fingerprint] = true
      unique = unique + 1
    end
  end
  ctx.assert.is_true(unique >= 10,
    "expected at least 10 distinct plans out of 12 candidates, got " .. unique)
end)

T.register_test("perfectworld", "village_world_seed_changes_the_plan", function(ctx)
  local base = make_candidate("seed_axis_v2", 3, -2, 2200, -1400)
  local other = make_candidate("seed_axis_v2", 3, -2, 2200, -1400)
  other.world_seed_override = "some_other_world_seed"
  local a = perfectworld.planner.plan_village(base, nil, terrain("rolling"))
  local b = perfectworld.planner.plan_village(other, nil, terrain("rolling"))
  ctx.assert.is_true(a.seed_key ~= b.seed_key, "seed keys must differ per world seed")
  ctx.assert.is_true(
    a.exact_plan_fingerprint ~= b.exact_plan_fingerprint
    or a.archetype ~= b.archetype
    or #a.lots ~= #b.lots,
    "a different world seed must change the plan")
end)

-- === Plan structure ===

T.register_test("perfectworld", "village_plan_has_roads_and_bounds", function(ctx)
  local candidate = make_candidate("struct_village_v2", 0, 0, 1200, 1200)
  local plan = perfectworld.planner.plan_village(candidate, nil, terrain("flat_upland"))
  ctx.assert.is_true(#plan.roads >= 1, "plan must have at least one road")
  for _, road in ipairs(plan.roads) do
    ctx.assert.is_true(#road.points >= 2, "road " .. road.id .. " must have >= 2 points")
    ctx.assert.not_nil(road.kind, "road must declare a kind")
    ctx.assert.is_true((road.width or 0) >= 1, "road must have a positive width")
  end
  ctx.assert.not_nil(plan.bounds, "plan must have bounds")
  ctx.assert.is_true(plan.bounds.min_x <= plan.center.x and plan.bounds.max_x >= plan.center.x,
    "bounds must contain the centre on x")
  ctx.assert.is_true(plan.bounds.min_z <= plan.center.z and plan.bounds.max_z >= plan.center.z,
    "bounds must contain the centre on z")
end)

T.register_test("perfectworld", "village_bounds_contain_every_planned_element", function(ctx)
  for i = 1, 6 do
    local candidate = make_candidate("bounds_v2_" .. i, i, -i, 3000 + i * 300, -3000 - i * 300)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("rolling"))
    local b = plan.bounds
    for _, road in ipairs(plan.roads) do
      for _, p in ipairs(road.points) do
        ctx.assert.is_true(p.x >= b.min_x and p.x <= b.max_x and p.z >= b.min_z and p.z <= b.max_z,
          "road point outside bounds in " .. candidate.id)
      end
    end
    for _, lot in ipairs(plan.lots) do
      ctx.assert.is_true(
        lot.footprint_min.x >= b.min_x and lot.footprint_max.x <= b.max_x and
        lot.footprint_min.z >= b.min_z and lot.footprint_max.z <= b.max_z,
        "lot footprint outside bounds in " .. candidate.id)
    end
  end
end)

T.register_test("perfectworld", "village_plan_lots_never_overlap", function(ctx)
  for i = 1, 8 do
    local candidate = make_candidate("overlap_v2_" .. i, i * 2, i, 5000 + i * 400, 5000 - i * 380)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("gentle_slope"))
    for a = 1, #plan.lots do
      for b = a + 1, #plan.lots do
        local la, lb = plan.lots[a], plan.lots[b]
        local overlaps = la.footprint_min.x <= lb.footprint_max.x
          and la.footprint_max.x >= lb.footprint_min.x
          and la.footprint_min.z <= lb.footprint_max.z
          and la.footprint_max.z >= lb.footprint_min.z
        ctx.assert.is_false(overlaps,
          string.format("lots %d and %d overlap in %s", a, b, candidate.id))
      end
    end
  end
end)

T.register_test("perfectworld", "village_plan_keeps_roads_out_of_buildings", function(ctx)
  for i = 1, 8 do
    local candidate = make_candidate("roadclear_v2_" .. i, -i, i * 2, -5000 - i * 400, 5000 + i * 360)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("flat_lowland"))
    local cells = perfectworld.planner._road_cell_set(plan.roads)
    for _, lot in ipairs(plan.lots) do
      local hit = nil
      for x = lot.footprint_min.x, lot.footprint_max.x do
        for z = lot.footprint_min.z, lot.footprint_max.z do
          if cells[x .. ":" .. z] then hit = x .. "," .. z end
        end
      end
      ctx.assert.is_nil(hit, "road runs through a building in " .. candidate.id .. " at " .. tostring(hit))
    end
  end
end)

T.register_test("perfectworld", "village_roads_stay_on_walkable_ground", function(ctx)
  -- Regression: road polylines were laid out geometrically before any terrain
  -- was consulted, so a street ran off the clifftop, down the rock face and
  -- into the sea. Every consecutive pair of road points must now sit on real
  -- ground and stay within one terrace step of each other.
  local specs = {"steep_slope", "cliff", "rolling", "shoreline"}
  local checked = 0
  for i, name in ipairs(specs) do
    local sampler = terrain(name)
    local candidate = make_candidate("roadtrim_v2_" .. i, i * 4, -i * 2,
      11000 + i * 420, -11000 - i * 380)
    local plan = perfectworld.planner.plan_village(candidate, nil, sampler)
    for _, road in ipairs(plan.roads) do
      for p = 1, #road.points - 1 do
        local a, b = road.points[p], road.points[p + 1]
        local ya = sampler.surface_y(a.x, a.z)
        local yb = sampler.surface_y(b.x, b.z)
        ctx.assert.not_nil(ya, "road point without ground in " .. candidate.id)
        ctx.assert.not_nil(yb, "road point without ground in " .. candidate.id)
        ctx.assert.is_false(sampler.is_liquid(b.x, b.z),
          "road crosses unbuildable ground in " .. candidate.id)
        ctx.assert.is_true(math.abs(yb - ya) <= 3, string.format(
          "road step of %d blocks in %s (%s)", math.abs(yb - ya), candidate.id, name))
        checked = checked + 1
      end
    end
  end
  ctx.assert.is_true(checked > 0, "expected at least one road segment to check")
end)

T.register_test("perfectworld", "village_lot_rotation_is_supported_by_its_structure", function(ctx)
  -- Regression: wells only support rotation 0, but the old planner assigned a
  -- random rotation from {0,90,180,270}, so 3 out of 4 wells failed to place.
  for i = 1, 10 do
    local candidate = make_candidate("rot_v2_" .. i, i, i * 3, 7000 + i * 350, -7000 + i * 310)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("rolling"))
    for _, lot in ipairs(plan.lots) do
      local def = perfectworld.structures.get(lot.structure_name)
      ctx.assert.not_nil(def, "structure " .. lot.structure_name .. " must be registered")
      local allowed = false
      for _, r in ipairs(def.rotations or {}) do
        if r == lot.rotation then allowed = true end
      end
      ctx.assert.is_true(allowed, string.format(
        "%s got rotation %s which it does not support", lot.structure_name, tostring(lot.rotation)))
    end
  end
end)

T.register_test("perfectworld", "village_lots_face_their_road", function(ctx)
  local checked = 0
  local facing = 0
  for i = 1, 10 do
    local candidate = make_candidate("face_v2_" .. i, i * 3, -i, 9000 + i * 330, 9000 - i * 290)
    local plan = perfectworld.planner.plan_village(candidate, nil, terrain("flat_upland"))
    for _, lot in ipairs(plan.lots) do
      local def = perfectworld.structures.get(lot.structure_name)
      local connector
      for _, c in ipairs((def and def.connectors) or {}) do
        if c.type == "road" and c.offset_pos then connector = c.offset_pos end
      end
      if connector and #(def.rotations or {}) > 1 then
        checked = checked + 1
        local rotated = perfectworld.structures.rotate_point(connector, lot.rotation)
        local dx = lot.road_point.x - lot.center.x
        local dz = lot.road_point.z - lot.center.z
        -- The door direction must have a positive projection onto the road.
        if rotated.x * dx + rotated.z * dz > 0 then facing = facing + 1 end
      end
    end
  end
  ctx.assert.is_true(checked > 0, "expected at least one orientable lot")
  ctx.assert.equal(facing, checked, "every orientable lot must face its road")
end)

-- === Profile contract ===

T.register_test("perfectworld", "village_profile_is_idempotent", function(ctx)
  local candidate = make_candidate("idem_profile_v2", 51, 51, 51100, 51100)
  local env = make_env("temperate", 2, 200)
  local a = perfectworld.planner.create_village_profile(candidate, env)
  local b = perfectworld.planner.create_village_profile(candidate, env)
  ctx.assert.equal(a.seed_key, b.seed_key, "seed key")
  ctx.assert.equal(a.archetype, b.archetype, "archetype")
  ctx.assert.equal(a.size_class, b.size_class, "size class")
  ctx.assert.equal(a.target_lots, b.target_lots, "target lots")
  ctx.assert.equal(table.concat(a.structure_roles, ","), table.concat(b.structure_roles, ","),
    "role composition")
end)

T.register_test("perfectworld", "village_profile_always_requests_min_dwellings", function(ctx)
  for i = 1, 40 do
    local candidate = make_candidate("roles_v2_" .. i, i, i, 100 + i * 97, 100 - i * 89)
    local env = make_env(({"temperate", "cold", "dry", "rocky", "wet", "coastal", "forest"})[1 + i % 7],
      i % 9, (i % 3 == 0) and 10 or 400)
    local profile = perfectworld.planner.create_village_profile(candidate, env)
    local dwellings = 0
    for _, role in ipairs(profile.structure_roles) do
      if role == "dwelling" then dwellings = dwellings + 1 end
    end
    ctx.assert.is_true(dwellings >= perfectworld.planner.MIN_DWELLINGS,
      "profile " .. candidate.id .. " requested only " .. dwellings .. " dwellings")
    ctx.assert.equal(#profile.structure_roles, profile.target_lots,
      "role list length must equal target lot count")
  end
end)

T.register_test("perfectworld", "village_missing_production_role_is_not_viable", function(ctx)
  local candidate = make_candidate(
    "missing_production_v3", 71, 71, 71000, 71000)
  local env = make_env("forest", 1, 300)
  env.specialization = "forestry"
  env.ecology = {
    buildable_ratio = 0.8,
    soil_ratio = 0.7,
    water_ratio = 0,
    tree_ratio = 0.5,
    exposed_stone_ratio = 0,
    roughness = 1,
    humidity = 0.8,
    biome_family = "forest",
  }
  local profile = perfectworld.planner.create_village_profile(candidate, env)
  ctx.assert.not_nil(profile.required_role_counts,
    "profile must expose generic role requirements")
  ctx.assert.not_nil(perfectworld.planner.missing_required_roles,
    "planner must expose generic missing-role validation")
  if not profile.required_role_counts
    or not perfectworld.planner.missing_required_roles then
    return
  end

  profile.role_variants.sawmill = {"pw_missing_sawmill_for_test"}
  local plan = perfectworld.planner.build_village_plan(
    candidate, profile, env, terrain("flat_upland"))
  ctx.assert.is_true((plan.role_counts.dwelling or 0) >= 2,
    "the fixture must still fit its required dwellings")
  ctx.assert.equal(plan.role_counts.sawmill or 0, 0,
    "the missing production structure must not be invented")
  ctx.assert.is_false(plan.viable,
    "two houses without the required sawmill are not a viable forestry village")
  ctx.assert.contains(table.concat(plan.missing_required_roles or {}, ","),
    "sawmill<1", "the plan must explain the missing production role")
end)

T.register_test("perfectworld", "village_palette_follows_biome_family", function(ctx)
  local seen = {}
  for _, family in ipairs(perfectworld.compat.list_families()) do
    local candidate = make_candidate("palette_v2_" .. family, 7, 7, 7000, 7000)
    local profile = perfectworld.planner.create_village_profile(candidate, make_env(family, 1, 300))
    ctx.assert.equal(profile.palette_id, family, "palette id must match the biome family")
    ctx.assert.not_nil(profile.material_palette, "palette must exist for " .. family)
    seen[profile.material_palette.wall_primary .. "|" .. profile.material_palette.foundation] = true
  end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  ctx.assert.is_true(distinct >= 3,
    "biome palettes must differ in materials, got " .. distinct .. " distinct wall/foundation pairs")
end)

-- === Persistence ===

T.register_test("perfectworld", "planner_save_and_load_settlement_plan", function(ctx)
  local sid = "save_load_test"
  local plan = {
    id = sid,
    type = "village",
    center = {x = 1400, z = 1400},
    lots = {
      {center = {x = 1400, z = 1410}, role = "dwelling", structure_name = "pw_house_small_v1"},
      {center = {x = 1400, z = 1390}, role = "central", structure_name = "pw_well_v1"},
    },
  }
  perfectworld.planner.save_settlement_plan(sid, plan)
  local loaded = perfectworld.planner.get_settlement_plan(sid)
  ctx.assert.not_nil(loaded, "plan must load")
  ctx.assert.equal(#loaded.lots, 2, "loaded plan must have 2 lots")
  ctx.assert.equal(loaded.lots[1].structure_name, "pw_house_small_v1", "first lot structure")
  ctx.assert.equal(loaded.center.x, 1400, "center x")
  perfectworld.planner._test_clear_settlement(sid)
end)

T.register_test("perfectworld", "planner_save_and_load_road", function(ctx)
  local road = {
    id = "test_road_1",
    type = "local_road",
    from_settlement = "village_1",
    path = {{x = 0, y = 10, z = 0}, {x = 10, y = 10, z = 0}},
    length = 2,
  }
  perfectworld.planner.save_road(road)
  local loaded = perfectworld.planner.get_road("test_road_1")
  ctx.assert.not_nil(loaded, "road must load")
  ctx.assert.equal(loaded.length, 2, "road length")
  ctx.assert.equal(loaded.type, "local_road", "road type")
end)

-- === Street length ===

T.register_test("perfectworld", "a_settlement_gets_enough_street_for_the_lots_it_plans", function(ctx)
  -- Street length was drawn independently of how many buildings were meant to
  -- stand on it, so a village aiming at twelve ran out of frontage and stopped
  -- at four. The rule now: the main street is never shorter than the lots need,
  -- until it hits the cap that keeps the settlement inside the emerged area.
  local cap = perfectworld.planner.MAX_STREET_LENGTH
  ctx.assert.not_nil(cap, "the planner must state how long a street may get")
  if not cap then return end
  local checked, short = 0, {}
  for i = 1, 60 do
    local candidate = make_candidate("street_length_" .. i, i, i, 900 + i * 131, -700 - i * 117)
    local env = make_env(({"temperate", "cold", "dry", "rocky", "wet", "coastal", "forest"})[1 + i % 7],
      i % 4, (i % 3 == 0) and 10 or 400)
    local profile = perfectworld.planner.create_village_profile(candidate, env)
    local spacing = profile.lot_spacing
    local average_gap = (spacing.min_gap + spacing.max_gap) / 2
    -- Two sides to a street, a lot every average gap, and half again because
    -- anchors are lost to their neighbours and to the carriageway.
    local needed = math.min(cap,
      math.ceil(profile.target_lots / 2 * average_gap * 1.5))
    checked = checked + 1
    if profile.road_character.main_length < needed then
      short[#short + 1] = string.format("%s wants %d lots, needs %d, got %d",
        candidate.id, profile.target_lots, needed, profile.road_character.main_length)
    end
  end
  ctx.assert.is_true(checked > 0, "no profile was built, so nothing was proved")
  ctx.assert.equal(#short, 0,
    "these settlements have less street than lots: " .. table.concat(short, "; "))
end)

T.register_test("perfectworld", "a_bigger_settlement_never_gets_a_shorter_street", function(ctx)
  -- Two settlements alike in everything but appetite. The larger one may share
  -- the frontage between a main street and its side lanes, but the total street
  -- it is given must not go down as it asks for more.
  local candidate = make_candidate("street_growth", 33, 33, 33333, -33333)
  local env = make_env("temperate", 1, 400)
  ctx.assert.not_nil(perfectworld.planner.street_plan_for,
    "the planner must expose the rule that sizes a street")
  if not perfectworld.planner.street_plan_for then return end

  local base = perfectworld.planner.create_village_profile(candidate, env)
  for _, archetype in ipairs({"linear", "compact"}) do
    local previous, previous_target = nil, nil
    local shrunk = {}
    for target = 3, 20 do
      local profile = perfectworld.core.deep_copy(base)
      profile.archetype = archetype
      profile.target_lots = target
      local character = perfectworld.planner.street_plan_for(profile)
      local total = character.main_length + character.branches * character.branch_length
      if previous and total < previous then
        shrunk[#shrunk + 1] = string.format("%s: %d lots got %d, %d lots got %d",
          archetype, previous_target, previous, target, total)
      end
      previous, previous_target = total, target
    end
    ctx.assert.equal(#shrunk, 0,
      "street shrank as the settlement grew: " .. table.concat(shrunk, "; "))
  end
end)
