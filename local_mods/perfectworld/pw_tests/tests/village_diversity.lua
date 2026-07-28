-- tests/village_diversity.lua
-- Diversity and biome-adaptation contracts for the village generator.
--
-- Unlike the earlier version of this file these tests build *real plans*
-- (roads, lots, structures, fingerprints), not just profiles.

local T = luanti_testkit

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

local function make_candidate(id, rx, rz, x, z)
  return {
    id = id,
    x = x or 0, z = z or 0,
    rx = rx or 0, rz = rz or 0,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    structure_id = id .. "_struct_0",
    rotation = 0,
    status = "candidate",
    region_id = perfectworld.get_region_id(rx or 0, rz or 0),
  }
end

-- === Determinism ===

T.register_test("perfectworld", "village_deterministic_profile", function(ctx)
  local c = make_candidate("test_det_1", 0, 0, 100, 100)
  local env = make_env("temperate", 2, 200)
  local a = perfectworld.planner.create_village_profile(c, env)
  local b = perfectworld.planner.create_village_profile(c, env)
  ctx.assert.equal(a.archetype, b.archetype, "same candidate+env must give same archetype")
  ctx.assert.equal(a.size_class, b.size_class, "same candidate+env must give same size_class")
  ctx.assert.equal(a.target_lots, b.target_lots, "same candidate+env must give same target_lots")
end)

T.register_test("perfectworld", "village_different_seeds_differ", function(ctx)
  -- Over a spread of candidates the profiles must actually vary; a generator
  -- that always returned the same profile would pass a per-pair check by luck.
  local combos = {}
  local unique = 0
  for i = 1, 30 do
    local c = make_candidate("test_seed_" .. i, i, 31 - i, 100 + i * 173, 100 - i * 151)
    local p = perfectworld.planner.create_village_profile(c, make_env("temperate", 2, 200))
    local key = p.archetype .. "|" .. p.size_class .. "|" .. p.target_lots
    if not combos[key] then
      combos[key] = true
      unique = unique + 1
    end
  end
  ctx.assert.is_true(unique >= 8,
    "expected at least 8 distinct archetype/size/lot combinations over 30 seeds, got " .. unique)
end)

-- === Archetypes ===

T.register_test("perfectworld", "village_archetypes_available", function(ctx)
  local families = perfectworld.compat.list_families()
  ctx.assert.is_true(#families >= 7, "must have at least 7 biome families, got " .. #families)
  ctx.assert.equal(#perfectworld.planner.ARCHETYPES, 3, "three archetypes must be declared")
end)

T.register_test("perfectworld", "village_terrain_steers_archetype_choice", function(ctx)
  local function distribution(env)
    local counts = {linear = 0, compact = 0, hillside = 0}
    for i = 1, 120 do
      local c = make_candidate("test_arch_" .. i, i, 0, 100 + i * 211, 100)
      local p = perfectworld.planner.create_village_profile(c, env)
      counts[p.archetype] = (counts[p.archetype] or 0) + 1
    end
    return counts
  end

  local rough = distribution(make_env("temperate", 8, 500))
  local flat = distribution(make_env("temperate", 0, 500))
  local shore = distribution(make_env("temperate", 0, 8))

  ctx.assert.is_true(rough.hillside > flat.hillside, string.format(
    "rough terrain must favour hillside (rough=%d flat=%d)", rough.hillside, flat.hillside))
  ctx.assert.is_true(shore.linear > flat.linear, string.format(
    "water proximity must favour linear (shore=%d inland=%d)", shore.linear, flat.linear))
  for _, archetype in ipairs(perfectworld.planner.ARCHETYPES) do
    ctx.assert.is_true(flat[archetype] > 0, archetype .. " must be reachable on flat terrain")
  end
end)

-- === Biome palettes ===

T.register_test("perfectworld", "village_biome_palettes_differ", function(ctx)
  local families = perfectworld.compat.list_families()
  local palettes = {}
  for _, f in ipairs(families) do
    local p = perfectworld.compat.get_family_palette(f)
    ctx.assert.not_nil(p, "palette for " .. f .. " must exist")
    palettes[f] = p
    for _, key in ipairs({"foundation", "wall_primary", "roof", "path"}) do
      local node_name = p[key]
      ctx.assert.is_true(node_name == "air" or minetest.registered_nodes[node_name] ~= nil,
        string.format("palette %s.%s = %s is not a registered node", f, key, tostring(node_name)))
    end
  end
  ctx.assert.is_true(
    palettes["cold"].foundation ~= palettes["dry"].foundation or
    palettes["cold"].wall_primary ~= palettes["dry"].wall_primary,
    "cold and dry palettes must differ")
  ctx.assert.is_true(palettes["rocky"].wall_primary ~= palettes["temperate"].wall_primary,
    "rocky and temperate walls must differ")
end)

T.register_test("perfectworld", "village_palette_reaches_the_building_generator", function(ctx)
  -- Regression: palettes used to be computed and then never applied, so every
  -- village was built out of oak regardless of biome.
  local rocky = perfectworld.compat.get_family_palette("rocky")
  local resolved = perfectworld.structures.palette_material(rocky, "wall_primary", "wall")
  ctx.assert.equal(resolved, rocky.wall_primary, "palette wall must win over the generic material")

  local generic = perfectworld.structures.palette_material(nil, "wall_primary", "wall")
  ctx.assert.equal(generic, perfectworld.compat.get_material("wall", {required = false}),
    "without a palette the generic material is used")

  local bogus = perfectworld.structures.palette_material({wall_primary = "no_such:node"},
    "wall_primary", "wall")
  ctx.assert.equal(bogus, perfectworld.compat.get_material("wall", {required = false}),
    "an unregistered palette node must fall back to the generic material")
end)

T.register_test("perfectworld", "biome_ids_resolve_to_families", function(ctx)
  -- Regression: minetest.get_biome_data returns a numeric biome *id*, but the
  -- resolver indexed minetest.registered_biomes (keyed by *name*) with it. The
  -- lookup always missed, so every biome in the world resolved to "temperate"
  -- and the whole palette system was dead in practice.
  ctx.assert.not_nil(minetest.get_biome_name, "minetest.get_biome_name must exist")

  local families = {}
  local resolved_ids = 0
  for name in pairs(minetest.registered_biomes or {}) do
    local id = minetest.get_biome_id(name)
    if id then
      resolved_ids = resolved_ids + 1
      ctx.assert.equal(perfectworld.compat.resolve_biome_name(id), name,
        "biome id " .. id .. " must resolve back to " .. name)
      families[perfectworld.compat.get_biome_family(id)] = true
    end
  end
  ctx.assert.is_true(resolved_ids > 10,
    "expected the game to register more than 10 biomes, got " .. resolved_ids)

  local distinct = 0
  for _ in pairs(families) do distinct = distinct + 1 end
  ctx.assert.is_true(distinct >= 4, string.format(
    "resolving every registered biome id must reach at least 4 families, got %d", distinct))
end)

T.register_test("perfectworld", "frozen_and_liquid_surfaces_are_unbuildable", function(ctx)
  -- Regression: the surface check only looked for "water" in the node name.
  -- A frozen ocean is flat, solid and walkable, so every geometric check
  -- passed and a village was materialized on the sea.
  local unbuildable = {"mcl_core:water_source", "mcl_core:water_flowing",
    "mcl_core:river_water_source", "mcl_core:lava_source", "mcl_core:ice"}
  for _, name in ipairs(unbuildable) do
    if minetest.registered_nodes[name] then
      ctx.assert.is_true(perfectworld.compat.is_unbuildable_surface(name),
        name .. " must not be treated as buildable ground")
    end
  end

  -- Every registered ice-like node must be rejected, not just the ones above.
  local ice_nodes = 0
  for name, def in pairs(minetest.registered_nodes) do
    if (def.groups or {}).ice then
      ice_nodes = ice_nodes + 1
      ctx.assert.is_true(perfectworld.compat.is_unbuildable_surface(name),
        "ice node " .. name .. " must not be treated as buildable ground")
    end
  end
  ctx.assert.is_true(ice_nodes > 0, "the game must register at least one ice node")

  for _, name in ipairs({"mcl_core:dirt", "mcl_core:stone", "mcl_core:sand",
    "mcl_core:dirt_with_grass"}) do
    if minetest.registered_nodes[name] then
      ctx.assert.is_false(perfectworld.compat.is_unbuildable_surface(name),
        name .. " must be buildable ground")
    end
  end

  ctx.assert.is_true(perfectworld.compat.is_liquid_node("mcl_core:water_source"),
    "water must be detected as a liquid")
  ctx.assert.is_false(perfectworld.compat.is_liquid_node("mcl_core:ice"),
    "ice is not a liquid, but it is still unbuildable")
  ctx.assert.is_false(perfectworld.compat.is_liquid_node("air"), "air is not a liquid")
end)

T.register_test("perfectworld", "village_unknown_biome_gets_fallback", function(ctx)
  local family = perfectworld.compat.get_biome_family("nonexistent_biome_xyz")
  ctx.assert.equal(family, "temperate", "unknown biome must fall back to temperate")
  local candidate = make_candidate("fallback_v2", 0, 0, 300, 300)
  local profile = perfectworld.planner.create_village_profile(candidate,
    make_env("nonexistent_biome_xyz", 1, 500))
  ctx.assert.equal(profile.palette_id, "temperate", "unknown family must resolve to the temperate palette")
  ctx.assert.not_nil(profile.material_palette, "fallback palette must exist")
end)

-- === Persistence ===

T.register_test("perfectworld", "village_settlement_record_saves", function(ctx)
  local c = make_candidate("test_persist_1", 50, 50, 51000, 51000)
  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)

  local env = make_env("temperate", 2, 200)
  local profile = perfectworld.planner.create_village_profile(c, env)
  perfectworld.planner.save_settlement_plan(c.id, {
    plan = {village_id = c.id, exact_plan_fingerprint = 12345, roads = {}, lots = {}},
    profile = profile,
    settlement = {
      settlement_id = c.id,
      archetype = profile.archetype,
      status = "complete",
      village_fingerprint = 12345,
      lot_count = profile.target_lots,
      center_pos = {x = c.x, y = 0, z = c.z},
      generator_version = profile.generator_version,
    },
  })
  perfectworld.planner.mark_placed(c.id)

  local s = perfectworld.settlements.get(c.id)
  ctx.assert.not_nil(s, "settlement record must be retrievable")
  ctx.assert.equal(s.archetype, profile.archetype, "archetype must match")
  ctx.assert.equal(s.village_fingerprint, 12345, "fingerprint must match")
  ctx.assert.is_true(#perfectworld.settlements.list_ids() >= 1, "list_ids must include the record")

  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
end)

T.register_test("perfectworld", "village_idempotent_profile", function(ctx)
  local c = make_candidate("test_idem_1", 51, 51, 51100, 51100)
  local env = make_env("temperate", 2, 200)
  local a = perfectworld.planner.create_village_profile(c, env)
  local b = perfectworld.planner.create_village_profile(c, env)
  ctx.assert.equal(a.archetype, b.archetype, "profile must be idempotent")
  ctx.assert.equal(a.target_lots, b.target_lots, "lot count must be idempotent")
  ctx.assert.equal(a.seed_key, b.seed_key, "seed_key must be idempotent")
end)

-- === Completeness contract ===

T.register_test("perfectworld", "village_failed_settlement_gets_failed_status", function(ctx)
  local c = make_candidate("test_fail_status", 60, 60, 60000, 60000)
  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)

  local profile = perfectworld.planner.create_village_profile(c, make_env("temperate", 2, 200))
  perfectworld.planner.save_settlement_plan(c.id, {
    plan = {village_id = c.id, lots = {}, roads = {}},
    profile = profile,
    settlement = {
      settlement_id = c.id,
      archetype = profile.archetype,
      status = "failed",
      exact_plan_fingerprint = 0,
      structural_fingerprint = 0,
      road_graph_fingerprint = 0,
      village_fingerprint = 0,
      lot_count = 0,
      structure_ids = {}, road_ids = {},
      center_pos = {x = c.x, y = 0, z = c.z},
      bounds = {min_x = c.x - 1, max_x = c.x + 1, min_z = c.z - 1, max_z = c.z + 1},
      generator_version = profile.generator_version,
    },
  })
  perfectworld.planner.mark_placed(c.id)

  local s = perfectworld.settlements.get(c.id)
  ctx.assert.equal(s.status, "failed", "empty settlement must be failed")
  ctx.assert.equal(s.lot_count, 0, "empty settlement lot_count must be 0")

  local report = perfectworld.planner.validate_settlement(c.id)
  ctx.assert.is_true(report.ok, "a correctly recorded failed settlement must validate: "
    .. table.concat(report.issues, ","))

  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
end)

T.register_test("perfectworld", "validator_rejects_complete_without_required_roles", function(ctx)
  local c = make_candidate("test_bad_complete", 61, 61, 61000, 61000)
  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)

  perfectworld.planner.save_settlement_plan(c.id, {
    plan = {village_id = c.id, lots = {}, roads = {}},
    profile = {},
    settlement = {
      settlement_id = c.id,
      status = "complete",
      lot_count = 1,
      planned_lot_count = 1,
      missing_required_roles = {"dwelling<2"},
      errors = {},
      exact_plan_fingerprint = 1, structural_fingerprint = 1, road_graph_fingerprint = 1,
      structure_ids = {}, road_ids = {},
      center_pos = {x = c.x, y = 0, z = c.z},
      bounds = {min_x = c.x - 1, max_x = c.x + 1, min_z = c.z - 1, max_z = c.z + 1},
    },
  })
  perfectworld.planner.mark_placed(c.id)

  local report = perfectworld.planner.validate_settlement(c.id)
  ctx.assert.is_false(report.ok, "complete settlement missing required roles must be invalid")
  ctx.assert.equal(report.checks.complete_has_required_roles, "FAIL:dwelling<2",
    "the required-role check must be the one that fails")

  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
end)

T.register_test("perfectworld", "validator_rejects_complete_with_partial_materialization", function(ctx)
  local c = make_candidate("test_partial_complete", 62, 62, 62000, 62000)
  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)

  perfectworld.planner.save_settlement_plan(c.id, {
    plan = {village_id = c.id, lots = {}, roads = {}},
    profile = {},
    settlement = {
      settlement_id = c.id,
      status = "complete",
      lot_count = 3,
      planned_lot_count = 6,
      missing_required_roles = {},
      errors = {},
      exact_plan_fingerprint = 1, structural_fingerprint = 1, road_graph_fingerprint = 1,
      structure_ids = {}, road_ids = {},
      center_pos = {x = c.x, y = 0, z = c.z},
      bounds = {min_x = c.x - 1, max_x = c.x + 1, min_z = c.z - 1, max_z = c.z + 1},
    },
  })
  perfectworld.planner.mark_placed(c.id)

  local report = perfectworld.planner.validate_settlement(c.id)
  ctx.assert.is_false(report.ok, "complete settlement with unbuilt lots must be invalid")
  ctx.assert.contains(report.checks.complete_fully_materialized, "FAIL",
    "the materialization-completeness check must fail")

  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
end)

T.register_test("perfectworld", "validator_checks_required_worksite_in_the_real_world", function(ctx)
  local c = make_candidate("test_worksite_validation", 63, 63, 63000, 63000)
  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
  local pos = {x = c.x, y = 20, z = c.z}
  if minetest.load_area then pcall(minetest.load_area, pos, pos) end
  minetest.set_node(pos, {name = "air"})
  local expected_name = perfectworld.compat.get_material("wall")
  minetest.set_node(pos, {name = expected_name})
  expected_name = minetest.get_node(pos).name
  minetest.set_node(pos, {name = "air"})

  perfectworld.planner.save_settlement_plan(c.id, {
    plan = {
      village_id = c.id,
      lots = {},
      roads = {},
      bounds = {
        min_x = pos.x - 1, max_x = pos.x + 1,
        min_z = pos.z - 1, max_z = pos.z + 1,
      },
    },
    profile = {},
    settlement = {
      settlement_id = c.id,
      status = "complete",
      lot_count = 1,
      planned_lot_count = 1,
      missing_required_roles = {},
      errors = {},
      exact_plan_fingerprint = 1,
      structural_fingerprint = 1,
      road_graph_fingerprint = 1,
      structure_ids = {},
      road_ids = {},
      center_pos = pos,
      bounds = {
        min_x = pos.x - 1, max_x = pos.x + 1,
        min_z = pos.z - 1, max_z = pos.z + 1,
      },
      required_worksite = "field",
      worksite_ids = {"test_worksite_validation_field"},
      worksites = {{
        id = "test_worksite_validation_field",
        kind = "field",
        required = true,
        status = "materialized",
        bounds = {min = pos, max = pos},
        footprint_cells = {{x = pos.x, z = pos.z}},
        expected_nodes = {{position = pos, node_name = expected_name}},
        node_count = 1,
      }},
    },
  })
  perfectworld.planner.mark_placed(c.id)

  local missing = perfectworld.planner.validate_settlement(c.id)
  ctx.assert.contains(missing.checks.worksites_present_in_world or "",
    "FAIL", "stored worksite record cannot prove a physical node exists")

  minetest.set_node(pos, {name = expected_name})
  local present = perfectworld.planner.validate_settlement(c.id)
  ctx.assert.equal(present.checks.worksites_present_in_world, "ok",
    "validator must accept the expected physical worksite node")

  perfectworld.planner._test_clear_settlement(c.id)
  perfectworld.planner._test_unmark_placed(c.id)
end)

-- === Real-plan diversity over the sampled map ===

T.register_test("perfectworld", "village_diversity_over_100_plans", function(ctx)
  -- Full plans (roads + lots + structures + fingerprints) across every biome
  -- family, every terrain archetype and several world seeds.
  local inputs = perfectworld.planner.build_analysis_sample({mode = "synthetic", count = 110})
  ctx.assert.is_true(#inputs >= 100, "sample must have at least 100 inputs, got " .. #inputs)
  local metrics = {
    total = 0, valid = 0, empty = 0, rejected = 0,
    archetypes = {}, families = {}, palettes = {}, size_classes = {},
    exact = {}, structural = {}, road_graph = {}, roles = {}, structures = {},
  }
  local function bump(tbl, key)
    key = tostring(key)
    tbl[key] = (tbl[key] or 0) + 1
  end
  local function count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
  end

  for _, input in ipairs(inputs) do
    local row = perfectworld.planner.analyze_input(input)
    metrics.total = metrics.total + 1
    if row.status == "valid" then
      metrics.valid = metrics.valid + 1
      bump(metrics.archetypes, row.archetype)
      bump(metrics.families, row.biome_family)
      bump(metrics.palettes, row.palette)
      bump(metrics.size_classes, row.size_class)
      bump(metrics.exact, row.exact_plan_fingerprint)
      bump(metrics.structural, row.structural_fingerprint)
      bump(metrics.road_graph, row.road_graph_fingerprint)
      bump(metrics.roles, row.role_composition)
      bump(metrics.structures, row.structure_composition)
      ctx.assert.is_true((row.lot_count or 0) > 0, "a valid plan must have lots: " .. row.input_id)
    elseif row.status == "empty" then
      metrics.empty = metrics.empty + 1
    elseif row.status == "rejected" then
      metrics.rejected = metrics.rejected + 1
    else
      ctx.assert.is_true(false, "planning errored for " .. tostring(row.input_id)
        .. ": " .. tostring(row.error))
    end
  end

  ctx.log(string.format("total=%d valid=%d rejected=%d empty=%d",
    metrics.total, metrics.valid, metrics.rejected, metrics.empty))
  ctx.log(string.format("archetypes=%d families=%d palettes=%d exact=%d road_graph=%d roles=%d structures=%d",
    count(metrics.archetypes), count(metrics.families), count(metrics.palettes),
    count(metrics.exact), count(metrics.road_graph),
    count(metrics.roles), count(metrics.structures)))

  ctx.assert.is_true(metrics.valid >= 60,
    "expected at least 60 viable plans in the sample, got " .. metrics.valid)
  ctx.assert.equal(count(metrics.archetypes), 3,
    "all three archetypes must appear, got " .. count(metrics.archetypes))
  ctx.assert.equal(count(metrics.palettes), #perfectworld.compat.list_families(),
    "every palette branch must appear, got " .. count(metrics.palettes))
  ctx.assert.is_true(count(metrics.exact) >= 20,
    "at least 20 distinct exact fingerprints required, got " .. count(metrics.exact))
  ctx.assert.is_true(count(metrics.road_graph) >= 10,
    "at least 10 distinct road graphs required, got " .. count(metrics.road_graph))
  ctx.assert.is_true(count(metrics.roles) >= 5,
    "at least 5 role compositions required, got " .. count(metrics.roles))
  ctx.assert.is_true(count(metrics.structures) >= 5,
    "at least 5 structure compositions required, got " .. count(metrics.structures))
end)

T.register_test("perfectworld", "village_same_input_gives_same_plan", function(ctx)
  local inputs = perfectworld.planner.build_analysis_sample({mode = "synthetic", count = 12})
  for _, input in ipairs(inputs) do
    local a = perfectworld.planner.analyze_input(input)
    local b = perfectworld.planner.analyze_input(input)
    ctx.assert.equal(b.status, a.status, "status must be reproducible for " .. input.input_id)
    ctx.assert.equal(b.exact_plan_fingerprint, a.exact_plan_fingerprint,
      "exact fingerprint must be reproducible for " .. input.input_id)
    ctx.assert.equal(b.road_graph_fingerprint, a.road_graph_fingerprint,
      "road graph fingerprint must be reproducible for " .. input.input_id)
  end
end)

-- === Buildings people can live in ===

T.register_test("perfectworld", "palettes_declare_a_full_building_kit", function(ctx)
  -- A palette that is missing its stairs or posts silently degrades every
  -- house in that biome back to a flat-lidded box.
  local required = {"foundation", "wall_primary", "wall_secondary", "wall_post",
    "floor_block", "roof_stair", "roof_slab", "window", "path", "fence", "fence_gate"}
  local roof_materials, wall_materials = {}, {}
  for _, family in ipairs(perfectworld.compat.list_families()) do
    local palette = perfectworld.compat.get_family_palette(family)
    ctx.assert.not_nil(palette, "palette missing for " .. family)
    for _, key in ipairs(required) do
      local node_name = palette[key]
      ctx.assert.not_nil(node_name, family .. " palette is missing " .. key)
      ctx.assert.is_true(node_name == "air" or minetest.registered_nodes[node_name] ~= nil,
        string.format("%s.%s = %s is not a registered node", family, key, tostring(node_name)))
    end
    roof_materials[palette.roof_stair] = true
    wall_materials[palette.wall_primary] = true
  end
  local distinct_roofs, distinct_walls = 0, 0
  for _ in pairs(roof_materials) do distinct_roofs = distinct_roofs + 1 end
  for _ in pairs(wall_materials) do distinct_walls = distinct_walls + 1 end
  ctx.assert.is_true(distinct_roofs >= 5,
    "biomes must not all share one roof material, got " .. distinct_roofs)
  ctx.assert.is_true(distinct_walls >= 5,
    "biomes must not all share one wall material, got " .. distinct_walls)
end)

T.register_test("perfectworld", "dwellings_have_a_porch_clear_of_the_eaves", function(ctx)
  -- Regression: the road connector used to sit directly under the roof
  -- overhang, so every downward surface scan found the roof instead of the
  -- ground and the door became unreachable.
  local checked = 0
  for _, name in ipairs(perfectworld.structures.list()) do
    local def = perfectworld.structures.get(name)
    local connector
    for _, c in ipairs(def.connectors or {}) do
      if c.type == "road" and c.offset_pos then connector = c.offset_pos end
    end
    if connector then
      checked = checked + 1
      local eave = math.floor(def.size.z / 2)
      ctx.assert.is_true(connector.z >= eave, string.format(
        "%s connector at z=%d is under its own %d-deep roof", name, connector.z, def.size.z))
      local footprint = def.terrain.building_footprint
      ctx.assert.is_true(footprint.max_z >= connector.z, string.format(
        "%s connector at z=%d is outside the prepared ground (max_z=%d)",
        name, connector.z, footprint.max_z))
    end
  end
  ctx.assert.is_true(checked >= 4, "expected at least 4 structures with a road connector")
end)

T.register_test("perfectworld", "bare_rock_and_ice_are_not_livable_ground", function(ctx)
  -- A village on naked andesite or on a glacier passes every geometric test
  -- and still looks absurd, because nothing could grow there.
  for _, name in ipairs({"mcl_core:stone", "mcl_core:andesite", "mcl_core:granite",
    "mcl_core:diorite", "mcl_core:gravel", "mcl_core:ice", "mcl_core:packed_ice",
    "mcl_core:water_source", "mcl_core:cobble"}) do
    if minetest.registered_nodes[name] then
      ctx.assert.is_false(perfectworld.compat.is_livable_ground(name),
        name .. " must not count as livable ground")
    end
  end
  for _, name in ipairs({"mcl_core:dirt", "mcl_core:dirt_with_grass", "mcl_core:podzol",
    "mcl_core:sand", "mcl_core:coarse_dirt", "mcl_core:dirt_with_grass_snow"}) do
    if minetest.registered_nodes[name] then
      ctx.assert.is_true(perfectworld.compat.is_livable_ground(name),
        name .. " must count as livable ground")
    end
  end
end)

T.register_test("perfectworld", "structures_offer_more_than_one_house_shape", function(ctx)
  -- Four identical boxes at different sizes is what made every village read
  -- as the same village.
  local dwellings = {}
  for _, name in ipairs(perfectworld.structures.list()) do
    local def = perfectworld.structures.get(name)
    for _, category in ipairs(def.categories or {}) do
      if category == "residential" then
        dwellings[name] = {x = def.size.x, y = def.size.y, z = def.size.z}
      end
    end
  end
  local shapes, count = {}, 0
  for _, size in pairs(dwellings) do
    local key = size.x .. "x" .. size.y .. "x" .. size.z
    if not shapes[key] then
      shapes[key] = true
      count = count + 1
    end
  end
  ctx.assert.is_true(count >= 4,
    "expected at least 4 distinct dwelling shapes, got " .. count)
end)
