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

function perfectworld.compat.is_replaceable(node_name)
  if not node_name or node_name == "air" or node_name == "ignore" then return true end
  local def = minetest.registered_nodes[node_name]
  return def and def.buildable_to == true or false
end

minetest.log("action", "[pw_compat_mcl] loaded")
