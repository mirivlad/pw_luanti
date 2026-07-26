-- tests/structures.lua
-- PerfectWorld Structure Pipeline v1 tests

local T = luanti_testkit

local function fill_flat_area(center, radius, surface_y, clear_to_y)
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = center.x - radius, y = surface_y - 8, z = center.z - radius},
      {x = center.x + radius, y = clear_to_y, z = center.z + radius})
  end
  for dx = -radius, radius do
    for dz = -radius, radius do
      minetest.set_node({x = center.x + dx, y = surface_y, z = center.z + dz}, {name = perfectworld.compat.get_material("ground")})
      for y = surface_y + 1, clear_to_y do
        minetest.set_node({x = center.x + dx, y = y, z = center.z + dz}, {name = "air"})
      end
    end
  end
end

T.register_test("perfectworld", "composite_ids_cover_coordinates_and_types", function(ctx)
  ctx.assert.equal(perfectworld.get_region_id(0, 0), "region_v1_p0_p0", "zero region id")
  ctx.assert.equal(perfectworld.get_region_id(-2, 3), "region_v1_n2_p3", "negative/positive region id")
  ctx.assert.equal(perfectworld.get_region_id(0, -1), "region_v1_p0_n1", "positive zero/negative region id")
  ctx.assert.equal(perfectworld.core.settlement_id(2, -3, 1), "settlement_v1_p2_n3_1", "settlement id")
  ctx.assert.equal(perfectworld.core.road_anchor_id(2, -3, 1), "road_anchor_v1_p2_n3_1", "road anchor id")
  ctx.assert.equal(
    perfectworld.core.structure_id("settlement_v1_p2_n3_1", 1),
    "structure_v1_settlement_v1_p2_n3_1_1",
    "structure id"
  )
  ctx.assert.is_true(
    perfectworld.core.settlement_id(0, 0, 1) ~= perfectworld.core.road_anchor_id(0, 0, 1),
    "different object types with same local index must differ"
  )
  ctx.assert.is_true(
    perfectworld.get_region_id(0, 0) ~= perfectworld.get_region_id(0, 1),
    "neighboring region ids must differ"
  )
end)

T.register_test("perfectworld", "world_format_lock_detects_incompatible_changes", function(ctx)
  local current = perfectworld.core.make_world_format_record()
  local same = perfectworld.core.check_world_format(current, perfectworld.core.deep_copy(current))
  ctx.assert.is_true(same.ok, "identical world format records must be compatible")

  local changed_region = perfectworld.core.deep_copy(current)
  changed_region.region_size = changed_region.region_size + 1
  local region_check = perfectworld.core.check_world_format(current, changed_region)
  ctx.assert.is_false(region_check.ok, "changed region_size must be incompatible")
  ctx.assert.contains(table.concat(region_check.reasons, ","), "region_size", "region_size reason")

  local changed_seed = perfectworld.core.deep_copy(current)
  changed_seed.world_seed_fingerprint = "different"
  local seed_check = perfectworld.core.check_world_format(current, changed_seed)
  ctx.assert.is_false(seed_check.ok, "changed seed fingerprint must be incompatible")
  ctx.assert.contains(table.concat(seed_check.reasons, ","), "world_seed_fingerprint", "seed reason")
end)

T.register_test("perfectworld", "world_format_lock_initializes_reuses_and_disables_on_mismatch", function(ctx)
  local old_enabled = perfectworld.materialization_enabled
  local old_error = perfectworld.world_format_error
  local values = {}
  local fake_storage = {
    get_string = function(_, key) return values[key] or "" end,
    set_string = function(_, key, value) values[key] = value end,
  }

  local ok, first = perfectworld.core.init_world_format(fake_storage)
  ctx.assert.is_true(ok, "first world format init must succeed")
  ctx.assert.not_nil(values.pw_world_format_lock, "first init must write world format lock")
  ctx.assert.equal(first.region_size, perfectworld.REGION_SIZE, "stored region size")

  local repeat_ok, repeat_record = perfectworld.core.init_world_format(fake_storage)
  ctx.assert.is_true(repeat_ok, "repeat world format init must reuse compatible lock")
  ctx.assert.equal(repeat_record.world_seed_fingerprint, first.world_seed_fingerprint, "repeat seed fingerprint")

  local incompatible = perfectworld.core.deep_copy(first)
  incompatible.region_size = incompatible.region_size + 16
  values.pw_world_format_lock = minetest.write_json(incompatible)
  local mismatch_ok, mismatch = perfectworld.core.init_world_format(fake_storage)
  ctx.assert.is_false(mismatch_ok, "incompatible world format must disable materialization")
  ctx.assert.contains(table.concat(mismatch.reasons, ","), "region_size", "mismatch reason")
  ctx.assert.is_false(perfectworld.materialization_enabled, "materialization flag must be false after mismatch")

  perfectworld.materialization_enabled = old_enabled
  perfectworld.world_format_error = old_error
end)

T.register_test("perfectworld", "structure_registry_validates_schema_and_returns_copy", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  ctx.assert.not_nil(def, "pw_farmstead_v1 must be registered")
  ctx.assert.equal(def.version, 1, "farmstead version")
  ctx.assert.equal(def.placement.type, "lua", "farmstead placement type")
  ctx.assert.is_true(perfectworld.structures.validate(def), "registered farmstead definition must validate")
  def.size.x = 999
  local again = perfectworld.structures.get("pw_farmstead_v1")
  ctx.assert.is_true(again.size.x ~= 999, "get() must return a defensive copy")

  local ok, err = perfectworld.structures.validate({version = 1})
  ctx.assert.is_false(ok, "invalid definition must be rejected")
  ctx.assert.contains(err, "size", "invalid definition should explain missing size")
end)

T.register_test("perfectworld", "farmstead_rotations_transform_points_and_connectors", function(ctx)
  local p0 = perfectworld.structures.rotate_point({x = 2, y = 0, z = 4}, 0)
  local p90 = perfectworld.structures.rotate_point({x = 2, y = 0, z = 4}, 90)
  local p180 = perfectworld.structures.rotate_point({x = 2, y = 0, z = 4}, 180)
  local p270 = perfectworld.structures.rotate_point({x = 2, y = 0, z = 4}, 270)
  ctx.assert.equal(p0.x, 2, "rotation 0 x")
  ctx.assert.equal(p0.z, 4, "rotation 0 z")
  ctx.assert.equal(p90.x, -4, "rotation 90 x")
  ctx.assert.equal(p90.z, 2, "rotation 90 z")
  ctx.assert.equal(p180.x, -2, "rotation 180 x")
  ctx.assert.equal(p180.z, -4, "rotation 180 z")
  ctx.assert.equal(p270.x, 4, "rotation 270 x")
  ctx.assert.equal(p270.z, -2, "rotation 270 z")

  local c = perfectworld.structures.rotate_connector({type = "road", side = "south", offset = 1}, 90)
  ctx.assert.equal(c.side, "west", "south connector rotated 90 degrees must face west")

  local cpos = perfectworld.structures.rotate_connector({
    type = "road",
    side = "south",
    offset = 1,
    offset_pos = {x = 0, y = 0, z = 7},
  }, 180)
  ctx.assert.equal(cpos.side, "north", "south connector rotated 180 degrees must face north")
  ctx.assert.equal(cpos.offset_pos.z, -7, "connector offset_pos must rotate with connector")
end)

T.register_test("perfectworld", "farmstead_footprint_rotates_dimensions", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  local pos = {x = 100, y = 10, z = 200}
  local min0, max0 = perfectworld.structures.get_footprint(def, pos, 0)
  ctx.assert.equal(max0.x - min0.x + 1, 15, "rotation 0 footprint width")
  ctx.assert.equal(max0.z - min0.z + 1, 14, "rotation 0 footprint depth")

  local min90, max90 = perfectworld.structures.get_footprint(def, pos, 90)
  ctx.assert.equal(max90.x - min90.x + 1, 14, "rotation 90 footprint width")
  ctx.assert.equal(max90.z - min90.z + 1, 15, "rotation 90 footprint depth")
end)

T.register_test("perfectworld", "compat_materials_resolve_required_and_optional_fallbacks", function(ctx)
  local wall = perfectworld.compat.get_material("wall")
  ctx.assert.not_nil(wall, "wall material must resolve")
  ctx.assert.is_true(minetest.registered_nodes[wall] ~= nil, "wall material must be registered")

  local fallback = perfectworld.compat.get_material("missing_optional_for_test", {required = false, fallback = "air"})
  ctx.assert.equal(fallback, "air", "optional material should use fallback")

  local ok, err = pcall(function()
    perfectworld.compat.get_material("missing_required_for_test", {required = true})
  end)
  ctx.assert.is_false(ok, "missing required material must fail before placement")
  ctx.assert.contains(tostring(err), "missing required material", "required material error")
end)

T.register_test("perfectworld", "compat_furniture_fallbacks_are_semantic", function(ctx)
	local table_material = perfectworld.compat.get_material("table", {required = false, fallback = "air"})
	ctx.assert.is_true(table_material == "air" or table_material:find("mcl_stairs:slab_", 1, true), "table must use mcl_stairs:slab_* or be skipped")
	ctx.assert.is_false(table_material:find("wool", 1, true), "table fallback must not use wool")
	ctx.assert.is_false(table_material:find("mcl_core:wood", 1, true), "table fallback must not use a full wood block")
	ctx.assert.is_true(minetest.registered_nodes[table_material] ~= nil or table_material == "air",
		"table material must be a registered node or air, got: " .. tostring(table_material))

	local bed_material = perfectworld.compat.get_material("bed", {required = false, fallback = "air"})
	ctx.assert.is_true(bed_material == "mcl_beds:bed" or bed_material == "air", "bed must use bed node or be skipped")
	ctx.assert.is_false(bed_material == "mcl_core:wood", "bed fallback must not use a full block")

	-- resolve() must never return an arbitrary non-node string
	local resolved_table = perfectworld.compat.resolve("table")
	ctx.assert.is_true(resolved_table == "air" or resolved_table == "ignore" or minetest.registered_nodes[resolved_table] ~= nil,
		"resolve('table') must return a registered node or air, got: " .. tostring(resolved_table))
	ctx.assert.is_false(resolved_table:find("wool", 1, true), "resolve('table') must not return wool")

	-- resolve for unknown key must return air, not the key itself
	local resolved_unknown = perfectworld.compat.resolve("nonexistent_key_xyz")
	ctx.assert.equal(resolved_unknown, "air", "resolve for unknown key must return air")
end)

T.register_test("perfectworld", "terrain_analysis_uses_building_footprint_not_full_structure", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  local origin = {x = -1120, y = 30, z = -1120}
  if minetest.load_area then
    pcall(minetest.load_area, {x = origin.x - 18, y = origin.y - 4, z = origin.z - 18}, {x = origin.x + 18, y = origin.y + 16, z = origin.z + 18})
  end
  for dx = -18, 18 do
    for dz = -18, 18 do
      local h = origin.y
      if dx < -4 or dx > 4 or dz < -4 or dz > 4 then
        h = origin.y - 3
      end
      minetest.set_node({x = origin.x + dx, y = h, z = origin.z + dz}, {name = perfectworld.compat.get_material("ground")})
      for y = h + 1, h + 8 do
        minetest.set_node({x = origin.x + dx, y = y, z = origin.z + dz}, {name = "air"})
      end
    end
  end
  local ok, result = perfectworld.structures.analyze_terrain(def, origin, 0)
  ctx.assert.is_true(ok, "building footprint should be flat enough: " .. tostring(result and result.reason or result))
end)

T.register_test("perfectworld", "terrain_preparation_limits_modified_area", function(ctx)
	local def = perfectworld.structures.get("pw_farmstead_v1")
	local origin = {x = -1150, y = 40, z = -1150}
	if minetest.load_area then
		pcall(minetest.load_area, {x = origin.x - 18, y = origin.y - 4, z = origin.z - 18}, {x = origin.x + 18, y = origin.y + 16, z = origin.z + 18})
	end
	for dx = -18, 18 do
		for dz = -18, 18 do
			local h = origin.y
			minetest.set_node({x = origin.x + dx, y = h, z = origin.z + dz}, {name = perfectworld.compat.get_material("ground")})
			for y = h + 1, h + 8 do
				minetest.set_node({x = origin.x + dx, y = y, z = origin.z + dz}, {name = "air"})
			end
		end
	end
	local ok, analysis = perfectworld.structures.analyze_terrain(def, origin, 0)
	ctx.assert.is_true(ok, "terrain analysis must succeed: " .. tostring(analysis and analysis.reason or analysis))

	local margin = def.terrain.modification_margin or 1
	local building_minp, building_maxp = perfectworld.structures.get_building_footprint(def, origin, 0)
	local modified_minp = {x = building_minp.x - margin, z = building_minp.z - margin}
	local modified_maxp = {x = building_maxp.x + margin, z = building_maxp.z + margin}

	-- save a reference node well outside the modified area
	local outside_pos = {x = modified_maxp.x + 3, y = origin.y, z = modified_maxp.z + 3}
	local outside_node_before = minetest.get_node(outside_pos).name

	local prep_ok, prep = perfectworld.structures.prepare_terrain(def, origin, 0, analysis)
	ctx.assert.is_true(prep_ok, "terrain preparation must succeed: " .. tostring(prep and prep.reason or prep))
	ctx.assert.equal(minetest.get_node(outside_pos).name, outside_node_before, "terrain preparation must not modify nodes outside building footprint + margin")

	-- verify no deep quarry: area outside modified zone must be untouched
	local quarry_check_pos = {x = modified_maxp.x + 2, y = origin.y - 2, z = modified_maxp.z + 2}
	ctx.assert.equal(minetest.get_node(quarry_check_pos).name, perfectworld.compat.get_material("ground"), "no quarry hole outside modified area")

	-- verify smooth edges: the transition zone (margin area) should not have vertical cliffs
	local edge_pos_inner = {x = building_maxp.x + 1, y = origin.y + 2, z = building_maxp.z + 1}
	local edge_pos_outer = {x = building_maxp.x + 3, y = origin.y + 2, z = building_maxp.z + 3}
	local inner_node = minetest.get_node(edge_pos_inner).name
	local outer_node = minetest.get_node(edge_pos_outer).name
	ctx.assert.is_true(inner_node == "air" or inner_node == perfectworld.compat.get_material("foundation"), "inner margin should be cleared or founded")
	ctx.assert.equal(outer_node, perfectworld.compat.get_material("ground"), "outside margin must remain original ground")
end)

T.register_test("perfectworld", "terrain_analysis_rejects_steep_slope", function(ctx)
	local def = perfectworld.structures.get("pw_farmstead_v1")
	local origin = {x = -1050, y = 20, z = -1050}
	if minetest.load_area then
		pcall(minetest.load_area, {x = origin.x - 16, y = origin.y - 4, z = origin.z - 16}, {x = origin.x + 16, y = origin.y + 16, z = origin.z + 16})
	end
	for dx = -10, 10 do
		for dz = -10, 10 do
			local h = origin.y + math.floor((dx + 10) / 2)
			minetest.set_node({x = origin.x + dx, y = h, z = origin.z + dz}, {name = perfectworld.compat.get_material("ground")})
			for y = h + 1, h + 8 do
				minetest.set_node({x = origin.x + dx, y = y, z = origin.z + dz}, {name = "air"})
			end
		end
	end
	local ok, result = perfectworld.structures.analyze_terrain(def, origin, 0)
	ctx.assert.is_false(ok, "steep terrain must be rejected")
	ctx.assert.contains(result.reason, "slope", "steep terrain reason")
end)

T.register_test("perfectworld", "terrain_analysis_rejects_excessive_cut", function(ctx)
	local origin = {x = -1250, y = 30, z = -1250}
	local slope = 0 -- flat but with a deep hole
	if minetest.load_area then
		pcall(minetest.load_area, {x = origin.x - 16, y = origin.y - 10, z = origin.z - 16}, {x = origin.x + 16, y = origin.y + 16, z = origin.z + 16})
	end
	-- create a flat area with a deep pit in the middle (exceeding max_cut_depth=3)
	for dx = -10, 10 do
		for dz = -10, 10 do
			local h = origin.y
			-- dig a hole of depth 6 in the center (max_cut is 3)
			if math.abs(dx) <= 2 and math.abs(dz) <= 2 then
				h = origin.y - 6
			end
			minetest.set_node({x = origin.x + dx, y = h, z = origin.z + dz}, {name = perfectworld.compat.get_material("ground")})
			for y = h + 1, h + 12 do
				minetest.set_node({x = origin.x + dx, y = y, z = origin.z + dz}, {name = "air"})
			end
		end
	end
	local ok, err = perfectworld.structures.register("pw_test_excessive_cut", {
		version = 1,
		size = {x = 5, y = 4, z = 5},
		origin = {x = 2, y = 0, z = 2},
		categories = {"test"},
		weight = 1,
		allowed_settlement_types = {"farm"},
		rotations = {0},
		terrain = {
			max_slope = 8,
			foundation_depth = 2,
			clearance_height = 4,
			max_cut_depth = 3,
			max_fill_height = 3,
			modification_margin = 1,
			building_footprint = {min_x = -1, max_x = 1, min_z = -1, max_z = 1},
		},
		connectors = {},
		placement = {
			type = "lua",
			generator = function(ctx) return true end,
		},
	})
	ctx.assert.is_true(ok, "excessive cut test structure must register: " .. tostring(err))

	local def = perfectworld.structures.get("pw_test_excessive_cut")
	local ok2, result = perfectworld.structures.analyze_terrain(def, origin, 0)
	ctx.assert.is_false(ok2, "terrain with excessive cut must be rejected")
	ctx.assert.contains(result.reason, "excessive_cut", "excessive cut reason")
end)

T.register_test("perfectworld", "farmstead_materializes_once_and_records_state", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  local pos = {x = -1010, y = 12, z = -1010}
  local structure_id = "structure_v1_test_farmstead_1"
  perfectworld.planner._test_clear_structure(structure_id)
  fill_flat_area(pos, 16, pos.y - 1, 256)

  local ok, result = perfectworld.structures.place("pw_farmstead_v1", {
    structure_id = structure_id,
    pos = pos,
    rotation = 90,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test",
  })
  ctx.assert.is_true(ok, "farmstead placement must succeed: " .. tostring(result and result.reason or result))
  perfectworld.planner.record_structure({
    structure_id = structure_id,
    structure_name = "pw_farmstead_v1",
    definition_version = def.version,
    status = "materialized",
    position = result.position,
    rotation = 90,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test",
  })

  local record = perfectworld.planner.get_structure(structure_id)
  ctx.assert.not_nil(record, "materialization record must be stored")
  ctx.assert.equal(record.structure_name, "pw_farmstead_v1", "record structure name")
  ctx.assert.equal(record.rotation, 90, "record rotation")
  ctx.assert.equal(
    minetest.get_node({x = result.position.x, y = result.position.y - 1, z = result.position.z}).name,
    perfectworld.compat.get_material("foundation"),
    "foundation must be filled below prepared position"
  )
  local table_pos = {x = result.position.x + 1, y = result.position.y + 1, z = result.position.z - 1}
  local table_name = minetest.get_node(table_pos).name
  ctx.assert.is_false(table_name:find("wool", 1, true), "farmstead table must not be wool")
  ctx.assert.is_true(table_name == "air" or table_name:find("mcl_stairs:", 1, true), "farmstead table must use stair/slab or be skipped")

  local second_ok, second_result = perfectworld.structures.place("pw_farmstead_v1", {
    structure_id = structure_id,
    pos = pos,
    rotation = 90,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test",
  })
  ctx.assert.is_false(second_ok, "second placement must be rejected by idempotency")
  ctx.assert.contains(second_result.reason, "already_materialized", "idempotency reason")

  perfectworld.planner._test_clear_structure(structure_id)
end)

T.register_test("perfectworld", "required_material_preflight_fails_before_terrain_changes", function(ctx)
  local pos = {x = -1010, y = 12, z = -1010}
  fill_flat_area(pos, 16, pos.y - 1, 80)
  minetest.set_node(pos, {name = "mcl_core:stone"})
  local ground_before = minetest.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name
  local prepared_before = minetest.get_node(pos).name

  local ok, err = perfectworld.structures.register("pw_test_missing_required_preflight", {
    version = 1,
    size = {x = 3, y = 3, z = 3},
    origin = {x = 1, y = 0, z = 1},
    categories = {"test"},
    weight = 1,
    allowed_settlement_types = {"farm"},
    rotations = {0},
    terrain = {max_slope = 1, foundation_depth = 1, clearance_height = 3, max_cut_depth = 1, max_fill_height = 3},
    connectors = {},
    placement = {
      type = "lua",
      preflight = function()
        return false, "missing required functional object"
      end,
      generator = function(context)
        minetest.set_node(context.prepared_position, {name = perfectworld.compat.get_material("wall")})
      end,
    },
  })
  ctx.assert.is_true(ok, "preflight test structure must register: " .. tostring(err))

  local placed, result = perfectworld.structures.place("pw_test_missing_required_preflight", {
    structure_id = "structure_v1_test_missing_required_1",
    pos = pos,
    rotation = 0,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test",
  })
  ctx.assert.is_false(placed, "missing required material must reject placement")
  ctx.assert.contains(result.reason, "material_unavailable", "failure reason")
  ctx.assert.equal(minetest.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name, ground_before, "ground must remain unchanged before placement")
  ctx.assert.equal(minetest.get_node(pos).name, prepared_before, "prepared position must remain unchanged before placement")
end)

T.register_test("perfectworld", "structure_failure_rolls_back_partial_nodes", function(ctx)
  local pos = {x = -980, y = 12, z = -980}
  fill_flat_area(pos, 8, pos.y - 1, 80)

  local ok, err = perfectworld.structures.register("pw_test_failure_rollback", {
    version = 1,
    size = {x = 3, y = 3, z = 3},
    origin = {x = 1, y = 0, z = 1},
    categories = {"test"},
    weight = 1,
    allowed_settlement_types = {"farm"},
    rotations = {0},
    terrain = {max_slope = 1, foundation_depth = 1, clearance_height = 3},
    connectors = {},
    placement = {
      type = "lua",
      generator = function(context)
        minetest.set_node(context.prepared_position, {name = perfectworld.compat.get_material("wall")})
        error("intentional placement failure")
      end,
    },
  })
  ctx.assert.is_true(ok, "rollback test structure must register: " .. tostring(err))

  local placed, result = perfectworld.structures.place("pw_test_failure_rollback", {
    structure_id = "structure_v1_test_rollback_1",
    pos = pos,
    rotation = 0,
    region_id = "region_v1_test",
    settlement_id = "settlement_v1_test",
  })
  ctx.assert.is_false(placed, "failing generator must reject placement")
  ctx.assert.contains(result.reason, "placement_failed", "failure reason")
  ctx.assert.equal(minetest.get_node(pos).name, "air", "failed generator must not leave partial wall")
  ctx.assert.equal(
    minetest.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name,
    perfectworld.compat.get_material("ground"),
    "failed generator must restore prepared ground"
  )
end)

-- === New Structure Registry Tests ===

T.register_test("perfectworld", "new_structure_registry_validates_all", function(ctx)
  local list = perfectworld.structures.list()
  ctx.assert.contains(table.concat(list, ","), "pw_house_small_v1", "pw_house_small_v1 must be registered")
  ctx.assert.contains(table.concat(list, ","), "pw_house_small_v2", "pw_house_small_v2 must be registered")
  ctx.assert.contains(table.concat(list, ","), "pw_barn_v1", "pw_barn_v1 must be registered")
  ctx.assert.contains(table.concat(list, ","), "pw_well_v1", "pw_well_v1 must be registered")
  ctx.assert.contains(table.concat(list, ","), "pw_farmstead_v1", "pw_farmstead_v1 must be registered")
  ctx.assert.is_true(#list >= 5, "must have at least 5 registered structures, got " .. #list)
end)
