-- pw_schemes/roofs.lua
--
-- Roof shapes. A roof is the thing that makes a building read as belonging
-- somewhere: the same box under a steep turf gable and under a low wide-eaved
-- hip is two different buildings from two different places.
--
-- Every shape here obeys one rule that cost this project a visible defect: a
-- stair's raised half points *uphill*, towards the ridge, so it meets the
-- underside of the course above and the slope reads as one plane. Pointing it
-- downhill leaves every course raised at its outer edge and dropping again at
-- its inner one, which from the gable end looks like a row of combs.

local put = perfectworld.schemes.put
local put_facing = perfectworld.schemes.put_facing

local UP_X = {x = 1, y = 0, z = 0}
local DOWN_X = {x = -1, y = 0, z = 0}
local UP_Z = {x = 0, y = 0, z = 1}
local DOWN_Z = {x = 0, y = 0, z = -1}

--- Shared argument bundle for every roof builder.
--
--   origin, rotation : where and which way
--   half_w, half_d   : half the footprint, floored
--   base_y           : the course the roof starts on
--   stair, slab      : the roof materials
--   gable            : what fills the triangle at a gable end
--   pitch            : node of rise per node of run; 1 is 45 degrees
--   eaves            : how far the roof oversails the wall

local function courses(half, pitch, eaves)
  -- How many courses a slope needs to close, and how far in each one steps.
  -- With pitch 2 the roof climbs two nodes per node of inward travel, which is
  -- the steep northern look; with pitch 1 it is the usual 45 degrees.
  return math.ceil((half + eaves) / 1), pitch
end

local roofs = {}

--- A gable: two slopes meeting at a ridge, triangles closing both ends.
function roofs.gable(o)
  local half_w, half_d = o.half_w, o.half_d
  local eaves = o.eaves or 1
  local rise = o.pitch or 1
  local total = courses(half_w, rise, eaves)

  for step = 0, total do
    local y = o.base_y + step * rise
    local left = -half_w - eaves + step
    local right = half_w + eaves - step
    if left > right then break end

    if left == right then
      for z = -half_d - eaves, half_d + eaves do
        put(o.origin, o.rotation, {x = left, y = y, z = z}, o.slab)
      end
      break
    end

    for z = -half_d - eaves, half_d + eaves do
      put_facing(o.origin, o.rotation, {x = left, y = y, z = z}, o.stair, UP_X)
      put_facing(o.origin, o.rotation, {x = right, y = y, z = z}, o.stair, DOWN_X)
    end

    -- Close the triangles so the loft is not open to the weather.
    for x = left + 1, right - 1 do
      put(o.origin, o.rotation, {x = x, y = y, z = -half_d}, o.gable)
      put(o.origin, o.rotation, {x = x, y = y, z = half_d}, o.gable)
    end
  end
end

--- A hip: four slopes, no gable ends. Reads as grander than a gable, and needs
--- no triangle to close, because every side is a slope.
function roofs.hip(o)
  local eaves = o.eaves or 1
  local rise = o.pitch or 1
  local reach = math.min(o.half_w, o.half_d) + eaves

  for step = 0, reach do
    local y = o.base_y + step * rise
    local x0, x1 = -o.half_w - eaves + step, o.half_w + eaves - step
    local z0, z1 = -o.half_d - eaves + step, o.half_d + eaves - step
    if x0 > x1 or z0 > z1 then break end

    if x0 == x1 and z0 == z1 then
      put(o.origin, o.rotation, {x = x0, y = y, z = z0}, o.slab)
      break
    end

    for z = z0, z1 do
      put_facing(o.origin, o.rotation, {x = x0, y = y, z = z}, o.stair, UP_X)
      put_facing(o.origin, o.rotation, {x = x1, y = y, z = z}, o.stair, DOWN_X)
    end
    for x = x0 + 1, x1 - 1 do
      put_facing(o.origin, o.rotation, {x = x, y = y, z = z0}, o.stair, UP_Z)
      put_facing(o.origin, o.rotation, {x = x, y = y, z = z1}, o.stair, DOWN_Z)
    end

    -- A hip that has closed in one axis but not the other finishes as a short
    -- ridge rather than a point.
    if x0 == x1 then
      for z = z0 + 1, z1 - 1 do
        put(o.origin, o.rotation, {x = x0, y = y, z = z}, o.slab)
      end
    elseif z0 == z1 then
      for x = x0 + 1, x1 - 1 do
        put(o.origin, o.rotation, {x = x, y = y, z = z0}, o.slab)
      end
    end
  end
end

--- A pent: one slope, falling from a high wall to a low one. The shape of a
--- lean-to, a shed and a workshop annexe.
function roofs.pent(o)
  local eaves = o.eaves or 1
  local rise = o.pitch or 1
  local span = o.half_w * 2 + eaves * 2

  for step = 0, span do
    local x = -o.half_w - eaves + step
    if x > o.half_w + eaves then break end
    local y = o.base_y + math.floor(step * rise)
    for z = -o.half_d - eaves, o.half_d + eaves do
      put_facing(o.origin, o.rotation, {x = x, y = y, z = z}, o.stair, UP_X)
    end
    -- Fill the wall under the rise so the slope does not float over open air.
    for fill_y = o.base_y, y - 1 do
      put(o.origin, o.rotation, {x = x, y = fill_y, z = -o.half_d}, o.gable)
      put(o.origin, o.rotation, {x = x, y = fill_y, z = o.half_d}, o.gable)
    end
  end
end

--- A flat roof with a parapet: a terrace, a tower top, a southern rooftop.
function roofs.flat(o)
  local eaves = o.eaves or 0
  for x = -o.half_w - eaves, o.half_w + eaves do
    for z = -o.half_d - eaves, o.half_d + eaves do
      put(o.origin, o.rotation, {x = x, y = o.base_y, z = z}, o.slab)
    end
  end
  if o.parapet ~= false then
    for x = -o.half_w - eaves, o.half_w + eaves do
      put(o.origin, o.rotation, {x = x, y = o.base_y + 1, z = -o.half_d - eaves}, o.gable)
      put(o.origin, o.rotation, {x = x, y = o.base_y + 1, z = o.half_d + eaves}, o.gable)
    end
    for z = -o.half_d - eaves, o.half_d + eaves do
      put(o.origin, o.rotation, {x = -o.half_w - eaves, y = o.base_y + 1, z = z}, o.gable)
      put(o.origin, o.rotation, {x = o.half_w + eaves, y = o.base_y + 1, z = z}, o.gable)
    end
  end
end

--- A gable whose eaves reach far out and whose pitch is shallow: the silhouette
--- of a building built for heavy rain and deep shade rather than for snow.
function roofs.wide_eaved_gable(o)
  local wide = {}
  for key, value in pairs(o) do wide[key] = value end
  wide.eaves = math.max(o.eaves or 1, 2)
  wide.pitch = 1
  roofs.gable(wide)
end

perfectworld.schemes.ROOFS = roofs
