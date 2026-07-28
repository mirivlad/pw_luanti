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

