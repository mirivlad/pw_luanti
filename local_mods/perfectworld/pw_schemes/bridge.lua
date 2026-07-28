-- pw_schemes/bridge.lua
--
-- Every scheme, registered as an ordinary `pw_structures` definition.
--
-- The planner already knows how to site a building: it analyses the terrain,
-- picks a rotation, prepares the ground, carries a plinth down a slope, checks
-- the door is reachable on foot, records what it placed and rolls the whole
-- thing back when placement fails. None of that should be rewritten because the
-- building came from a table instead of from a generator.
--
-- So a scheme becomes a structure definition whose generator calls the scheme
-- builder. The catalogue gets to be data; the placement pipeline stays the one
-- that has already been debugged against real terrain.
--
-- The numbers below are derived from the scheme rather than declared in it,
-- because a scheme should describe a building and not its bounding box. Getting
-- these wrong is quiet: a size that under-reports the roof lets a neighbour be
-- planned into it, and a footprint that omits the doorstep lets the planner
-- decide a lot is buildable when the porch would hang over a cliff.

local schemes = perfectworld.schemes

--- How tall the finished building is, roof included.
--
-- A gable or hip closes at `pitch` nodes per node of inward travel, so a wide
-- steep roof is much taller than a wide shallow one, and a flat roof adds only
-- its parapet. Over-reporting costs nothing; under-reporting means the planner
-- thinks there is air where there is roof.
local function total_height(scheme)
  local half_w = math.floor(scheme.footprint.w / 2)
  local eaves = scheme.roof.eaves or 1
  local pitch = scheme.roof.pitch or 1
  local kind = scheme.roof.kind

  local roof
  if kind == "flat" then
    roof = 2
  elseif kind == "pent" then
    roof = math.ceil((half_w * 2 + eaves * 2) * pitch) + 1
  else
    roof = math.ceil((half_w + eaves) * pitch) + 1
  end
  return (scheme.raised_floor or 0) + scheme.wall_height + roof + 2
end

--- The ground the building actually needs to be flat.
--
-- Not the bounding box: the roof oversails the walls and the planner must not
-- demand level ground under an overhang. But it does include the doorstep,
-- which extends past the wall by the depth of the eaves plus one, because that
-- is where a walker stands and it has to be solid.
local function building_footprint(scheme)
  local half_w = math.floor(scheme.footprint.w / 2)
  local half_d = math.floor(scheme.footprint.d / 2)
  local step = math.max(scheme.roof.eaves or 1, 1) + 1
  return {
    min_x = -half_w, max_x = half_w,
    -- Reaches to the outer doorstep, which is the node the connector names and
    -- therefore the node that has to be solid ground.
    min_z = -half_d, max_z = half_d + step,
  }
end

local function terrain_for(scheme)
  local terrain = {
    max_slope = 3,
    foundation_depth = 3,
    clearance_height = math.max(8, total_height(scheme)),
    modification_margin = 1,
    max_cut_depth = 4,
    max_fill_height = 4,
    max_plinth_depth = 12,
    building_footprint = building_footprint(scheme),
  }
  -- A building on posts is meant to stand over ground that is not level, and
  -- over water. Holding it to the same flatness as a cottage on a plinth would
  -- reject every site a stilt village could exist on.
  if (scheme.raised_floor or 0) > 0 then
    terrain.max_slope = 5
    terrain.max_fill_height = 2
  end
  return terrain
end

--- Categories the planner and the debug tools filter on.
local function categories_for(scheme)
  local out = {"settlement", "scheme", scheme.style}
  for _, role in ipairs(scheme.roles) do out[#out + 1] = role end
  return out
end

local registered = {}

function schemes.register_as_structures()
  local count = 0
  for _, id in ipairs(schemes.list()) do
    if not registered[id] then
      local scheme = schemes.get(id)
      local half_w = math.floor(scheme.footprint.w / 2)
      local half_d = math.floor(scheme.footprint.d / 2)
      local eaves = math.max(scheme.roof.eaves or 1, 1)
      local door_x = scheme.door and scheme.door.offset or 0

      -- The bounding box is exactly what the building occupies: the walls, the
      -- eaves oversailing them on every side, and the doorstep reaching past
      -- the front. Not one node more.
      --
      -- Padding it "to be safe" is not safe. The road connector has to sit at
      -- or beyond the box's half-depth, because anything nearer is under the
      -- building's own overhang — and a connector under the eaves is how every
      -- downward surface scan found roof instead of ground and made the door
      -- unreachable. A too-large box silently pushes the connector inside it.
      -- The box reaches back and sideways as far as the eaves, and forward
      -- exactly to the outer doorstep — which is where the connector sits. That
      -- equality is not incidental: the connector must be at or past the box's
      -- half-depth, and any padding in front pushes the halfway point outwards
      -- until the connector falls inside the overhang again. Wide eaves make
      -- this bite first, which is why the Japanese and stilt schemes found it.
      local ok = perfectworld.structures.register(id, {
        version = 1,
        size = {
          x = scheme.footprint.w + eaves * 2,
          y = total_height(scheme),
          z = scheme.footprint.d + eaves * 2 + 1,
        },
        origin = {x = half_w + eaves, y = 0, z = half_d + eaves},
        categories = categories_for(scheme),
        weight = 1,
        allowed_settlement_types = {"village", "hamlet"},
        rotations = {0, 90, 180, 270},
        terrain = terrain_for(scheme),
        connectors = {
          -- The road meets the building at the outer doorstep, clear of the
          -- overhang, so nothing hangs above the point a walker aims for.
          {type = "road", side = "south", offset = 0,
           offset_pos = {x = door_x, y = 0, z = half_d + eaves + 1}},
        },
        placement = {
          type = "lua",
          generator = function(context, def)
            return schemes.build(id, context)
          end,
          preflight = function()
            perfectworld.compat.get_material("wall")
            return true
          end,
        },
      })
      if ok then
        registered[id] = true
        count = count + 1
      else
        minetest.log("error", "[pw_schemes] could not register " .. id .. " as a structure")
      end
    end
  end
  minetest.log("action", "[pw_schemes] registered " .. count .. " schemes as structures")
  return count
end

--- Which schemes of a style can fill a planner role.
--
-- The planner's role names and the schemes' role names are not the same
-- vocabulary and should not be forced to be: `central` means the well at the
-- middle of a village, and `fishery` means a building that carries a worksite
-- contract. Only the roles that genuinely correspond are mapped, and anything
-- unmapped keeps the structure the specialization already named.
schemes.PLANNER_ROLES = {
  dwelling = "dwelling",
  storage = "storage",
  barn = "barn",
}

--- The variant list for a role in a given style, or nil to leave it alone.
function schemes.variants_for(style_id, planner_role)
  local scheme_role = schemes.PLANNER_ROLES[planner_role]
  if not scheme_role then return nil end
  local ids = schemes.for_role(style_id, scheme_role)
  if #ids == 0 then return nil end
  return ids
end
