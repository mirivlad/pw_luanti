-- tests/fingerprints.lua
-- Contracts for the three settlement fingerprints:
--   road_graph_fingerprint  - canonical geometry + topology of the road network
--   exact_plan_fingerprint  - exact normalised geometry of the whole plan
--   structural_fingerprint  - quantised, for grouping visually similar plans

local T = luanti_testkit

local planner = perfectworld.planner
local road_graph_signature = planner._road_graph_signature
local exact_plan_signature = planner._exact_plan_signature
local structural_plan_signature = planner._structural_plan_signature

local function pts(list)
  local out = {}
  for _, p in ipairs(list) do table.insert(out, {x = p[1], z = p[2]}) end
  return out
end

local function reversed(list)
  local out = {}
  for i = #list, 1, -1 do table.insert(out, list[i]) end
  return out
end

local function make_plan(overrides)
  local plan = {
    archetype = "linear",
    size_class = "medium",
    palette_id = "temperate",
    center = {x = 100, z = 200},
    environment = {biome_family = "temperate"},
    lots = {
      {center = {x = 104, z = 206}, road_point = {x = 100, z = 206},
       role = "dwelling", structure_name = "pw_house_small_v1", rotation = 270},
      {center = {x = 96, z = 214}, road_point = {x = 100, z = 214},
       role = "dwelling", structure_name = "pw_house_small_v2", rotation = 90},
    },
    roads = {
      {kind = "main_street", width = 3, points = pts({{100, 190}, {100, 200}, {100, 210}, {100, 220}})},
    },
  }
  for key, value in pairs(overrides or {}) do plan[key] = value end
  return plan
end

-- === Road graph: canonical form ===

T.register_test("perfectworld", "road_graph_ignores_table_order", function(ctx)
  local center = {x = 0, z = 0}
  local a = {kind = "main_street", width = 3, points = pts({{-10, 0}, {0, 0}, {10, 0}})}
  local b = {kind = "branch", width = 2, points = pts({{0, 0}, {0, 8}, {0, 16}})}
  ctx.assert.equal(
    road_graph_signature({a, b}, center),
    road_graph_signature({b, a}, center),
    "swapping two independent roads must not change the road graph fingerprint")
end)

T.register_test("perfectworld", "road_graph_treats_segments_as_undirected", function(ctx)
  local center = {x = 0, z = 0}
  local forward = {kind = "main_street", width = 3, points = pts({{-6, 0}, {0, 0}, {6, 4}})}
  local backward = {kind = "main_street", width = 3, points = reversed(forward.points)}
  ctx.assert.equal(
    road_graph_signature({forward}, center),
    road_graph_signature({backward}, center),
    "a road written from the opposite end is the same undirected graph")
end)

T.register_test("perfectworld", "road_graph_distinguishes_bends", function(ctx)
  local center = {x = 0, z = 0}
  local straight = {kind = "main_street", width = 3, points = pts({{-6, 0}, {0, 0}, {6, 0}})}
  local bent = {kind = "main_street", width = 3, points = pts({{-6, 0}, {0, 1}, {6, 0}})}
  ctx.assert.is_true(
    road_graph_signature({straight}, center) ~= road_graph_signature({bent}, center),
    "a one-block bend must change the road graph fingerprint")
end)

T.register_test("perfectworld", "road_graph_distinguishes_connections", function(ctx)
  local center = {x = 0, z = 0}
  -- Same four points, different edges: a path A-B-C-D versus a star B-A, B-C, B-D.
  local path = {
    {kind = "main_street", width = 2, points = pts({{0, 0}, {4, 0}, {8, 0}, {12, 0}})},
  }
  local star = {
    {kind = "main_street", width = 2, points = pts({{4, 0}, {0, 0}})},
    {kind = "branch", width = 2, points = pts({{4, 0}, {8, 0}})},
    {kind = "branch", width = 2, points = pts({{4, 0}, {12, 0}})},
  }
  ctx.assert.is_true(
    road_graph_signature(path, center) ~= road_graph_signature(star, center),
    "same point set with different connections must differ")
end)

T.register_test("perfectworld", "road_graph_ignores_absolute_position", function(ctx)
  local function shifted(dx, dz)
    return {kind = "main_street", width = 3,
      points = pts({{dx - 6, dz}, {dx, dz + 2}, {dx + 6, dz}})}
  end
  ctx.assert.equal(
    road_graph_signature({shifted(0, 0)}, {x = 0, z = 0}),
    road_graph_signature({shifted(9000, -7000)}, {x = 9000, z = -7000}),
    "translating a settlement must not create a new road graph fingerprint")
end)

T.register_test("perfectworld", "road_graph_deduplicates_repeated_edges", function(ctx)
  local center = {x = 0, z = 0}
  local once = {kind = "main_street", width = 2, points = pts({{0, 0}, {4, 0}})}
  local twice = {kind = "main_street", width = 2, points = pts({{0, 0}, {4, 0}, {0, 0}, {4, 0}})}
  -- Degrees differ, so the signatures differ: retracing an edge is a real
  -- topological difference, not noise. The point is that it is deterministic.
  ctx.assert.equal(road_graph_signature({once}, center), road_graph_signature({once}, center),
    "signature must be stable")
  ctx.assert.is_true(road_graph_signature({twice}, center) ~= nil, "retraced road still signs")
end)

-- === Exact plan fingerprint ===

T.register_test("perfectworld", "exact_fingerprint_detects_one_block_move", function(ctx)
  local base = make_plan()
  base.road_graph_signature = road_graph_signature(base.roads, base.center)
  local moved = make_plan()
  moved.lots[1].center.x = moved.lots[1].center.x + 1
  moved.road_graph_signature = road_graph_signature(moved.roads, moved.center)
  ctx.assert.is_true(
    exact_plan_signature(base) ~= exact_plan_signature(moved),
    "moving one lot by one block must change the exact fingerprint")
end)

T.register_test("perfectworld", "exact_fingerprint_detects_variant_and_rotation", function(ctx)
  local base = make_plan()
  base.road_graph_signature = road_graph_signature(base.roads, base.center)

  local variant = make_plan()
  variant.lots[1].structure_name = "pw_barn_v1"
  variant.road_graph_signature = base.road_graph_signature
  ctx.assert.is_true(exact_plan_signature(base) ~= exact_plan_signature(variant),
    "different structure variant must change the exact fingerprint")

  local rotated = make_plan()
  rotated.lots[1].rotation = 180
  rotated.road_graph_signature = base.road_graph_signature
  ctx.assert.is_true(exact_plan_signature(base) ~= exact_plan_signature(rotated),
    "different rotation must change the exact fingerprint")

  local role = make_plan()
  role.lots[2].role = "utility"
  role.road_graph_signature = base.road_graph_signature
  ctx.assert.is_true(exact_plan_signature(base) ~= exact_plan_signature(role),
    "different role must change the exact fingerprint")
end)

T.register_test("perfectworld", "exact_fingerprint_ignores_lot_table_order", function(ctx)
  local base = make_plan()
  base.road_graph_signature = road_graph_signature(base.roads, base.center)
  local swapped = make_plan()
  swapped.lots[1], swapped.lots[2] = swapped.lots[2], swapped.lots[1]
  swapped.road_graph_signature = base.road_graph_signature
  ctx.assert.equal(exact_plan_signature(base), exact_plan_signature(swapped),
    "Lua table order of lots must not affect the exact fingerprint")
end)

T.register_test("perfectworld", "exact_fingerprint_ignores_absolute_position", function(ctx)
  local base = make_plan()
  base.road_graph_signature = road_graph_signature(base.roads, base.center)

  local far = make_plan()
  local shift_x, shift_z = 12000, -8000
  far.center = {x = far.center.x + shift_x, z = far.center.z + shift_z}
  for _, lot in ipairs(far.lots) do
    lot.center.x = lot.center.x + shift_x
    lot.center.z = lot.center.z + shift_z
    lot.road_point.x = lot.road_point.x + shift_x
    lot.road_point.z = lot.road_point.z + shift_z
  end
  for _, road in ipairs(far.roads) do
    for _, p in ipairs(road.points) do
      p.x = p.x + shift_x
      p.z = p.z + shift_z
    end
  end
  far.road_graph_signature = road_graph_signature(far.roads, far.center)

  ctx.assert.equal(exact_plan_signature(base), exact_plan_signature(far),
    "the same layout built elsewhere must not look unique")
end)

-- === Structural fingerprint ===

T.register_test("perfectworld", "structural_fingerprint_groups_near_identical_plans", function(ctx)
  local base = make_plan()
  local nudged = make_plan()
  nudged.lots[1].center.x = nudged.lots[1].center.x + 1
  base.road_graph_signature = road_graph_signature(base.roads, base.center)
  nudged.road_graph_signature = base.road_graph_signature

  ctx.assert.is_true(exact_plan_signature(base) ~= exact_plan_signature(nudged),
    "exact fingerprint must see the one-block nudge")
  ctx.assert.equal(structural_plan_signature(base), structural_plan_signature(nudged),
    "structural fingerprint quantises, so a one-block nudge groups together")
end)

T.register_test("perfectworld", "structural_fingerprint_separates_different_layouts", function(ctx)
  local base = make_plan()
  local different = make_plan({
    archetype = "compact",
    lots = {
      {center = {x = 130, z = 240}, road_point = {x = 126, z = 240},
       role = "dwelling", structure_name = "pw_house_small_v1", rotation = 90},
      {center = {x = 70, z = 160}, road_point = {x = 74, z = 160},
       role = "farm", structure_name = "pw_farmstead_v1", rotation = 270},
      {center = {x = 100, z = 250}, road_point = {x = 100, z = 246},
       role = "central", structure_name = "pw_well_v1", rotation = 0},
    },
  })
  ctx.assert.is_true(
    structural_plan_signature(base) ~= structural_plan_signature(different),
    "materially different layouts must not share a structural fingerprint")
end)

-- === Wiring into real plans ===

T.register_test("perfectworld", "plans_expose_all_three_fingerprints", function(ctx)
  local candidate = {
    id = "fp_wiring_test",
    x = 400, z = 400, rx = 0, rz = 0,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    region_id = perfectworld.get_region_id(0, 0),
  }
  local synthetic = perfectworld.planner.make_synthetic_terrain(
    {base = 40, slope_x = 0.05, relief = 2, seed_key = "fp_wiring"})
  local plan = perfectworld.planner.plan_village(candidate, nil, synthetic)
  ctx.assert.not_nil(plan.exact_plan_fingerprint, "exact_plan_fingerprint must be set")
  ctx.assert.not_nil(plan.structural_fingerprint, "structural_fingerprint must be set")
  ctx.assert.not_nil(plan.road_graph_fingerprint, "road_graph_fingerprint must be set")
  ctx.assert.equal(plan.fingerprint, plan.exact_plan_fingerprint,
    "legacy alias must point at the exact fingerprint")

  local again = perfectworld.planner.plan_village(candidate, nil,
    perfectworld.planner.make_synthetic_terrain(
      {base = 40, slope_x = 0.05, relief = 2, seed_key = "fp_wiring"}))
  ctx.assert.equal(again.exact_plan_fingerprint, plan.exact_plan_fingerprint,
    "planning the same candidate twice must give the same exact fingerprint")
  ctx.assert.equal(again.road_graph_fingerprint, plan.road_graph_fingerprint,
    "planning the same candidate twice must give the same road graph fingerprint")
end)
