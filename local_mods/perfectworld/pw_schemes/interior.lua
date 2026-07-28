-- pw_schemes/interior.lua
--
-- Furniture, placed by role rather than by node name.
--
-- A scheme says `interior = {"bed", "chest", "table", "hearth"}` and this
-- decides where each one goes and what it is made of. Two reasons it works that
-- way. A scheme should be readable as a description of a building, and a list
-- of coordinates and Mineclonia node names is not that. And a bed in a Japanese
-- house should not be the same object as a bed in a longhouse, which a role can
-- express and a node name cannot.
--
-- Placement walks a ring of positions along the walls, skipping the doorway and
-- the path from it, so nothing is furnished into the way of someone walking in.
-- The order is fixed, so the same scheme furnishes the same way every time.

local schemes = perfectworld.schemes
local put, put_facing = schemes.put, schemes.put_facing

local function first_registered(...)
  for _, name in ipairs({...}) do
    if name and minetest.registered_nodes[name] then return name end
  end
  return nil
end

--- Node choices per role, most preferred first. A role that resolves to nothing
--- in this game is skipped rather than faked.
local FIXTURES = {
  bed = function(style)
    local colour = style and style.bed_colour or "red"
    return {
      bottom = first_registered("mcl_beds:bed_" .. colour .. "_bottom", "mcl_beds:bed_red_bottom"),
      top = first_registered("mcl_beds:bed_" .. colour .. "_top", "mcl_beds:bed_red_top"),
    }
  end,
  chest = function() return {node = first_registered("mcl_chests:chest_small", "mcl_chests:chest")} end,
  table = function(mat) return {node = mat.slab} end,
  bench = function(mat) return {node = mat.stair} end,
  hearth = function() return {node = first_registered("mcl_furnaces:furnace", "mcl_core:cobble")} end,
  lamp = function() return {node = first_registered("mcl_torches:torch", "mcl_ocean:sea_lantern")} end,
  shelf = function() return {node = first_registered("mcl_books:bookshelf", "mcl_trees:wood_oak")} end,
  loom = function() return {node = first_registered("mcl_loom:loom", "mcl_trees:wood_oak")} end,
  barrel = function() return {node = first_registered("mcl_barrels:barrel_closed", "mcl_chests:chest_small")} end,
  anvil = function() return {node = first_registered("mcl_anvils:anvil", "mcl_core:ironblock")} end,
  cauldron = function() return {node = first_registered("mcl_cauldrons:cauldron", "mcl_core:cobble")} end,
  hay = function() return {node = first_registered("mcl_farming:hay_block", "mcl_trees:wood_oak")} end,
  workbench = function() return {node = first_registered("mcl_crafting_table:crafting_table", "mcl_trees:wood_oak")} end,

  -- The one fixture that is not decoration. `workstation` resolves to whatever
  -- trade this particular house was given, so the same scheme furnishes a
  -- fisherman's cottage in one village and a mason's in another. Without it a
  -- dwelling holds a bed, a chest and somebody with nothing to do: measured in
  -- a six-bed village, one farmer and five unemployed, unchanged after two
  -- minutes.
  workstation = function(_, _, trade)
    if not trade then return {} end
    local node = perfectworld.compat.get_material(
      perfectworld.settlements.workstation_for(trade), {required = false})
    if not node or node == "air" then return {} end
    return {node = node}
  end,
}

--- Wall-side positions a fixture may take, in a fixed order.
--
-- The doorway column on the +z wall is excluded along with the two cells in
-- front of it, so walking in never means walking into the furniture.
local function spots(half_w, half_d, floor_y, door_x)
  local out = {}
  local function add(x, z) out[#out + 1] = {x = x, y = floor_y + 1, z = z} end
  for z = -half_d + 1, half_d - 1 do add(-half_w + 1, z) end
  for z = -half_d + 1, half_d - 1 do add(half_w - 1, z) end
  for x = -half_w + 2, half_w - 2 do add(x, -half_d + 1) end
  for x = -half_w + 2, half_w - 2 do
    if x ~= door_x then add(x, half_d - 1) end
  end
  return out
end

function schemes.furnish(scheme, ctx)
  local mat = ctx.materials
  local available = spots(ctx.half_w, ctx.half_d, ctx.floor_y, ctx.door_x)
  local next_spot = 1

  local function take()
    local spot = available[next_spot]
    next_spot = next_spot + 1
    return spot
  end

  for _, role in ipairs(scheme.interior) do
    local resolve = FIXTURES[role]
    if resolve then
      local fixture = resolve(mat, ctx.style, ctx.trade)
      local spot = take()
      if not spot then break end

      if role == "bed" and fixture.bottom and fixture.top then
        -- A bed is two nodes and has to lie along a wall with room for its
        -- foot, so it takes the space behind it rather than beside it.
        local foot = {x = spot.x, y = spot.y, z = spot.z + 1}
        if foot.z <= ctx.half_d - 1 then
          put_facing(ctx.origin, ctx.rotation, spot, fixture.bottom, {x = 0, y = 0, z = 1})
          put_facing(ctx.origin, ctx.rotation, foot, fixture.top, {x = 0, y = 0, z = 1})
          next_spot = next_spot + 1
        end
      elseif role == "lamp" then
        -- Light belongs above head height, not on the floor where it would be
        -- walked through.
        put(ctx.origin, ctx.rotation,
          {x = spot.x, y = ctx.floor_y + ctx.height, z = spot.z}, fixture.node)
      elseif fixture.node then
        put_facing(ctx.origin, ctx.rotation, spot, fixture.node, {x = 0, y = 0, z = 1})
      end
    end
  end
end
