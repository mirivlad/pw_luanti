perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.compat = perfectworld.compat or {}

local materials = {
  foundation = "mcl_core:cobble",
  wall = "mcl_core:wood",
  roof = "mcl_stairs:slab_oak",
  floor = "mcl_core:wood",
  road = "mcl_core:coarse_dirt",
  fence = "mcl_fences:fence",
  door = "mcl_doors:door_oak_b_1",
  door_top = "mcl_doors:door_oak_t_1",
  window = "mcl_core:glass",
  light = "mcl_torches:torch",
  bed = "mcl_beds:bed",
  table_oak = "mcl_stairs:slab_oak",
  table = "mcl_stairs:slab_oak",
  container = "mcl_chests:chest",
  ground = "mcl_core:dirt",
  garden_soil = "mcl_farming:soil",
  crop = "mcl_farming:carrot_4",
  dirt = "mcl_core:dirt",
  grass = "mcl_core:dirt_with_grass",
  cobble = "mcl_core:cobble",
  wood_planks = "mcl_core:wood",
  tree = "mcl_core:tree",
  stone = "mcl_core:stone",
  sandstone = "mcl_core:sandstone",
  desert_sand = "mcl_core:desert_sand",
  sand = "mcl_core:sand",
  gravel = "mcl_core:gravel",
  water = "mcl_core:water_source",
  air = "air",
  chest = "mcl_chests:chest",
  slab_wood = "mcl_stairs:slab_oak",
  fence_block = "mcl_fences:fence",
  torch = "mcl_torches:torch",
  lantern = "mcl_lanterns:lantern",
}

local fallbacks = {
  road = "mcl_core:dirt",
  fence = "air",
  door = "mcl_core:wood",
  door_top = "air",
  window = "air",
  light = "mcl_torches:torch",
  bed = "air",
  table = "air",
  table_oak = "air",
  container = "mcl_chests:chest",
  garden_soil = "mcl_core:dirt",
  crop = "air",
}

local function resolve_node_name(name)
  if not name or name == "" then return nil end
  if name == "air" or name == "ignore" then return name end
  if minetest.registered_nodes[name] then return name end
  return nil
end

function perfectworld.compat.resolve(name)
  return perfectworld.compat.get_material(name, {required = false})
end

function perfectworld.compat.get_material(name, opts)
  opts = opts or {}
  local node_name = materials[name]
  local fallback = opts.fallback or fallbacks[name]

  -- try primary material
  if resolve_node_name(node_name) then
    return node_name
  end

  -- try explicit or default fallback
  if resolve_node_name(fallback) then
    return fallback
  end

  -- optional: never return an arbitrary string as a node name
  if opts.required == false then
    return "air"
  end
  error("missing required material: " .. tostring(name))
end

--- Is this node a liquid?
function perfectworld.compat.is_liquid_node(node_name)
  if not node_name or node_name == "air" or node_name == "ignore" then return false end
  local def = minetest.registered_nodes[node_name]
  if def and def.liquidtype and def.liquidtype ~= "none" then return true end
  return node_name:find("water") ~= nil or node_name:find("lava") ~= nil
end

--- Can a settlement stand on this surface node?
--
-- Liquids are the obvious no. Ice is the subtle one: a frozen ocean is flat,
-- solid and walkable, so every geometric check passes and the planner will
-- cheerfully lay out a village on the sea.
function perfectworld.compat.is_unbuildable_surface(node_name)
  if not node_name or node_name == "ignore" then return true end
  if perfectworld.compat.is_liquid_node(node_name) then return true end
  local def = minetest.registered_nodes[node_name]
  local groups = (def and def.groups) or {}
  if groups.ice or groups.water or groups.lava then return true end
  return node_name:find("ice") ~= nil
end

--- Ground people would actually settle on.
--
-- Geometry alone is not enough: bare andesite at 2000 m is as flat and solid
-- as a meadow, and a village there looks absurd because nothing can grow.
-- Soil, sand and snow-covered soil are fine — snowy taiga and foothills are
-- legitimate places to live; naked stone, gravel and ice are not.
local livable_ground = {
  ["mcl_core:dirt"] = true,
  ["mcl_core:dirt_with_grass"] = true,
  ["mcl_core:dirt_with_grass_snow"] = true,
  ["mcl_core:coarse_dirt"] = true,
  ["mcl_core:podzol"] = true,
  ["mcl_core:podzol_snow"] = true,
  ["mcl_core:mycelium"] = true,
  ["mcl_core:mycelium_snow"] = true,
  ["mcl_core:sand"] = true,
  ["mcl_core:redsand"] = true,
  ["mcl_core:clay"] = true,
  ["mcl_core:snow"] = true,
  ["mcl_core:snowblock"] = true,
  ["mcl_mud:mud"] = true,
}

function perfectworld.compat.is_livable_ground(node_name)
  if not node_name then return false end
  if livable_ground[node_name] then return true end
  local def = minetest.registered_nodes[node_name]
  local groups = (def and def.groups) or {}
  -- Mineclonia tags anything a plant can be planted on.
  if groups.soil and groups.soil > 0 then return true end
  if groups.grass_block or groups.dirt or groups.sand then return true end
  -- Terracotta badlands are barren rock but villages there read fine, and the
  -- dry palette is built for them.
  if node_name:find("hardened_clay") or node_name:find("terracotta") then return true end
  return false
end

function perfectworld.compat.is_replaceable(node_name)
  if not node_name or node_name == "air" or node_name == "ignore" then return true end
  local def = minetest.registered_nodes[node_name]
  return def and def.buildable_to == true or false
end

-- === Environment Profile ===
-- Normalizes Mineclonia biome data into a stable, testable environment profile
-- used by village planning and material selection.

local biome_families = {
  ["mcl_biomes:grassland"] = "temperate",
  ["mcl_biomes:plains"] = "temperate",
  ["mcl_biomes:sunflower_plains"] = "temperate",
  ["mcl_biomes:forest"] = "forest",
  ["mcl_biomes:flower_forest"] = "forest",
  ["mcl_biomes:birch_forest"] = "forest",
  ["mcl_biomes:dark_forest"] = "forest",
  ["mcl_biomes:taiga"] = "cold",
  ["mcl_biomes:snowy_tundra"] = "cold",
  ["mcl_biomes:snowy_taiga"] = "cold",
  ["mcl_biomes:ice_plains"] = "cold",
  ["mcl_biomes:ice_plains_spikes"] = "cold",
  ["mcl_biomes:desert"] = "dry",
  ["mcl_biomes:savanna"] = "dry",
  ["mcl_biomes:savanna_plateau"] = "dry",
  ["mcl_biomes:mesa"] = "dry",
  ["mcl_biomes:mesa_bryce"] = "dry",
  ["mcl_biomes:jungle"] = "wet",
  ["mcl_biomes:jungle_edge"] = "wet",
  ["mcl_biomes:jungle_hills"] = "wet",
  ["mcl_biomes:swamp"] = "wet",
  ["mcl_biomes:mangrove_swamp"] = "wet",
  ["mcl_biomes:extreme_hills"] = "rocky",
  ["mcl_biomes:extreme_hills_edge"] = "rocky",
  ["mcl_biomes:stone_beach"] = "rocky",
  ["mcl_biomes:mushroom_island"] = "temperate",
  ["mcl_biomes:beach"] = "coastal",
  ["mcl_biomes:ocean"] = "coastal",
  ["mcl_biomes:deep_ocean"] = "coastal",
  ["mcl_biomes:cold_ocean"] = "coastal",
  ["mcl_biomes:frozen_ocean"] = "cold",
}

--- Resolve whatever minetest.get_biome_data() handed us into a biome name.
-- `biome_data.biome` is a numeric biome *id*; minetest.registered_biomes is
-- keyed by biome *name*, so indexing it with the id always missed and every
-- biome in the world silently resolved to "temperate".
local function resolve_biome_name(biome)
  if type(biome) == "number" then
    if minetest.get_biome_name then
      return minetest.get_biome_name(biome) or "unknown"
    end
    return "unknown"
  end
  return biome
end

perfectworld.compat.resolve_biome_name = resolve_biome_name

local function get_biome_family(biome_name)
  biome_name = resolve_biome_name(biome_name)
  if type(biome_name) ~= "string" then
    return "temperate"
  end
  local family = biome_families[biome_name]
  if family then return family end
  -- heuristic fallback based on biome name
  local lower = biome_name:lower()
  if lower:find("snow") or lower:find("ice") or lower:find("cold") or lower:find("froz") then return "cold" end
  if lower:find("desert") or lower:find("savanna") or lower:find("mesa") or lower:find("badland") then return "dry" end
  if lower:find("jungle") or lower:find("swamp") or lower:find("mangrove") then return "wet" end
  if lower:find("mount") or lower:find("hill") or lower:find("extreme") or lower:find("rock") then return "rocky" end
  if lower:find("forest") or lower:find("wood") then return "forest" end
  if lower:find("ocean") or lower:find("beach") or lower:find("shore") then return "coastal" end
  return "temperate"
end

--- Compute an environment profile at a given position.
-- Returns a table with biome information, normalized family, and derived properties.
-- Uses minetest.get_biome_data which provides heat/humidity at (x,z).
function perfectworld.compat.get_environment(pos)
  local x, z = pos.x, pos.z
  local biome_data = minetest.get_biome_data({x = x, y = pos.y, z = z})
  local biome_id = biome_data and biome_data.biome
  local biome_name = resolve_biome_name(biome_id or "unknown")
  local heat = biome_data and biome_data.heat or 50
  local humidity = biome_data and biome_data.humidity or 50
  local family = get_biome_family(biome_name)

  -- Approximate roughness by sampling nearby surface heights
  local roughness = 0
  local avg_slope = 0
  local samples = 0
  local prev_y = nil
  for dx = -4, 4, 2 do
    for dz = -4, 4, 2 do
      local sy = nil
      for y = 256, -64, -1 do
        local node = minetest.get_node({x = x + dx, y = y, z = z + dz})
        if node.name ~= "air" and node.name ~= "ignore" then
          sy = y
          break
        end
      end
      if sy then
        samples = samples + 1
        if prev_y then
          avg_slope = avg_slope + math.abs(sy - prev_y)
        end
        prev_y = sy
      end
    end
  end
  if samples > 1 then
    roughness = math.floor(avg_slope / (samples - 1) * 10) / 10
  end

  -- Water proximity: nearest open water or frozen water surface. Ice counts:
  -- a village on a frozen lake shore is still a shore settlement.
  local water_proximity = 999
  for dx = -16, 16, 4 do
    for dz = -16, 16, 4 do
      for y = pos.y + 10, pos.y - 10, -1 do
        local node = minetest.get_node({x = x + dx, y = y, z = z + dz})
        if perfectworld.compat.is_unbuildable_surface(node.name) then
          water_proximity = math.min(water_proximity, math.sqrt(dx * dx + dz * dz))
          break
        end
        if node.name ~= "air" and node.name ~= "ignore" then break end
      end
    end
  end

  -- Vegetation density heuristic
  local veg_count = 0
  local veg_samples = 0
  for dx = -8, 8, 4 do
    for dz = -8, 8, 4 do
      for y = 256, pos.y, -1 do
        local node = minetest.get_node({x = x + dx, y = y, z = z + dz})
        if node.name ~= "air" and node.name ~= "ignore" then
          veg_samples = veg_samples + 1
          if node.name:find("leaves") or node.name:find("tree") or node.name:find("grass") or node.name:find("plant") or node.name:find("flower") or node.name:find("fern") then
            veg_count = veg_count + 1
          end
          break
        end
      end
    end
  end
  local vegetation_density = veg_samples > 0 and math.floor(veg_count / veg_samples * 100) or 0

  return {
    biome_id = biome_id,
    biome_name = biome_name,
    biome_family = family,
    heat = heat,
    humidity = humidity,
    elevation = pos.y,
    roughness = roughness,
    average_slope = roughness,
    water_proximity = water_proximity,
    vegetation_density = vegetation_density,
    available_material_profile = family, -- alias for material selection
  }
end

--- Material palettes per biome family.
-- Each palette maps material roles to concrete node names.
-- Extends the base materials table with family-specific overrides.
local family_palettes = {
  temperate = {
    foundation = "mcl_core:cobble",
    wall_primary = "mcl_trees:wood_oak",
    wall_secondary = "mcl_core:cobble",
    wall_post = "mcl_trees:tree_oak",
    floor_block = "mcl_trees:wood_oak",
    roof = "mcl_stairs:slab_oak",
    roof_stair = "mcl_stairs:stair_oak",
    roof_slab = "mcl_stairs:slab_oak",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:coarse_dirt",
    fence = "mcl_fences:oak_fence",
    fence_gate = "mcl_fences:oak_fence_gate",
    crop = "mcl_farming:wheat_7",
  },
  forest = {
    foundation = "mcl_core:cobble",
    wall_primary = "mcl_trees:wood_birch",
    wall_secondary = "mcl_core:cobble",
    wall_post = "mcl_trees:tree_birch",
    floor_block = "mcl_trees:wood_birch",
    roof = "mcl_stairs:slab_birch",
    roof_stair = "mcl_stairs:stair_birch",
    roof_slab = "mcl_stairs:slab_birch",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:dirt",
    fence = "mcl_fences:birch_fence",
    fence_gate = "mcl_fences:birch_fence_gate",
    crop = "mcl_farming:carrot_7",
  },
  cold = {
    foundation = "mcl_core:cobble",
    wall_primary = "mcl_trees:wood_spruce",
    wall_secondary = "mcl_core:stonebrick",
    wall_post = "mcl_trees:tree_spruce",
    floor_block = "mcl_trees:wood_spruce",
    roof = "mcl_stairs:slab_spruce",
    roof_stair = "mcl_stairs:stair_spruce",
    roof_slab = "mcl_stairs:slab_spruce",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:gravel",
    fence = "mcl_fences:spruce_fence",
    fence_gate = "mcl_fences:spruce_fence_gate",
    crop = "mcl_farming:potato_3",
  },
  dry = {
    foundation = "mcl_core:sandstonesmooth",
    wall_primary = "mcl_core:sandstone",
    wall_secondary = "mcl_core:sandstonesmooth2",
    wall_post = "mcl_trees:tree_acacia",
    floor_block = "mcl_trees:wood_acacia",
    roof = "mcl_stairs:slab_acacia",
    roof_stair = "mcl_stairs:stair_acacia",
    roof_slab = "mcl_stairs:slab_acacia",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:sand",
    fence = "mcl_fences:acacia_fence",
    fence_gate = "mcl_fences:acacia_fence_gate",
    crop = "mcl_farming:wheat_7",
  },
  rocky = {
    foundation = "mcl_core:stonebrick",
    wall_primary = "mcl_core:cobble",
    wall_secondary = "mcl_core:stonebrick",
    wall_post = "mcl_trees:tree_dark_oak",
    floor_block = "mcl_trees:wood_dark_oak",
    roof = "mcl_stairs:slab_dark_oak",
    roof_stair = "mcl_stairs:stair_dark_oak",
    roof_slab = "mcl_stairs:slab_dark_oak",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:gravel",
    fence = "mcl_fences:dark_oak_fence",
    fence_gate = "mcl_fences:dark_oak_fence_gate",
    crop = "mcl_farming:beetroot_3",
  },
  wet = {
    foundation = "mcl_core:cobble",
    wall_primary = "mcl_trees:wood_jungle",
    wall_secondary = "mcl_trees:wood_oak",
    wall_post = "mcl_trees:tree_jungle",
    floor_block = "mcl_trees:wood_jungle",
    roof = "mcl_stairs:slab_jungle",
    roof_stair = "mcl_stairs:stair_jungle",
    roof_slab = "mcl_stairs:slab_jungle",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:dirt",
    fence = "mcl_fences:jungle_fence",
    fence_gate = "mcl_fences:jungle_fence_gate",
    crop = "mcl_farming:carrot_7",
  },
  coastal = {
    foundation = "mcl_core:stonebrick",
    wall_primary = "mcl_trees:wood_oak",
    wall_secondary = "mcl_core:sandstone",
    wall_post = "mcl_trees:tree_oak",
    floor_block = "mcl_trees:wood_oak",
    roof = "mcl_stairs:slab_oak",
    roof_stair = "mcl_stairs:stair_oak",
    roof_slab = "mcl_stairs:slab_oak",
    window = "mcl_panes:pane_natural_flat",
    path = "mcl_core:sand",
    fence = "mcl_fences:oak_fence",
    fence_gate = "mcl_fences:oak_fence_gate",
    crop = "mcl_farming:wheat_7",
  },
}

function perfectworld.compat.get_family_palette(family)
  return perfectworld.core and perfectworld.core.deep_copy and
    perfectworld.core.deep_copy(family_palettes[family]) or family_palettes[family]
end

function perfectworld.compat.get_biome_family(biome_name)
  return get_biome_family(biome_name)
end

-- Provide list of known families for testing
function perfectworld.compat.list_families()
  local families = {}
  for _, f in pairs(biome_families) do
    families[f] = true
  end
  local result = {}
  for f, _ in pairs(families) do
    table.insert(result, f)
  end
  table.sort(result)
  return result
end

minetest.log("action", "[pw_compat_mcl] loaded")
