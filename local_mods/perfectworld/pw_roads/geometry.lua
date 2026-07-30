local roads = perfectworld.roads

local function width_value(width)
  return math.max(math.floor(tonumber(width) or 1), 1)
end

local function round(value)
  return math.floor(value + 0.5)
end

local function canonical_direction(dx, dz)
  dx = tonumber(dx) or 0
  dz = tonumber(dz) or 0
  if dx < 0 or (dx == 0 and dz < 0) then
    dx, dz = -dx, -dz
  end
  return dx, dz
end

--- Integer offsets across a road, perpendicular to its direction.
--
-- Even widths are centred on the half-cell between the two middle rows. A
-- canonical direction makes the unavoidable one-cell bias independent of
-- whether a path was recorded forwards or backwards.
function roads.cross_section(dx, dz, width)
  dx, dz = canonical_direction(dx, dz)
  local abs_x, abs_z = math.abs(dx), math.abs(dz)
  local perpendicular_x, perpendicular_z
  if abs_x > abs_z then
    perpendicular_x, perpendicular_z = 0, 1
  elseif abs_z > abs_x then
    perpendicular_x, perpendicular_z = 1, 0
  elseif abs_x > 0 then
    perpendicular_x = dz >= 0 and -1 or 1
    perpendicular_z = 1
  else
    perpendicular_x, perpendicular_z = 0, 1
  end

  local result = {}
  local count = width_value(width)
  local first = -(count - 1) / 2
  for index = 0, count - 1 do
    local offset = round(first + index)
    result[#result + 1] = {
      x = perpendicular_x * offset,
      z = perpendicular_z * offset,
    }
  end
  return result
end

--- The cells a way of this width covers, one list per centreline cell.
--
-- `cross_section` alone does not make a road. It gives a row of cells across
-- one direction, and a rasterized centreline changes direction constantly: a
-- gentle diagonal is a staircase, so the row flips between running north-south
-- and east-west from one cell to the next. Laid out, that is not a carriageway
-- but a chain of two-cell dashes touching at their corners — the blotchy zigzag
-- in every screenshot of a road this project has taken.
--
-- Two rules fix it, and neither is a special case:
--
--  * Take the direction from a window rather than from the neighbours. A
--    staircase averaged over five cells is a diagonal, and a diagonal has a
--    stable perpendicular.
--  * Where consecutive rows touch only at a corner, fill the corner. A road you
--    can only cross diagonally is not one a walker can follow, and the engine's
--    pathfinder agrees: it steps north, south, east and west.
--
-- Pure: no world reads, no randomness, and the same input gives the same
-- output cell for cell.
local WINDOW = 2

function roads.way_footprint(cells, first, last, width)
  first = first or 1
  last = last or #cells
  local footprint = {}
  local owner = {}

  local function claim(index, x, z)
    local key = x .. ":" .. z
    if owner[key] then return end
    owner[key] = index
    footprint[index] = footprint[index] or {}
    local list = footprint[index]
    list[#list + 1] = {x = x, z = z}
  end

  for i = first, last do
    local cell = cells[i]
    if cell then
      local ahead = cells[math.min(i + WINDOW, last)] or cell
      local behind = cells[math.max(i - WINDOW, first)] or cell
      local dx, dz = ahead.x - behind.x, ahead.z - behind.z
      if dx == 0 and dz == 0 then dx = 1 end
      for _, offset in ipairs(roads.cross_section(dx, dz, width)) do
        claim(i, cell.x + offset.x, cell.z + offset.z)
      end
    end
  end

  -- Close the corners. Two rows that share no edge are joined through the
  -- cell that is orthogonal to one and orthogonal to the other; there are two
  -- such cells for a diagonal pair and the lower-sorting one is taken, so the
  -- result does not depend on which way the way was walked.
  for i = first, last - 1 do
    local here, there = footprint[i], footprint[i + 1]
    if here and there then
      local touching = false
      for _, a in ipairs(here) do
        for _, b in ipairs(there) do
          if math.abs(a.x - b.x) + math.abs(a.z - b.z) <= 1 then
            touching = true
            break
          end
        end
        if touching then break end
      end
      if not touching then
        local best = nil
        for _, a in ipairs(here) do
          for _, b in ipairs(there) do
            if math.abs(a.x - b.x) == 1 and math.abs(a.z - b.z) == 1 then
              for _, corner in ipairs({{x = a.x, z = b.z}, {x = b.x, z = a.z}}) do
                if not best or corner.x < best.x
                  or (corner.x == best.x and corner.z < best.z) then
                  best = corner
                end
              end
            end
          end
        end
        if best then claim(i, best.x, best.z) end
      end
    end
  end

  return footprint
end

local function sorted_cells(set)
  local cells = {}
  for _, cell in pairs(set) do
    cells[#cells + 1] = cell
  end
  table.sort(cells, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.z < b.z
  end)
  return cells
end

local function add_cell(set, x, z)
  x, z = round(x), round(z)
  set[x .. ":" .. z] = {x = x, z = z}
end

--- Rasterize a path into a canonical, de-duplicated list of exact road cells.
function roads.rasterize(path, width)
  path = type(path) == "table" and path or {}
  local set = {}

  if #path == 1 then
    for _, offset in ipairs(roads.cross_section(1, 0, width)) do
      add_cell(set, path[1].x + offset.x, path[1].z + offset.z)
    end
  end

  for segment = 1, #path - 1 do
    local from, to = path[segment], path[segment + 1]
    local dx, dz = to.x - from.x, to.z - from.z
    local offsets = roads.cross_section(dx, dz, width)
    local steps = math.max(math.abs(dx), math.abs(dz), 1)
    for step = 0, steps do
      local ratio = step / steps
      local center_x = round(from.x + dx * ratio)
      local center_z = round(from.z + dz * ratio)
      for _, offset in ipairs(offsets) do
        add_cell(set, center_x + offset.x, center_z + offset.z)
      end
    end
  end

  return sorted_cells(set)
end

function roads.cell_set(path, width)
  local set = {}
  for _, cell in ipairs(roads.rasterize(path, width)) do
    set[cell.x .. ":" .. cell.z] = cell
  end
  return set
end

--- Use persisted cells when present; derive them for legacy path-only records.
function roads.rasterize_record(road)
  road = type(road) == "table" and road or {}
  if type(road.cells) == "table" then
    local set = {}
    for _, cell in ipairs(road.cells) do
      if type(cell) == "table"
        and tonumber(cell.x) and tonumber(cell.z) then
        add_cell(set, cell.x, cell.z)
      end
    end
    return sorted_cells(set)
  end
  return roads.rasterize(road.path or road.points or {}, road.width or 1)
end

