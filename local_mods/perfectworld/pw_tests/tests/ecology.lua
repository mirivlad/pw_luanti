-- tests/ecology.lua
-- Ecological site evidence and settlement-specialization contracts.

local T = luanti_testkit

local function evidence(overrides)
  local value = {
    buildable_ratio = 0.8,
    soil_ratio = 0.1,
    water_ratio = 0,
    tree_ratio = 0,
    exposed_stone_ratio = 0,
    roughness = 1,
    average_slope = 1,
    shore_distance = nil,
    elevation = 40,
    humidity = 0.5,
    biome_family = "temperate",
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

T.register_test("perfectworld", "ecology_classifies_ground_below_canopy", function(ctx)
  ctx.assert.not_nil(perfectworld.compat.classify_node,
    "compat must expose ecological node classification")
  if not perfectworld.compat.classify_node then return end
  local trunk = perfectworld.compat.classify_node("mcl_trees:tree_oak")
  local leaves = perfectworld.compat.classify_node("mcl_trees:leaves_oak")
  local soil = perfectworld.compat.classify_node("mcl_core:dirt_with_grass")
  local stone = perfectworld.compat.classify_node("mcl_core:stone")

  ctx.assert.is_true(trunk.tree, "oak trunk must be tree evidence")
  ctx.assert.is_true(trunk.vegetation, "oak trunk must be skipped while finding ground")
  ctx.assert.is_true(leaves.leaves, "oak leaves must be leaf evidence")
  ctx.assert.is_true(leaves.vegetation, "oak leaves must be skipped while finding ground")
  ctx.assert.is_true(soil.soil, "grass must be soil")
  ctx.assert.is_true(soil.buildable_ground, "grass must be buildable ground")
  ctx.assert.is_true(stone.stone, "stone must be exposed-stone evidence")
  ctx.assert.is_false(stone.buildable_ground, "bare stone must not be ordinary living ground")
end)

T.register_test("perfectworld", "ecology_matching_evidence_selects_each_specialization", function(ctx)
  ctx.assert.not_nil(perfectworld.settlements.evaluate_specializations,
    "settlements must evaluate ecological specializations")
  if not perfectworld.settlements.evaluate_specializations then return end
  local fixtures = {
    fishing = evidence({
      water_ratio = 0.3,
      shore_distance = 8,
      biome_family = "coastal",
    }),
    farming = evidence({
      soil_ratio = 0.9,
      roughness = 0.5,
    }),
    forestry = evidence({
      tree_ratio = 0.55,
      buildable_ratio = 0.65,
      humidity = 0.8,
      biome_family = "forest",
    }),
    mining = evidence({
      exposed_stone_ratio = 0.55,
      roughness = 5,
      biome_family = "rocky",
    }),
  }

  for expected, fixture in pairs(fixtures) do
    local ranked = perfectworld.settlements.evaluate_specializations(fixture)
    ctx.assert.equal(ranked[1].id, expected, expected .. " evidence must rank first")
    ctx.assert.is_true(ranked[1].viable, expected .. " must be viable")
  end
end)

T.register_test("perfectworld", "ecology_biome_alone_cannot_claim_a_specialization", function(ctx)
  ctx.assert.not_nil(perfectworld.settlements.evaluate_specializations,
    "settlements must evaluate ecological specializations")
  if not perfectworld.settlements.evaluate_specializations then return end
  local ranked = perfectworld.settlements.evaluate_specializations(evidence({
    buildable_ratio = 0.2,
    biome_family = "coastal",
  }))

  for _, result in ipairs(ranked) do
    ctx.assert.is_false(result.viable, result.id .. " must need physical evidence")
  end
end)

T.register_test("perfectworld", "ecology_specialization_definitions_are_defensive_and_sorted", function(ctx)
  ctx.assert.not_nil(perfectworld.settlements.list_specializations,
    "settlements must list ecological specializations")
  ctx.assert.not_nil(perfectworld.settlements.get_specialization,
    "settlements must expose specialization definitions")
  if not perfectworld.settlements.list_specializations
    or not perfectworld.settlements.get_specialization then
    return
  end
  local ids = perfectworld.settlements.list_specializations()
  ctx.assert.equal(table.concat(ids, ","), "farming,fishing,forestry,mining",
    "specialization ids must have stable sorted order")

  local first = perfectworld.settlements.get_specialization("forestry")
  ctx.assert.not_nil(first, "forestry definition must exist")
  first.resource_features[1] = "mutated"
  local second = perfectworld.settlements.get_specialization("forestry")
  ctx.assert.is_false(second.resource_features[1] == "mutated",
    "callers must not mutate registered specialization definitions")
end)

T.register_test("perfectworld", "settlement_records_normalize_legacy_and_grammar_v3_data", function(ctx)
  ctx.assert.not_nil(perfectworld.settlements.normalize,
    "settlements must expose defensive record normalization")
  if not perfectworld.settlements.normalize then return end

  local legacy = {
    plan = {
      center = {x = 10, z = 20},
      bounds = {min_x = 1, max_x = 2, min_z = 3, max_z = 4},
      lots = {{index = 1, role = "dwelling"}},
    },
    profile = {},
    settlement = {
      settlement_id = "legacy_normalization",
      center_pos = {x = 101, y = 12, z = 202},
      bounds = {min_x = 90, max_x = 112, min_z = 190, max_z = 214},
      structure_ids = {"legacy_house"},
      road_ids = {"legacy_road"},
    },
  }
  local normalized_legacy = perfectworld.settlements.normalize(legacy)
  ctx.assert.not_nil(normalized_legacy, "legacy wrapped record must normalize")
  if not normalized_legacy then return end
  ctx.assert.equal(normalized_legacy.settlement_grammar_version, 2,
    "legacy records must report grammar version 2")
  ctx.assert.equal(normalized_legacy.center_pos.x, 101,
    "actual settlement center must beat planned center")
  ctx.assert.equal(normalized_legacy.bounds.max_z, 214,
    "actual settlement bounds must beat planned bounds")
  ctx.assert.equal(#normalized_legacy.plan_lots, 1,
    "legacy plan lots must remain available separately")
  ctx.assert.equal(#normalized_legacy.ecology, 0,
    "legacy ecology defaults to an empty table")
  ctx.assert.equal(#normalized_legacy.worksite_ids, 0,
    "legacy worksite ids default to an empty array")
  ctx.assert.equal(#normalized_legacy.worksite_kinds, 0,
    "legacy worksite kinds default to an empty array")
  ctx.assert.equal(#normalized_legacy.worksites, 0,
    "legacy worksite records default to an empty array")

  normalized_legacy.center_pos.x = -1
  normalized_legacy.plan_lots[1].role = "mutated"
  ctx.assert.equal(legacy.settlement.center_pos.x, 101,
    "normalization must not expose the stored center by reference")
  ctx.assert.equal(legacy.plan.lots[1].role, "dwelling",
    "normalization must not expose plan lots by reference")

  local current = {
    plan = {
      settlement_grammar_version = 3,
      center = {x = -10, z = -20},
      bounds = {min_x = -2, max_x = 2, min_z = -2, max_z = 2},
      lots = {{index = 2, role = "fishery"}},
    },
    profile = {settlement_grammar_version = 3},
    settlement = {
      settlement_id = "current_normalization",
      settlement_grammar_version = 3,
      center_pos = {x = 501, y = 22, z = 601},
      bounds = {min_x = 480, max_x = 530, min_z = 580, max_z = 635},
      specialization = "fishing",
      ecology = {water_ratio = 0.4},
      worksite_ids = {"dock_1"},
      worksite_kinds = {"dock"},
      worksites = {{id = "dock_1", kind = "dock"}},
    },
  }
  local normalized_current = perfectworld.settlements.normalize(current)
  ctx.assert.not_nil(normalized_current, "grammar-v3 record must normalize")
  if not normalized_current then return end
  ctx.assert.equal(normalized_current.settlement_grammar_version, 3,
    "grammar-v3 version must survive normalization")
  ctx.assert.equal(normalized_current.center_pos.x, 501,
    "grammar-v3 actual center must beat planned center")
  ctx.assert.equal(normalized_current.bounds.max_z, 635,
    "grammar-v3 actual bounds must beat planned bounds")
  ctx.assert.equal(normalized_current.specialization, "fishing",
    "specialization must survive normalization")
  ctx.assert.equal(normalized_current.worksites[1].kind, "dock",
    "worksite records must survive normalization")
end)

T.register_test("perfectworld", "ecology_profiles_require_their_local_work", function(ctx)
  local cases = {
    fishing = {role = "fishery", worksite = "dock"},
    farming = {role = "farm", worksite = "field"},
    forestry = {role = "sawmill", worksite = "forestry_yard"},
    mining = {role = "mine_workshop", worksite = "minehead"},
  }

  for specialization, expected in pairs(cases) do
    local definition = perfectworld.settlements.get_specialization(specialization)
    local environment = evidence({
      specialization = specialization,
      ecology = evidence(),
      biome_id = "test:" .. specialization,
      biome_name = "test:" .. specialization,
      water_proximity = 20,
      vegetation_density = 50,
      available_material_profile = "temperate",
    })
    local profile = perfectworld.planner.create_village_profile({
      id = "ecology_profile_" .. specialization,
      x = 320, z = 320, rx = 0, rz = 0,
    }, environment)

    ctx.assert.equal(profile.specialization, specialization,
      specialization .. " profile must retain the selected specialization")
    ctx.assert.not_nil(profile.required_role_counts,
      specialization .. " profile must expose required role counts")
    if profile.required_role_counts then
      ctx.assert.equal(profile.required_role_counts.dwelling, 2,
        specialization .. " must require two dwellings")
      ctx.assert.equal(profile.required_role_counts[expected.role], 1,
        specialization .. " must require one " .. expected.role)
    end
    ctx.assert.equal(profile.required_worksite, expected.worksite,
      specialization .. " worksite must follow its ecology")
    ctx.assert.equal(minetest.write_json(profile.resource_features),
      minetest.write_json(definition.resource_features),
      specialization .. " resource features must come from its definition")
    ctx.assert.not_nil(profile.role_variants and profile.role_variants[expected.role],
      specialization .. " must expose variants for its production role")
    ctx.assert.equal(table.concat({
      profile.structure_roles[1] or "?",
      profile.structure_roles[2] or "?",
      profile.structure_roles[3] or "?",
    }, ","), "dwelling,dwelling," .. expected.role,
      specialization .. " required roles must be scheduled before optional lots")
  end
end)

T.register_test("perfectworld", "fishing_main_street_runs_along_the_measured_shore", function(ctx)
  local candidate = {
    id = "fishing_shore_road_axis",
    x = 320,
    z = 320,
    rx = 0,
    rz = 0,
  }
  local function profile_for(direction)
    return perfectworld.planner.create_village_profile(candidate, {
      biome_name = "test:coastal",
      biome_family = "coastal",
      heat = 50,
      humidity = 50,
      elevation = 20,
      roughness = 0,
      water_proximity = 6,
      vegetation_density = 0,
      specialization = "fishing",
      ecology = {shore_direction = direction},
    })
  end

  local water_east = profile_for({x = 6, z = 0})
  local water_north = profile_for({x = 0, z = 6})
  ctx.assert.is_true(
    water_east.road_character.direction_index == 3
      or water_east.road_character.direction_index == 7,
    "east-facing water needs a north-south shore road")
  ctx.assert.is_true(
    water_north.road_character.direction_index == 1
      or water_north.road_character.direction_index == 5,
    "north-facing water needs an east-west shore road")
end)

local function ecology_api(ctx)
  local api = perfectworld.planner.ecology
  ctx.assert.not_nil(api, "planner must expose bounded ecological site selection")
  if not api then return nil end
  return api
end

T.register_test("perfectworld", "ecology_site_search_is_bounded_and_deterministic", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_sites", x = 100, z = 200, rx = 0, rz = 0}
  local a = api.enumerate_sites(candidate)
  local b = api.enumerate_sites(candidate)

  ctx.assert.equal(#a, 9, "site search must have exactly nine sites")
  ctx.assert.equal(minetest.write_json(a), minetest.write_json(b),
    "site enumeration must be deterministic")
  for _, site in ipairs(a) do
    ctx.assert.is_true(site.x >= 80 and site.x <= perfectworld.REGION_SIZE - 81,
      "site x must stay inside the regional margin")
    ctx.assert.is_true(site.z >= 80 and site.z <= perfectworld.REGION_SIZE - 81,
      "site z must stay inside the regional margin")
  end
end)

T.register_test("perfectworld", "ecology_survey_reads_exactly_81_columns", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local calls = 0
  local terrain = {
    sample_column = function()
      calls = calls + 1
      return {
        y = 32,
        buildable = true,
        soil = true,
        liquid = false,
        tree = false,
        stone = false,
      }
    end,
  }
  local result = api.survey_site({id = "center", x = 0, z = 0}, terrain, {
    biome_name = "test:temperate",
    biome_family = "temperate",
    humidity = 50,
  })

  ctx.assert.equal(calls, 81, "one site must sample exactly 9x9 columns")
  ctx.assert.equal(result.sample_count, 81, "survey must report its exact sample count")
  ctx.assert.equal(result.buildable_ratio, 1, "all columns are buildable")
  ctx.assert.equal(result.soil_ratio, 1, "all columns are soil")
end)

T.register_test("perfectworld", "ecology_gentle_slope_remains_farmable", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local terrain = perfectworld.planner.make_synthetic_terrain({
    base = 40,
    slope_x = 0.10,
    slope_z = 0.03,
    seed_key = "ecology_gentle_slope",
  })
  local surveyed = api.survey_site({id = "gentle", x = 320, z = 320}, terrain, {
    biome_name = "test:temperate",
    biome_family = "temperate",
    humidity = 50,
  })
  local ranked = perfectworld.settlements.evaluate_specializations(surveyed)

  ctx.assert.is_true(surveyed.roughness <= 3.5,
    "roughness must be a local gradient, not the full 48-node elevation range")
  ctx.assert.equal(ranked[1].id, "farming", "gentle soil slope must rank as farming")
  ctx.assert.is_true(ranked[1].viable, "gentle soil slope must remain viable")
end)

T.register_test("perfectworld", "ecology_world_sampler_finds_ground_below_tree_canopy", function(ctx)
  local terrain = perfectworld.planner._world_terrain
  ctx.assert.not_nil(terrain.sample_column,
    "world terrain must expose true-ground column samples")
  if not terrain.sample_column then return end

  local pos = {x = -1380, y = 35, z = -1380}
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = pos.x, y = pos.y - 2, z = pos.z},
      {x = pos.x, y = pos.y + 4, z = pos.z})
  end
  local snapshot = {}
  for y = pos.y - 2, pos.y + 4 do
    snapshot[#snapshot + 1] = {
      pos = {x = pos.x, y = y, z = pos.z},
      node = minetest.get_node({x = pos.x, y = y, z = pos.z}),
    }
  end

  minetest.set_node({x = pos.x, y = pos.y, z = pos.z},
    {name = "mcl_core:dirt_with_grass"})
  minetest.set_node({x = pos.x, y = pos.y + 1, z = pos.z},
    {name = "mcl_trees:leaves_oak"})
  minetest.set_node({x = pos.x, y = pos.y + 2, z = pos.z},
    {name = "mcl_trees:leaves_oak"})
  for y = pos.y + 3, pos.y + 4 do
    minetest.set_node({x = pos.x, y = y, z = pos.z}, {name = "air"})
  end

  terrain.reset()
  local column = terrain.sample_column(pos.x, pos.z)
  ctx.assert.equal(column.y, pos.y, "ground must be below the canopy")
  ctx.assert.is_true(column.tree,
    "a sampled canopy column must remain forest resource evidence")
  ctx.assert.is_true(column.soil, "the resolved ground must retain its soil class")

  for index = #snapshot, 1, -1 do
    minetest.set_node(snapshot[index].pos, snapshot[index].node)
  end
  terrain.reset()
end)

T.register_test("perfectworld", "village_paving_level_ignores_nearby_tree_trunks", function(ctx)
  local pos = {x = -2390, y = 28, z = -2390}
  local snapshot = {}
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = pos.x, y = pos.y - 2, z = pos.z},
      {x = pos.x, y = pos.y + 4, z = pos.z})
  end
  for y = pos.y - 2, pos.y + 4 do
    local node_pos = {x = pos.x, y = y, z = pos.z}
    snapshot[#snapshot + 1] = {pos = node_pos, node = minetest.get_node(node_pos)}
    minetest.set_node(node_pos, {name = "air"})
  end
  minetest.set_node(pos, {name = perfectworld.compat.get_material("ground")})
  minetest.set_node(
    {x = pos.x, y = pos.y + 1, z = pos.z},
    {name = perfectworld.compat.get_material("tree")})
  minetest.set_node(
    {x = pos.x, y = pos.y + 2, z = pos.z},
    {name = perfectworld.compat.get_material("tree")})

  perfectworld.planner._world_terrain.reset()
  local level = perfectworld.planner._paving_level(pos.x, pos.z, pos.y)
  ctx.assert.equal(level, pos.y,
    "roads and worksite anchors must use physical ground below a trunk")

  for index = #snapshot, 1, -1 do
    local entry = snapshot[index]
    minetest.set_node(entry.pos, entry.node)
  end
  perfectworld.planner._world_terrain.reset()
end)

T.register_test("perfectworld", "ecology_selects_a_viable_shore_site_instead_of_bad_anchor", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_shore", x = 320, z = 320, rx = 0, rz = 0}
  local sites = api.enumerate_sites(candidate)
  local target = sites[2]
  local terrain = {
    sample_column = function(x, z)
      local dx = x - target.x
      local dz = z - target.z
      if math.abs(dx) <= 24 and math.abs(dz) <= 24 then
        if dx >= 6 then
          return {y = 30, liquid = true, buildable = false, soil = false,
            tree = false, stone = false}
        end
        return {y = 31, liquid = false, buildable = true, soil = false,
          tree = false, stone = false}
      end
      return {y = 60, liquid = false, buildable = false, soil = false,
        tree = false, stone = false}
    end,
  }
  local selected = api.select_site(candidate, terrain, function()
    return {
      biome_name = "test:coastal",
      biome_family = "coastal",
      heat = 50,
      humidity = 50,
    }
  end)

  ctx.assert.not_nil(selected, "a usable shore site must be selected")
  if not selected then return end
  ctx.assert.equal(selected.site.id, target.id,
    "the resource-bearing ring site must beat the bad regional anchor")
  ctx.assert.equal(selected.specialization, "fishing",
    "the selected shore must produce a fishing profile")
  ctx.assert.not_nil(selected.evidence.shore_anchor,
    "fishing selection must retain its physical water anchor")
end)

T.register_test("perfectworld", "ecology_moves_a_water_center_to_measured_shore_land", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_water_center", x = 512, z = 512, rx = 0, rz = 0}
  local target = api.enumerate_sites(candidate)[2]
  local terrain = {
    sample_column = function(x, z)
      local dx = x - target.x
      local dz = z - target.z
      if math.abs(dx) <= 24 and math.abs(dz) <= 24 then
        if dx >= 12 or (dx == 0 and dz == 0) then
          return {y = 30, liquid = true, buildable = false, soil = false,
            tree = false, stone = false}
        end
        return {y = 31, liquid = false, buildable = true, soil = false,
          tree = false, stone = false}
      end
      return {y = 60, liquid = false, buildable = false, soil = false,
        tree = false, stone = false}
    end,
  }
  local selected = api.select_site(candidate, terrain, function()
    return {
      biome_name = "test:coastal",
      biome_family = "coastal",
      heat = 50,
      humidity = 50,
    }
  end)

  ctx.assert.not_nil(selected,
    "a measured buildable shore must rescue the survey without building in water")
  if selected then
    ctx.assert.equal(selected.specialization, "fishing",
      "the relocated site must retain the shoreline specialization")
    ctx.assert.equal(selected.site.x, selected.evidence.shore_land_anchor.x,
      "fishing center x must use the measured land anchor")
    ctx.assert.equal(selected.site.z, selected.evidence.shore_land_anchor.z,
      "fishing center z must use the measured land anchor")
  end
end)

T.register_test("perfectworld", "ecology_moves_a_dry_fishing_center_to_measured_shore_land", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_dry_shore_center", x = 512, z = 512, rx = 0, rz = 0}
  local target = api.enumerate_sites(candidate)[2]
  local terrain = {
    sample_column = function(x, z)
      local dx = x - target.x
      local dz = z - target.z
      if math.abs(dx) <= 24 and math.abs(dz) <= 24 then
        if dx >= 12 then
          return {y = 30, liquid = true, buildable = false, soil = false,
            tree = false, stone = false}
        end
        return {y = 31, liquid = false, buildable = true, soil = false,
          tree = false, stone = false}
      end
      return {y = 60, liquid = false, buildable = false, soil = false,
        tree = false, stone = false}
    end,
  }
  local selected = api.select_site(candidate, terrain, function()
    return {
      biome_name = "test:coastal",
      biome_family = "coastal",
      heat = 50,
      humidity = 50,
    }
  end)

  ctx.assert.not_nil(selected, "a dry survey center may still describe a usable shore")
  if selected then
    ctx.assert.equal(selected.specialization, "fishing",
      "the relocated dry site must retain the shoreline specialization")
    ctx.assert.equal(selected.site.x, selected.evidence.shore_land_anchor.x,
      "fishing center x must use measured shore land even when the survey center is dry")
    ctx.assert.equal(selected.site.z, selected.evidence.shore_land_anchor.z,
      "fishing center z must use measured shore land even when the survey center is dry")
  end
end)

T.register_test("perfectworld", "ecology_prefers_a_buildable_shoreline_span_over_the_nearest_pocket", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_usable_shore_span", x = 512, z = 512, rx = 0, rz = 0}
  local target = api.enumerate_sites(candidate)[2]
  local terrain = {
    sample_column = function(x, z)
      local dx = x - target.x
      local dz = z - target.z
      if math.abs(dx) > 24 or math.abs(dz) > 24 then
        return {y = 60, liquid = false, buildable = false, soil = false,
          tree = false, stone = false}
      end
      if dx == 18 or (dx == 0 and dz == 0) then
        return {y = 30, liquid = true, buildable = false, soil = false,
          tree = false, stone = false}
      end
      if math.abs(dx) <= 6 and math.abs(dz) <= 6
        and not (dx == -6 and dz == 0) then
        return {y = 31, liquid = false, buildable = false, soil = false,
          tree = false, stone = false}
      end
      return {y = 31, liquid = false, buildable = true, soil = false,
        tree = false, stone = false}
    end,
  }
  local selected = api.select_site(candidate, terrain, function()
    return {
      biome_name = "test:coastal",
      biome_family = "coastal",
      heat = 50,
      humidity = 50,
    }
  end)

  ctx.assert.not_nil(selected, "the survey contains a viable fishing shore")
  if selected then
    ctx.assert.equal(selected.specialization, "fishing",
      "the usable shoreline must retain the fishing specialization")
    ctx.assert.equal(selected.site.x, target.x + 12,
      "the long buildable bank must beat the nearer one-cell shore pocket")
    ctx.assert.equal(selected.site.z, target.z,
      "equal shoreline spans must resolve to the closest measured water cell")
  end
end)

T.register_test("perfectworld", "ecology_ranks_every_viable_site_specialization_pair", function(ctx)
  local api = ecology_api(ctx)
  if not api then return end
  local candidate = {id = "ecology_all_viable_pairs", x = 512, z = 512, rx = 0, rz = 0}
  local target = api.enumerate_sites(candidate)[2]
  local terrain = {
    sample_column = function(x, z)
      local dx = x - target.x
      local dz = z - target.z
      if math.abs(dx) <= 24 and math.abs(dz) <= 24 then
        local liquid = dx == 6
        return {
          y = liquid and 30 or 31,
          liquid = liquid,
          buildable = not liquid,
          soil = not liquid,
          tree = false,
          stone = false,
        }
      end
      return {y = 60, liquid = false, buildable = false, soil = false,
        tree = false, stone = false}
    end,
  }
  local _, _, ranked = api.select_site(candidate, terrain, function()
    return {
      biome_name = "test:coastal_farmland",
      biome_family = "temperate",
      heat = 50,
      humidity = 50,
    }
  end)
  local target_specializations = {}
  for _, pair in ipairs(ranked or {}) do
    if pair.survey_site.id == target.id then
      target_specializations[pair.specialization] = true
    end
  end

  ctx.assert.is_true(target_specializations.farming == true,
    "the mixed shore must retain its viable farming pair")
  ctx.assert.is_true(target_specializations.fishing == true,
    "the same site must retain fishing as a deterministic fallback pair")
end)

local function village_candidate(id)
  return {
    id = id,
    x = 320,
    z = 320,
    rx = 0,
    rz = 0,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    structure_id = id .. "_struct_0",
    status = "candidate",
    region_id = perfectworld.get_region_id(0, 0),
  }
end

T.register_test("perfectworld", "ecology_plan_uses_selected_physical_site", function(ctx)
  local candidate = village_candidate("ecology_plan_site")
  local terrain = perfectworld.planner.make_synthetic_terrain({
    base = 32,
    seed_key = "ecology_plan_site",
  })
  local expected = perfectworld.planner.ecology.select_site(candidate, terrain, function()
    return {
      biome_id = "test:temperate",
      biome_name = "test:temperate",
      biome_family = "temperate",
      heat = 50,
      humidity = 50,
    }
  end)
  ctx.assert.not_nil(expected, "flat synthetic soil must have a farming site")

  local plan, profile, environment = perfectworld.planner.plan_village(candidate, {
    biome_id = "test:temperate",
    biome_name = "test:temperate",
    biome_family = "temperate",
    heat = 50,
    humidity = 50,
  }, terrain)

  ctx.assert.equal(plan.settlement_grammar_version, 3, "new plan grammar version")
  ctx.assert.equal(profile.settlement_grammar_version, 3, "new profile grammar version")
  ctx.assert.equal(profile.specialization, "farming", "flat soil must select farming")
  ctx.assert.equal(profile.required_role_counts.farm, 1,
    "flat-soil village must require a farm")
  ctx.assert.is_true((plan.role_counts.farm or 0) >= 1,
    "flat-soil village must physically plan its farm")
  ctx.assert.is_true(plan.viable,
    "a farming plan is viable only after the farm and dwellings fit")
  ctx.assert.equal(environment.specialization, "farming",
    "environment must carry the selected specialization")
  ctx.assert.equal(plan.center.x, expected.site.x, "roads must use selected site x")
  ctx.assert.equal(plan.center.z, expected.site.z, "roads must use selected site z")
  ctx.assert.not_nil(profile.regional_anchor,
    "profile must retain the original regional anchor")
  ctx.assert.not_nil(profile.selected_site, "profile must persist selected site")
  if not profile.regional_anchor or not profile.selected_site then return end
  ctx.assert.equal(profile.regional_anchor.x, candidate.x,
    "profile must retain the original regional anchor")
  ctx.assert.equal(profile.selected_site.x, expected.site.x,
    "profile must persist selected site")
  ctx.assert.not_nil(profile.ecology, "profile must persist ecological evidence")
end)

T.register_test("perfectworld", "ecology_plan_retries_the_next_ranked_site_after_layout_failure", function(ctx)
  local candidate = village_candidate("ecology_plan_site_fallback")
  local definition = perfectworld.settlements.get_specialization("farming")
  local function selection(id, x, score)
    return {
      site = {id = id, x = x, z = 320},
      survey_site = {id = id, x = x, z = 320},
      evidence = {
        sample_count = 81,
        buildable_ratio = 1,
        soil_ratio = 1,
        water_ratio = 0,
        tree_ratio = 0,
        exposed_stone_ratio = 0,
        roughness = 0,
        average_slope = 0,
        elevation = 32,
        biome_name = "test:temperate",
        biome_family = "temperate",
        heat = 50,
        humidity = 0.5,
      },
      environment = {
        biome_id = "test:temperate",
        biome_name = "test:temperate",
        biome_family = "temperate",
        heat = 50,
        humidity = 50,
      },
      specialization = "farming",
      specialization_score = score,
      specialization_scores = {
        farming = {score = score, viable = true, reasons = {}},
      },
      definition = definition,
      tie = 0,
    }
  end
  local ranked = {
    selection("best_ecology", 320, 1),
    selection("usable_layout", 400, 0.9),
  }
  local terrain = {
    kind = "synthetic",
    sample_column = function()
      return {y = 32, liquid = false, buildable = true, soil = true}
    end,
    surface_y = function() return 32 end,
  }
  local original_select = perfectworld.planner.ecology.select_site
  local original_build = perfectworld.planner.build_village_plan
  local built_centers = {}
  local plan, profile
  local ok, err = pcall(function()
    perfectworld.planner.ecology.select_site = function()
      return ranked[1], nil, ranked
    end
    perfectworld.planner.build_village_plan = function(selected_candidate)
      built_centers[#built_centers + 1] = selected_candidate.x
      return {
        viable = selected_candidate.x == 400,
        rejections = selected_candidate.x == 400 and {} or {no_surface = 1},
        roads = {},
        lots = {},
        center = {x = selected_candidate.x, z = selected_candidate.z},
      }
    end
    plan, profile = perfectworld.planner.plan_village(candidate, nil, terrain)
  end)
  perfectworld.planner.ecology.select_site = original_select
  perfectworld.planner.build_village_plan = original_build
  if not ok then error(err) end

  ctx.assert.is_true(plan and plan.viable,
    "a failed top ecological pair must not hide a viable ranked site")
  ctx.assert.equal(plan and plan.center.x, 400,
    "the plan must use the next ranked site's physical center")
  ctx.assert.equal(profile and profile.selected_site.x, 400,
    "the persisted profile must describe the site that actually fit")
  ctx.assert.equal(table.concat(built_centers, ","), "320,400",
    "ranked sites must be tried once and in deterministic score order")
end)

T.register_test("perfectworld", "village_road_trim_starts_from_the_nearest_usable_center_point", function(ctx)
  local candidate = village_candidate("road_trim_usable_center")
  local environment = {
    biome_id = "test:shore",
    biome_name = "test:shore",
    biome_family = "temperate",
    heat = 50,
    humidity = 50,
    specialization = "farming",
    ecology = evidence({
      soil_ratio = 0.9,
      buildable_ratio = 0.9,
    }),
  }
  local profile = perfectworld.planner.create_village_profile(
    candidate, environment)
  profile.archetype = "linear"
  profile.road_character = {
    main_length = 10,
    branches = 0,
    curve = 0,
    crossing = false,
    direction_index = 1,
  }
  local terrain = {
    surface_y = function() return 32 end,
    is_liquid = function(x) return x <= candidate.x end,
    is_livable = function(x) return x > candidate.x end,
  }
  local plan = perfectworld.planner.build_village_plan(
    candidate, profile, environment, terrain)

  ctx.assert.equal(#plan.roads, 1,
    "an unusable first midpoint must not hide the dry half of the road")
  for _, point in ipairs(plan.roads[1] and plan.roads[1].points or {}) do
    ctx.assert.is_true(point.x > candidate.x,
      "the retained road must start on the nearest usable side")
  end
end)

T.register_test("perfectworld", "ecology_plan_rejects_a_region_without_viable_site", function(ctx)
  local candidate = village_candidate("ecology_plan_reject")
  local terrain = perfectworld.planner.make_synthetic_terrain({
    base = 80,
    seed_key = "ecology_plan_reject",
    column_at = function()
      return {
        y = 80,
        liquid = false,
        buildable = false,
        soil = false,
        tree = false,
        stone = false,
      }
    end,
  })
  local plan, profile = perfectworld.planner.plan_village(candidate, {
    biome_id = "test:barren",
    biome_name = "test:barren",
    biome_family = "temperate",
    heat = 50,
    humidity = 20,
  }, terrain)

  ctx.assert.is_false(plan.viable, "resource-free region must not get a generic village")
  ctx.assert.equal(plan.rejections.no_suitable_ecological_site, 1,
    "failed plan must preserve the ecological rejection")
  ctx.assert.equal(#plan.roads, 0, "failed ecological plan must not invent roads")
  ctx.assert.equal(#plan.lots, 0, "failed ecological plan must not invent lots")
  ctx.assert.equal(profile.ecology_error, "no_suitable_ecological_site",
    "profile must explain why selection failed")
end)
