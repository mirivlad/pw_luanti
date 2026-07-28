-- Bounded, transactional physical work sites for ecological villages.

local worksites = {}
local deep_copy = perfectworld.core.deep_copy
local MAX_TRANSACTION_VOLUME = 4096
local placed_records = {}

local function sorted_bounds(bounds)
  if type(bounds) ~= "table"
    or type(bounds.min) ~= "table"
    or type(bounds.max) ~= "table" then
    return nil
  end
  return {
    min = {
      x = math.min(bounds.min.x, bounds.max.x),
      y = math.min(bounds.min.y, bounds.max.y),
      z = math.min(bounds.min.z, bounds.max.z),
    },
    max = {
      x = math.max(bounds.min.x, bounds.max.x),
      y = math.max(bounds.min.y, bounds.max.y),
      z = math.max(bounds.min.z, bounds.max.z),
    },
  }
end

local function volume(bounds)
  return (bounds.max.x - bounds.min.x + 1)
    * (bounds.max.y - bounds.min.y + 1)
    * (bounds.max.z - bounds.min.z + 1)
end

local function restore(snapshot)
  for index = #snapshot, 1, -1 do
    local entry = snapshot[index]
    minetest.set_node(entry.pos, entry.node)
  end
end

function worksites.transaction(bounds, mutator)
  local exact = sorted_bounds(bounds)
  if not exact then return false, {reason = "invalid_worksite_bounds"} end
  local size = volume(exact)
  if size > MAX_TRANSACTION_VOLUME then
    return false, {
      reason = "worksite_too_large",
      volume = size,
      maximum = MAX_TRANSACTION_VOLUME,
    }
  end
  if type(mutator) ~= "function" then
    return false, {reason = "invalid_worksite_mutator"}
  end

  local snapshot = {}
  for x = exact.min.x, exact.max.x do
    for y = exact.min.y, exact.max.y do
      for z = exact.min.z, exact.max.z do
        local pos = {x = x, y = y, z = z}
        if minetest.is_protected(pos, "") then
          return false, {reason = "worksite_protected", pos = pos}
        end
        local node = minetest.get_node(pos)
        if node.name == "ignore" then
          return false, {reason = "worksite_not_loaded", pos = pos}
        end
        snapshot[#snapshot + 1] = {
          pos = pos,
          node = {name = node.name, param2 = node.param2 or 0},
        }
      end
    end
  end

  local called, result, detail = pcall(mutator, exact)
  if not called or result == false then
    restore(snapshot)
    if type(detail) == "table" then return false, detail end
    if type(result) == "table" and result.reason then return false, result end
    return false, {
      reason = "worksite_mutator_failed",
      error = tostring(called and detail or result),
    }
  end
  return true, result
end

local function optional_material(role)
  return perfectworld.compat.get_material(role, {required = false})
end

local function palette_material(context, key, role)
  if perfectworld.structures and perfectworld.structures.palette_material then
    return perfectworld.structures.palette_material(context.palette, key, role)
  end
  return optional_material(role)
end

local function surface_y(context, x, z, hint)
  if type(context.surface_y) == "function" then
    return context.surface_y(x, z)
  end
  local top = hint and hint + 8 or 256
  local bottom = hint and hint - 8 or -64
  for y = top, bottom, -1 do
    local node = minetest.get_node({x = x, y = y, z = z})
    if node.name ~= "air" and node.name ~= "ignore" then return y end
  end
  return nil
end

local function rectangle_cells(anchor, half_x, half_z)
  local cells = {}
  for dx = -half_x, half_x do
    for dz = -half_z, half_z do
      cells[#cells + 1] = {
        x = anchor.x + dx,
        z = anchor.z + dz,
        dx = dx,
        dz = dz,
      }
    end
  end
  return cells
end

local function cardinal_direction(from, to)
  local dx = (to.x or 0) - (from.x or 0)
  local dz = (to.z or 0) - (from.z or 0)
  if math.abs(dx) >= math.abs(dz) and dx ~= 0 then
    return dx > 0 and 1 or -1, 0
  elseif dz ~= 0 then
    return 0, dz > 0 and 1 or -1
  end
  return nil
end

local function line_cells(origin, dir_x, dir_z, first, last, half_width)
  local cells = {}
  local side_x, side_z = -dir_z, dir_x
  for step = first, last do
    for offset = -half_width, half_width do
      cells[#cells + 1] = {
        x = origin.x + dir_x * step + side_x * offset,
        z = origin.z + dir_z * step + side_z * offset,
        step = step,
        offset = offset,
      }
    end
  end
  return cells
end

local function bounds_for(cells, min_y, max_y)
  local bounds = {
    min = {x = math.huge, y = min_y, z = math.huge},
    max = {x = -math.huge, y = max_y, z = -math.huge},
  }
  for _, cell in ipairs(cells) do
    bounds.min.x = math.min(bounds.min.x, cell.x)
    bounds.max.x = math.max(bounds.max.x, cell.x)
    bounds.min.z = math.min(bounds.min.z, cell.z)
    bounds.max.z = math.max(bounds.max.z, cell.z)
  end
  return bounds
end

local function footprint_cells(cells)
  local out, seen = {}, {}
  for _, cell in ipairs(cells) do
    local key = cell.x .. ":" .. cell.z
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = {x = cell.x, z = cell.z}
    end
  end
  table.sort(out, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.z < b.z
  end)
  return out
end

local function overlaps_blocked(cells, context)
  for _, cell in ipairs(cells) do
    local key = cell.x .. ":" .. cell.z
    if context.road_cells and context.road_cells[key] then
      return "worksite_overlaps_road"
    end
    for _, box in ipairs(context.structure_footprints or {}) do
      local min = box.min or box.footprint_min
      local max = box.max or box.footprint_max
      if min and max
        and cell.x >= math.min(min.x, max.x)
        and cell.x <= math.max(min.x, max.x)
        and cell.z >= math.min(min.z, max.z)
        and cell.z <= math.max(min.z, max.z) then
        return "worksite_overlaps_structure"
      end
    end
  end
  return nil
end

local function tracker()
  local by_key = {}
  return {
    set = function(_, pos, node_name, param2)
      if not node_name then return end
      minetest.set_node(pos, {name = node_name, param2 = param2 or 0})
      local key = pos.x .. ":" .. pos.y .. ":" .. pos.z
      if node_name == "air" then
        by_key[key] = nil
      else
        local actual = minetest.get_node(pos)
        by_key[key] = {
          position = {x = pos.x, y = pos.y, z = pos.z},
          node_name = actual.name,
          param2 = actual.param2 or 0,
        }
      end
    end,
    expected = function()
      local result = {}
      for _, entry in pairs(by_key) do result[#result + 1] = entry end
      table.sort(result, function(a, b)
        local ap, bp = a.position, b.position
        if ap.x ~= bp.x then return ap.x < bp.x end
        if ap.y ~= bp.y then return ap.y < bp.y end
        return ap.z < bp.z
      end)
      return result
    end,
  }
end

local function field_spec(anchor, context)
  local cells = rectangle_cells(anchor, 4, 3)
  local bounds = bounds_for(cells, anchor.y - 3, anchor.y + 4)
  return {
    anchor = anchor,
    cells = cells,
    bounds = bounds,
    mutate = function()
      local placed = tracker()
      local fence = palette_material(context, "fence", "fence")
      local soil = optional_material("garden_soil")
      local crop = palette_material(context, "crop", "crop")
      local water = optional_material("water")
      local composter = optional_material("composter")

      for _, cell in ipairs(cells) do
        local y = surface_y(context, cell.x, cell.z, anchor.y)
        if not y or math.abs(y - anchor.y) > 2 then
          return false, {reason = "worksite_terrain_unusable"}
        end
        local ground = minetest.get_node({x = cell.x, y = y, z = cell.z})
        if perfectworld.compat.is_liquid_node(ground.name) then
          return false, {reason = "worksite_terrain_unusable"}
        end
        local edge = math.abs(cell.dx) == 4 or math.abs(cell.dz) == 3
        if edge then
          if fence ~= "air" then
            placed:set({x = cell.x, y = y + 1, z = cell.z}, fence)
          end
        elseif cell.dx == 0 and cell.dz == 0 and water ~= "air" then
          placed:set({x = cell.x, y = y, z = cell.z}, water)
        else
          placed:set({x = cell.x, y = y, z = cell.z}, soil)
          if crop ~= "air" and (cell.dx + cell.dz) % 2 == 0 then
            placed:set({x = cell.x, y = y + 1, z = cell.z}, crop)
          end
        end
      end
      if composter ~= "air" then
        placed:set({
          x = anchor.x + 3, y = anchor.y + 1, z = anchor.z + 2,
        }, composter)
      end
      return {expected_nodes = placed:expected()}
    end,
  }
end

local function forestry_spec(anchor, context)
  local cells = rectangle_cells(anchor, 4, 3)
  local bounds = bounds_for(cells, anchor.y - 3, anchor.y + 5)
  return {
    anchor = anchor,
    cells = cells,
    bounds = bounds,
    mutate = function()
      local placed = tracker()
      local log = palette_material(context, "wall_post", "tree")
      local planks = palette_material(context, "wall_primary", "wood_planks")
      local beehive = optional_material("beehive")
      local barrel = optional_material("barrel")
      local fence = palette_material(context, "fence", "fence")
      local chain = optional_material("chain")
      local campfire = optional_material("campfire")

      for _, cell in ipairs(cells) do
        local y = surface_y(context, cell.x, cell.z, anchor.y)
        if not y or math.abs(y - anchor.y) > 2 then
          return false, {reason = "worksite_terrain_unusable"}
        end
        local ground = minetest.get_node({x = cell.x, y = y, z = cell.z})
        if perfectworld.compat.is_liquid_node(ground.name) then
          return false, {reason = "worksite_terrain_unusable"}
        end
      end

      for z = -2, 2 do
        placed:set({x = anchor.x - 3, y = anchor.y + 1, z = anchor.z + z}, log)
      end
      placed:set({x = anchor.x - 3, y = anchor.y + 2, z = anchor.z - 2}, log)
      for x = 0, 2 do
        for z = -1, 1 do
          placed:set({x = anchor.x + x, y = anchor.y, z = anchor.z + z}, planks)
        end
      end
      if beehive ~= "air" then
        placed:set({x = anchor.x + 3, y = anchor.y + 1, z = anchor.z - 2}, beehive)
        placed:set({x = anchor.x + 3, y = anchor.y + 1, z = anchor.z}, beehive)
      end
      if barrel ~= "air" then
        placed:set({x = anchor.x + 3, y = anchor.y + 1, z = anchor.z + 2}, barrel)
      end
      if campfire ~= "air" then
        placed:set({x = anchor.x, y = anchor.y + 1, z = anchor.z + 2}, campfire)
      end
      if fence ~= "air" then
        for _, x in ipairs({-1, 1}) do
          placed:set({x = anchor.x + x, y = anchor.y + 1, z = anchor.z - 2}, fence)
          placed:set({x = anchor.x + x, y = anchor.y + 2, z = anchor.z - 2}, fence)
        end
        if chain ~= "air" then
          placed:set({x = anchor.x, y = anchor.y + 2, z = anchor.z - 2}, chain)
        end
      end
      return {expected_nodes = placed:expected()}
    end,
  }
end

local function dock_spec(context)
  local shore = context.shore_anchor
  local land = context.shore_land_anchor
  if type(shore) ~= "table" or type(land) ~= "table" then
    return nil, {reason = "missing_shore_anchor"}
  end
  local dir_x, dir_z = cardinal_direction(land, shore)
  if not dir_x then return nil, {reason = "missing_shore_anchor"} end
  local water = minetest.get_node({
    x = shore.x, y = shore.y, z = shore.z,
  })
  if not perfectworld.compat.is_unbuildable_surface(water.name) then
    return nil, {reason = "shore_anchor_not_liquid"}
  end
  local cells = line_cells(land, dir_x, dir_z, 0, 6, 1)
  local deck_y = land.y + 1
  local bounds = bounds_for(cells, deck_y - 5, deck_y + 4)
  return {
    anchor = deep_copy(land),
    cells = cells,
    bounds = bounds,
    mutate = function()
      local placed = tracker()
      local deck = palette_material(context, "floor_block", "wood_planks")
      local pile = palette_material(context, "wall_post", "tree")
      local barrel = optional_material("barrel")
      local fence = palette_material(context, "fence", "fence")
      local chain = optional_material("chain")
      local light = optional_material("lantern")
      local side_x, side_z = -dir_z, dir_x

      for _, cell in ipairs(cells) do
        placed:set({x = cell.x, y = deck_y, z = cell.z}, deck)
      end
      for _, step in ipairs({3, 6}) do
        for _, side in ipairs({-1, 1}) do
          local x = land.x + dir_x * step + side_x * side
          local z = land.z + dir_z * step + side_z * side
          local supported = false
          for depth = 1, 4 do
            local pos = {x = x, y = deck_y - depth, z = z}
            local node = minetest.get_node(pos)
            if node.name ~= "air"
              and not perfectworld.compat.is_liquid_node(node.name) then
              supported = true
              break
            end
            placed:set(pos, pile)
          end
          if not supported then
            return false, {reason = "dock_water_too_deep"}
          end
        end
      end
      if barrel ~= "air" then
        placed:set({
          x = land.x + side_x, y = deck_y + 1, z = land.z + side_z,
        }, barrel)
      end
      if fence ~= "air" then
        for _, side in ipairs({-1, 1}) do
          local x = land.x + dir_x + side_x * side
          local z = land.z + dir_z + side_z * side
          placed:set({x = x, y = deck_y + 1, z = z}, fence)
          placed:set({x = x, y = deck_y + 2, z = z}, fence)
        end
        if chain ~= "air" then
          placed:set({
            x = land.x + dir_x, y = deck_y + 2, z = land.z + dir_z,
          }, chain)
        end
      end
      if light ~= "air" then
        placed:set({
          x = land.x + dir_x * 5, y = deck_y + 1, z = land.z + dir_z * 5,
        }, light)
      end
      return {expected_nodes = placed:expected()}
    end,
  }
end

local function minehead_spec(context)
  local stone = context.stone_anchor
  if type(stone) ~= "table" then
    return nil, {reason = "missing_stone_anchor"}
  end
  local node = minetest.get_node({x = stone.x, y = stone.y, z = stone.z})
  if not perfectworld.compat.classify_node(node.name).stone then
    return nil, {reason = "stone_anchor_not_stone"}
  end
  local approach = context.approach_anchor or {
    x = stone.x - 1, y = stone.y, z = stone.z,
  }
  local dir_x, dir_z = cardinal_direction(approach, stone)
  if not dir_x then dir_x, dir_z = 1, 0 end
  local cells = line_cells(stone, dir_x, dir_z, -2, 4, 1)
  local bounds = bounds_for(cells, stone.y - 3, stone.y + 4)
  return {
    anchor = deep_copy(stone),
    cells = cells,
    bounds = bounds,
    mutate = function()
      local placed = tracker()
      local support = palette_material(context, "wall_post", "tree")
      local stone_material = palette_material(context, "foundation", "stone")
      local rail = optional_material("rail")
      local furnace = optional_material("furnace")
      local anvil = optional_material("anvil")
      local light = optional_material("lantern")
      local side_x, side_z = -dir_z, dir_x

      for step = 0, 3 do
        local x = stone.x + dir_x * step
        local z = stone.z + dir_z * step
        placed:set({x = x, y = stone.y + 1, z = z}, "air")
        placed:set({x = x, y = stone.y + 2, z = z}, "air")
        if rail ~= "air" then
          placed:set({x = x, y = stone.y + 1, z = z}, rail)
        end
      end
      for _, step in ipairs({0, 2}) do
        for _, side in ipairs({-1, 1}) do
          local x = stone.x + dir_x * step + side_x * side
          local z = stone.z + dir_z * step + side_z * side
          placed:set({x = x, y = stone.y + 1, z = z}, support)
          placed:set({x = x, y = stone.y + 2, z = z}, support)
        end
        placed:set({
          x = stone.x + dir_x * step,
          y = stone.y + 3,
          z = stone.z + dir_z * step,
        }, support)
      end
      for offset = -1, 1 do
        local x = stone.x + dir_x * 4 + side_x * offset
        local z = stone.z + dir_z * 4 + side_z * offset
        placed:set({x = x, y = stone.y + 1, z = z}, stone_material)
        placed:set({x = x, y = stone.y + 2, z = z}, stone_material)
      end
      local yard_x = stone.x - dir_x * 2
      local yard_z = stone.z - dir_z * 2
      if furnace ~= "air" then
        placed:set({x = yard_x + side_x, y = stone.y + 1, z = yard_z + side_z}, furnace)
      end
      if anvil ~= "air" then
        placed:set({x = yard_x - side_x, y = stone.y + 1, z = yard_z - side_z}, anvil)
      end
      if light ~= "air" then
        placed:set({x = stone.x, y = stone.y + 2, z = stone.z}, light)
      end
      return {expected_nodes = placed:expected()}
    end,
  }
end

local builders = {
  field = field_spec,
  forestry_yard = forestry_spec,
}

local function make_spec(kind, anchor, context)
  if kind == "dock" then return dock_spec(context) end
  if kind == "minehead" then return minehead_spec(context) end
  local builder = builders[kind]
  if not builder then return nil, {reason = "unknown_worksite_kind"} end
  if type(anchor) ~= "table" then
    return nil, {reason = "missing_worksite_anchor"}
  end
  return builder(anchor, context)
end

function worksites.place(kind, context)
  context = context or {}
  local id = context.worksite_id
  if type(id) ~= "string" or id == "" then
    return false, {reason = "missing_worksite_id"}
  end
  if placed_records[id] then return true, deep_copy(placed_records[id]) end

  local anchors = context.candidate_anchors
  if type(anchors) ~= "table" or #anchors == 0 then
    anchors = {context.anchor}
  end
  if kind == "dock" or kind == "minehead" then anchors = {false} end

  local last_error = {reason = "worksite_unplaceable"}
  for _, anchor in ipairs(anchors) do
    local spec, spec_error = make_spec(kind, anchor, context)
    if not spec then
      last_error = spec_error or last_error
    else
      local blocked = overlaps_blocked(spec.cells, context)
      if blocked then
        last_error = {reason = blocked}
      else
        local ok, result = worksites.transaction(spec.bounds, spec.mutate)
        if ok then
          local expected = result.expected_nodes or {}
          local record = {
            id = id,
            kind = kind,
            required = context.required == true,
            anchor = deep_copy(spec.anchor),
            bounds = deep_copy(spec.bounds),
            footprint_cells = footprint_cells(spec.cells),
            expected_nodes = deep_copy(expected),
            node_count = #expected,
            status = "materialized",
          }
          placed_records[id] = deep_copy(record)
          return true, record
        end
        last_error = result or last_error
      end
    end
  end
  return false, last_error
end

function worksites._test_forget(id)
  placed_records[id] = nil
end

return worksites
