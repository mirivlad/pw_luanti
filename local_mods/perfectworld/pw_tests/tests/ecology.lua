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
