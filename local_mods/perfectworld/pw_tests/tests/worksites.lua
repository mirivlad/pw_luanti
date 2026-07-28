-- tests/worksites.lua
-- Transactional, bounded village worksite contracts.

local T = luanti_testkit

local function api(ctx)
  local worksites = perfectworld.planner.worksites
  ctx.assert.not_nil(worksites, "planner must expose transactional worksites")
  return worksites
end

local function prepare_flat(center, radius, surface_y)
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = center.x - radius, y = surface_y - 8, z = center.z - radius},
      {x = center.x + radius, y = surface_y + 8, z = center.z + radius})
  end
  local ground, air = {}, {}
  for dx = -radius, radius do
    for dz = -radius, radius do
      for y = surface_y - 4, surface_y do
        ground[#ground + 1] = {
          x = center.x + dx, y = y, z = center.z + dz,
        }
      end
      for y = surface_y + 1, surface_y + 7 do
        air[#air + 1] = {x = center.x + dx, y = y, z = center.z + dz}
      end
    end
  end
  minetest.bulk_set_node(ground,
    {name = perfectworld.compat.get_material("ground")})
  minetest.bulk_set_node(air, {name = "air"})
end

T.register_test("perfectworld", "worksite_transaction_rolls_back_node_and_param2", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.transaction then return end
  local pos = {x = -2450, y = 24, z = -2450}
  if minetest.load_area then pcall(minetest.load_area, pos, pos) end
  local original = {
    name = perfectworld.compat.get_material("wall"),
    param2 = 2,
  }
  minetest.set_node(pos, original)
  original = minetest.get_node(pos)

  local ok = worksites.transaction({min = pos, max = pos}, function()
    minetest.set_node(pos, {
      name = perfectworld.compat.get_material("stone"),
      param2 = 5,
    })
    error("injected worksite failure")
  end)

  ctx.assert.is_false(ok, "mutator error must fail the transaction")
  local restored = minetest.get_node(pos)
  ctx.assert.equal(restored.name, original.name, "rollback must restore node name")
  ctx.assert.equal(restored.param2, original.param2, "rollback must restore param2")
end)

T.register_test("perfectworld", "worksite_transaction_checks_protection_before_mutating", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.transaction then return end
  local pos = {x = -2460, y = 24, z = -2460}
  if minetest.load_area then pcall(minetest.load_area, pos, pos) end
  minetest.set_node(pos, {name = perfectworld.compat.get_material("ground")})
  local before = minetest.get_node(pos)
  local called = false
  local original_is_protected = minetest.is_protected
  minetest.is_protected = function(candidate)
    return candidate.x == pos.x and candidate.y == pos.y and candidate.z == pos.z
  end
  local ok, result = worksites.transaction({min = pos, max = pos}, function()
    called = true
    minetest.set_node(pos, {name = perfectworld.compat.get_material("stone")})
  end)
  minetest.is_protected = original_is_protected

  ctx.assert.is_false(ok, "protected bounds must reject the transaction")
  ctx.assert.is_false(called, "mutator must not run after protection rejection")
  ctx.assert.equal(result.reason, "worksite_protected", "protection reason")
  ctx.assert.equal(minetest.get_node(pos).name, before.name,
    "protected node must remain unchanged")
end)

T.register_test("perfectworld", "field_tries_bounded_sites_away_from_roads_and_buildings", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.place then return end
  if worksites._test_forget then
    worksites._test_forget("test_field_collision")
  end
  local center = {x = -2600, y = 20, z = -2600}
  prepare_flat(center, 35, center.y)
  local candidates = {
    {x = center.x - 20, y = center.y, z = center.z},
    {x = center.x, y = center.y, z = center.z},
    {x = center.x + 20, y = center.y, z = center.z},
  }
  local road_cells = {}
  for x = candidates[1].x - 5, candidates[1].x + 5 do
    for z = candidates[1].z - 4, candidates[1].z + 4 do
      road_cells[x .. ":" .. z] = true
    end
  end
  local structures = {{
    min = {x = candidates[2].x - 5, z = candidates[2].z - 4},
    max = {x = candidates[2].x + 5, z = candidates[2].z + 4},
  }}

  local ok, record = worksites.place("field", {
    worksite_id = "test_field_collision",
    required = true,
    candidate_anchors = candidates,
    road_cells = road_cells,
    structure_footprints = structures,
    surface_y = function() return center.y end,
    palette = perfectworld.compat.get_family_palette("temperate"),
    seed_key = "test_field_collision",
  })
  ctx.assert.is_true(ok, "a third bounded field site must fit: "
    .. tostring(record and record.reason))
  if not ok then return end
  ctx.assert.equal(record.anchor.x, candidates[3].x,
    "field must skip the road and building candidates")
  for _, cell in ipairs(record.footprint_cells or {}) do
    ctx.assert.is_false(road_cells[cell.x .. ":" .. cell.z] == true,
      "field footprint must avoid exact road cells")
    local box = structures[1]
    local overlaps = cell.x >= box.min.x and cell.x <= box.max.x
      and cell.z >= box.min.z and cell.z <= box.max.z
    ctx.assert.is_false(overlaps, "field footprint must avoid buildings")
  end

  local repeat_ok, repeat_record = worksites.place("field", {
    worksite_id = "test_field_collision",
    required = true,
    candidate_anchors = candidates,
    road_cells = road_cells,
    structure_footprints = structures,
    surface_y = function() return center.y end,
    palette = perfectworld.compat.get_family_palette("temperate"),
    seed_key = "test_field_collision",
  })
  ctx.assert.is_true(repeat_ok, "repeat placement must return the existing record")
  ctx.assert.equal(minetest.write_json(repeat_record), minetest.write_json(record),
    "repeat placement must not duplicate or mutate the worksite")
end)

T.register_test("perfectworld", "dock_and_minehead_require_physical_resource_anchors", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.place then return end
  local dock_ok, dock_error = worksites.place("dock", {
    worksite_id = "test_dock_without_shore",
    required = true,
  })
  ctx.assert.is_false(dock_ok, "dock without shore evidence must fail")
  ctx.assert.equal(dock_error.reason, "missing_shore_anchor",
    "dock must explain missing shore evidence")

  local mine_ok, mine_error = worksites.place("minehead", {
    worksite_id = "test_mine_without_stone",
    required = true,
  })
  ctx.assert.is_false(mine_ok, "minehead without stone evidence must fail")
  ctx.assert.equal(mine_error.reason, "missing_stone_anchor",
    "minehead must explain missing stone evidence")
end)

T.register_test("perfectworld", "dock_accepts_a_measured_frozen_shore", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.place then return end
  local center = {x = -2900, y = 20, z = -2900}
  local worksite_id = "test_frozen_shore_dock"
  if worksites._test_forget then worksites._test_forget(worksite_id) end
  prepare_flat(center, 18, center.y)
  local shore = {x = center.x + 6, y = center.y, z = center.z}
  minetest.set_node(shore, {name = "mcl_core:ice"})

  local ok, result = worksites.place("dock", {
    worksite_id = worksite_id,
    required = true,
    shore_land_anchor = center,
    shore_anchor = shore,
    palette = perfectworld.compat.get_family_palette("cold"),
    seed_key = worksite_id,
  })

  ctx.assert.is_true(ok, "a frozen water surface is valid shore evidence: "
    .. tostring(result and result.reason))
end)

T.register_test("perfectworld", "ecological_worksites_place_physical_decor", function(ctx)
  local worksites = api(ctx)
  if not worksites or not worksites.place then return end
  local palette = perfectworld.compat.get_family_palette("temperate")
  local fixtures = {
    {
      kind = "forestry_yard",
      id = "test_physical_forestry_yard",
      center = {x = -2750, y = 20, z = -2750},
    },
    {
      kind = "dock",
      id = "test_physical_dock",
      center = {x = -2800, y = 20, z = -2800},
    },
    {
      kind = "minehead",
      id = "test_physical_minehead",
      center = {x = -2850, y = 20, z = -2850},
    },
  }

  for _, fixture in ipairs(fixtures) do
    if worksites._test_forget then worksites._test_forget(fixture.id) end
    prepare_flat(fixture.center, 18, fixture.center.y)
    local context = {
      worksite_id = fixture.id,
      required = true,
      anchor = fixture.center,
      candidate_anchors = {fixture.center},
      road_cells = {},
      structure_footprints = {},
      surface_y = function() return fixture.center.y end,
      palette = palette,
      seed_key = fixture.id,
    }
    if fixture.kind == "dock" then
      context.shore_land_anchor = fixture.center
      context.shore_anchor = {
        x = fixture.center.x + 6,
        y = fixture.center.y,
        z = fixture.center.z,
      }
      minetest.set_node(context.shore_anchor,
        {name = perfectworld.compat.get_material("water")})
    elseif fixture.kind == "minehead" then
      context.stone_anchor = fixture.center
      context.approach_anchor = {
        x = fixture.center.x - 6,
        y = fixture.center.y,
        z = fixture.center.z,
      }
      minetest.set_node(context.stone_anchor,
        {name = perfectworld.compat.get_material("stone")})
    end

    local ok, record = worksites.place(fixture.kind, context)
    ctx.assert.is_true(ok, fixture.kind .. " must place: "
      .. tostring(record and record.reason))
    if ok then
      ctx.assert.equal(record.status, "materialized",
        fixture.kind .. " record status")
      ctx.assert.is_true((record.node_count or 0) > 0,
        fixture.kind .. " must place physical nodes")
      local found = 0
      for _, expected in ipairs(record.expected_nodes or {}) do
        local node = minetest.get_node(expected.position)
        if node.name == expected.node_name then found = found + 1 end
      end
      ctx.assert.equal(found, record.node_count,
        fixture.kind .. " expected nodes must exist in the world")
    end
  end
end)
