-- pw_bot_bridge/tests/unit_semantics.lua
--
-- The semantic registry and normalised node properties.
--
-- These tests care about one thing above all: that the bridge reads real node
-- definitions instead of guessing from names, and that walkable, collision
-- geometry, selection geometry and visual transparency stay four separate
-- facts.

local B = pw_bot_bridge
local semantics = B.impl.semantics

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function has(list, wanted)
  for _, item in ipairs(list or {}) do if item == wanted then return true end end
  return false
end

--- First registered node carrying a group, so a test can name a real node
--- without hard-coding a Mineclonia item string.
local function node_in_group(group)
  local names = {}
  for name, def in pairs(minetest.registered_nodes) do
    if (def.groups and (def.groups[group] or 0) > 0) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names[1]
end

test("semantics_air_is_passable_and_transparent", function(ctx)
  local air = B.describe_node("air", 0)
  ctx.assert.equal(air.name, "air", "name")
  ctx.assert.is_false(air.properties.walkable, "air is not walkable")
  ctx.assert.is_false(air.properties.blocks_sight, "air does not block sight")
  ctx.assert.is_true(has(air.semantics, "passable"), "air is tagged passable")
end)

test("semantics_ignore_and_unknown_nodes_are_distinguished", function(ctx)
  local ignored = B.get_node_semantics("ignore")
  ctx.assert.is_true(has(ignored, "not_loaded"), "ignore means the map is not loaded")

  local unknown = B.describe_node("pw_bot_bridge:no_such_node_exists", 0)
  ctx.assert.is_false(unknown.registered, "the node is not registered")
  ctx.assert.is_true(has(unknown.semantics, "unknown_node"), "tagged unknown_node")
  ctx.assert.is_true(has(unknown.semantics, "navigation_obstacle"),
    "an unknown node is treated as an obstacle, not as free space")
  ctx.assert.is_true(unknown.properties.blocks_sight,
    "an unknown node blocks sight rather than being seen through")
end)

test("semantics_separates_walkable_collision_selection_and_transparency", function(ctx)
  local stone = perfectworld.compat.get_material("stone", {required = false})
  if not minetest.registered_nodes[stone] then
    return ctx.skip("no stone node registered")
  end
  local described = B.describe_node(stone, 0)
  ctx.assert.is_true(described.properties.walkable, "stone is walkable")
  ctx.assert.is_true(described.properties.blocks_sight, "stone blocks sight")
  ctx.assert.is_true(#described.collision_boxes >= 1, "collision geometry is reported")
  ctx.assert.is_true(#described.selection_boxes >= 1, "selection geometry is reported")
  ctx.assert.equal(described.collision_box_type, "regular", "a full cube is a regular box")

  local slab = node_in_group("slab")
  if slab then
    local slab_desc = B.describe_node(slab, 0)
    ctx.assert.is_true(slab_desc.properties.walkable, "a slab is walkable")
    ctx.assert.is_true(has(slab_desc.semantics, "slab"), "a slab is tagged slab")
    ctx.assert.is_true(slab_desc.collision_box_type ~= "regular",
      "a slab does not fill its voxel: " .. slab_desc.collision_box_type)
  end
end)

test("semantics_glass_is_walkable_but_does_not_block_sight", function(ctx)
  local glass = perfectworld.compat.get_material("window", {required = false})
  if not glass or not minetest.registered_nodes[glass]
    or minetest.registered_nodes[glass].paramtype ~= "light" then
    glass = node_in_group("glass")
  end
  if not glass then return ctx.skip("no glass node registered") end
  local described = B.describe_node(glass, 0)
  ctx.assert.is_true(described.properties.walkable, "glass is solid to a body")
  ctx.assert.is_false(described.properties.blocks_sight, "glass is not solid to an eye")
  ctx.assert.is_true(described.properties.attenuates_sight,
    "glass is flagged as dimming the view")
end)

test("semantics_reads_door_state_from_the_game_convention_not_the_name", function(ctx)
  local door = node_in_group("door_bottom")
  if not door then return ctx.skip("no door nodes registered") end
  local described = B.describe_node(door, 0)
  ctx.assert.is_true(has(described.semantics, "door"), "tagged door")
  ctx.assert.is_true(has(described.semantics, "interactable"), "tagged interactable")
  ctx.assert.is_true(has(described.semantics, "structure_entrance"), "tagged as an entrance")
  ctx.assert.is_true(has(described.semantics, "door_open") or has(described.semantics, "door_closed"),
    "a door reports a state")

  -- Mineclonia stores the open flag in node metadata and offers mcl_doors.is_open;
  -- the _1 / _2 name suffix is the mirroring variant, so a substring check would
  -- be wrong about half the time. Both variants must describe alike.
  local mirrored = door:gsub("_b_1$", "_b_2")
  if mirrored ~= door and minetest.registered_nodes[mirrored] then
    local other = B.describe_node(mirrored, 0)
    ctx.assert.equal(
      has(other.semantics, "door_open"), has(described.semantics, "door_open"),
      "the _1 and _2 variants are not open and closed")
  end
end)

test("semantics_knows_fence_gate_state_from_walkability", function(ctx)
  local gate = node_in_group("fence_gate")
  if not gate then return ctx.skip("no fence gate registered") end
  local closed = B.describe_node(gate, 0)
  ctx.assert.is_true(has(closed.semantics, "gate"), "tagged gate")
  local open_name = gate .. "_open"
  if minetest.registered_nodes[open_name] then
    local opened = B.describe_node(open_name, 0)
    ctx.assert.is_true(has(opened.semantics, "gate_open"), "the open gate is tagged open")
    ctx.assert.is_true(has(closed.semantics, "gate_closed"), "the closed gate is tagged closed")
    ctx.assert.is_false(opened.properties.walkable, "an open gate is walkable through")
  end
end)

test("semantics_tags_ladders_stairs_and_liquids", function(ctx)
  local climbable = {}
  for name, def in pairs(minetest.registered_nodes) do
    if def.climbable then climbable[#climbable + 1] = name end
  end
  table.sort(climbable)
  local ladder = climbable[1]
  if ladder then
    local described = B.describe_node(ladder, 0)
    ctx.assert.is_true(described.properties.climbable, "a climbable node reports climbable")
    ctx.assert.is_true(has(described.semantics, "climbable"), "tagged climbable")
  end

  local stair = node_in_group("stair")
  if stair then
    ctx.assert.is_true(has(B.get_node_semantics(stair), "stair"), "stairs are tagged")
  end

  local water = perfectworld.compat.get_material("water", {required = false})
  if minetest.registered_nodes[water] then
    local described = B.describe_node(water, 0)
    ctx.assert.equal(described.properties.liquid_type, "source", "water source")
    ctx.assert.is_true(has(described.semantics, "liquid"), "tagged liquid")
    ctx.assert.is_true(has(described.semantics, "water"), "tagged water")
  end
end)

test("semantics_recognises_perfectworld_road_material", function(ctx)
  local road = perfectworld.compat.get_material("road", {required = false})
  if not road or road == "air" then return ctx.skip("no road material resolved") end
  local tags = B.get_node_semantics(road)
  ctx.assert.is_true(has(tags, "road_surface"),
    road .. " is registered as a PerfectWorld road surface, got: " .. table.concat(tags, ","))
  ctx.assert.is_true(has(tags, "navigation_support"), "a road can be walked on")
end)

test("semantics_registry_is_central_and_extensible", function(ctx)
  local name = "pw_bot_bridge:test_marker"
  B.register_node_semantics(name, {"dock", "structure_exterior"})
  local tags = B.get_node_semantics(name)
  ctx.assert.is_true(has(tags, "dock"), "a custom tag is returned")
  ctx.assert.is_true(has(tags, "structure_exterior"), "all custom tags are returned")
  ctx.assert.is_true(has(tags, "unknown_node"),
    "derived tags are merged with registered ones")

  local sorted = true
  for i = 2, #tags do
    if tags[i - 1] > tags[i] then sorted = false end
  end
  ctx.assert.is_true(sorted, "tags come back sorted")

  B.register_entity_semantics("pw_bot_bridge:test_entity", {"vehicle", "boat"})
  local entity_tags = semantics.tags_for_entity("pw_bot_bridge:test_entity", false, nil)
  ctx.assert.is_true(has(entity_tags, "boat"), "entity tags are registered centrally")
end)

test("semantics_builtin_adapters_cover_the_mineclonia_conventions", function(ctx)
  local groups = semantics.registered_group_names()
  for _, group in ipairs({"door_bottom", "door_top", "fence", "fence_gate",
    "slab", "stair", "trapdoor", "water"}) do
    ctx.assert.is_true(has(groups, group), "an adapter is registered for group " .. group)
  end
  local entity_names = semantics.registered_entity_names()
  ctx.assert.is_true(has(entity_names, "mcl_boats:boat"), "boats are known to the registry")
end)

test("semantics_feature_names_are_a_closed_set", function(ctx)
  ctx.assert.is_true(semantics.is_known_feature("door"), "door is a feature")
  ctx.assert.is_true(semantics.is_known_feature("road_surface"), "road_surface is a feature")
  ctx.assert.is_false(semantics.is_known_feature("teapot"), "nonsense is not a feature")
  local sorted = true
  for i = 2, #semantics.FEATURES do
    if semantics.FEATURES[i - 1] > semantics.FEATURES[i] then sorted = false end
  end
  ctx.assert.is_true(sorted, "the feature list is sorted")
end)
