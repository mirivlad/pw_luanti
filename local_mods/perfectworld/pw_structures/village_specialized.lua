local function optional_material(role)
  return perfectworld.compat.get_material(role, {required = false})
end

local function palette_material(ctx, key, role)
  return perfectworld.structures.palette_material(ctx.palette, key, role)
end

local function place_if_available(ctx, pos, node_name)
  if node_name ~= "air" then
    ctx.place(pos, node_name)
  end
end

local function fishery_interior(ctx)
  local hw, hd = ctx.half_w, ctx.half_d
  local barrel = optional_material("barrel")
  local smoker = optional_material("smoker")
  local cauldron = optional_material("cauldron")
  local light = optional_material("lantern")

  place_if_available(ctx, {x = -hw + 1, y = 1, z = -hd + 1}, barrel)
  place_if_available(ctx, {x = -hw + 1, y = 1, z = -hd + 2}, barrel)
  place_if_available(ctx, {x = hw - 1, y = 1, z = -hd + 1}, smoker)
  place_if_available(ctx, {x = hw - 1, y = 1, z = -hd + 2}, cauldron)
  place_if_available(ctx, {x = 0, y = ctx.height, z = 0}, light)
end

local function sawmill_interior(ctx)
  local hw, hd = ctx.half_w, ctx.half_d
  local log = palette_material(ctx, "wall_post", "tree")
  local planks = palette_material(ctx, "wall_primary", "wood_planks")
  local barrel = optional_material("barrel")
  local campfire = optional_material("campfire")

  for z = -hd + 1, hd - 1 do
    ctx.place({x = -hw + 1, y = 1, z = z}, log)
  end
  ctx.place({x = -hw + 1, y = 2, z = -hd + 1}, log)
  ctx.place({x = hw - 1, y = 1, z = -hd + 1}, planks)
  ctx.place({x = hw - 1, y = 2, z = -hd + 1}, planks)
  place_if_available(ctx, {x = hw - 1, y = 1, z = hd - 1}, barrel)
  place_if_available(ctx, {x = 0, y = 1, z = -hd + 1}, campfire)
end

local function mine_workshop_interior(ctx)
  local hw, hd = ctx.half_w, ctx.half_d
  local furnace = optional_material("furnace")
  local anvil = optional_material("anvil")
  local grindstone = optional_material("grindstone")
  local rail = optional_material("rail")
  local light = optional_material("lantern")
  local stone = palette_material(ctx, "foundation", "stone")

  place_if_available(ctx, {x = -hw + 1, y = 1, z = -hd + 1}, furnace)
  place_if_available(ctx, {x = -hw + 1, y = 1, z = -hd + 2}, anvil)
  place_if_available(ctx, {x = hw - 1, y = 1, z = -hd + 1}, grindstone)
  place_if_available(ctx, {x = 0, y = 1, z = hd - 1}, rail)
  ctx.place({x = hw - 1, y = 1, z = hd - 1}, stone)
  ctx.place({x = hw - 1, y = 2, z = hd - 1}, stone)
  place_if_available(ctx, {x = 0, y = ctx.height, z = 0}, light)
end

return function(api)
  assert(type(api) == "table" and type(api.register_building) == "function",
    "village_specialized requires register_building")

  api.register_building("pw_fishery_v1", {
    width = 9, depth = 7, wall_height = 4, door_offset_x = 0,
    categories = {"settlement", "production", "workshop", "fishery"},
    interior = fishery_interior,
  })

  api.register_building("pw_sawmill_v1", {
    width = 9, depth = 7, wall_height = 5, door_offset_x = 0,
    wide_door = true, windows = false,
    categories = {"settlement", "production", "workshop", "sawmill"},
    interior = sawmill_interior,
  })

  api.register_building("pw_mine_workshop_v1", {
    width = 7, depth = 7, wall_height = 4, door_offset_x = 0,
    categories = {"settlement", "production", "workshop", "mine_workshop"},
    interior = mine_workshop_interior,
  })
end
