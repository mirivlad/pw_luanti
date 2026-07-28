-- styles/urban.lua
--
-- Town buildings: two, three and four storeys, stone below and timber above.
--
-- Not a regional style like the others. `urban` is a *size* of building rather
-- than a place's way of building, so these schemes are marked `urban = true`
-- and are drawn on by a settlement that is a town, whatever style the region
-- otherwise gave it. A town in the north still builds the way the north builds;
-- it just builds taller, and puts stone under the timber.
--
-- Stone under timber is not decoration. It is what the bottom of a tall
-- building does, in every place that has ever built one, because the bottom
-- carries the rest — and it is the single thing that stops a four-storey plank
-- box from reading as a four-storey plank box.

local register = perfectworld.schemes.register

perfectworld.schemes.register_style({
  id = "urban",
  title = "Town",
  description = "Two to four storeys, stone ground floor, timber above, steep roofs.",
  roof = {pitch = 1, eaves = 1},
  bed_colour = "red",
})

local function townhouse(id, options)
  local base = {
    id = id,
    style = "urban",
    urban = true,
    roles = {"dwelling"},
    plinth = true,
    posts = true,
    stone_ground_floor = true,
    windows = {rows = 1, spacing = 2},
    roof = {kind = "gable", pitch = 1, eaves = 1},
  }
  for key, value in pairs(options) do
    if key ~= "roof" then base[key] = value end
  end
  base.roof = {kind = options.roof or "gable", pitch = 1, eaves = 1}
  return base
end

-- === Two storeys: the ordinary town house ===

register(townhouse("urban_house_two", {
  title = "Two-storey town house",
  footprint = {w = 5, d = 7},
  wall_height = 3,
  storeys = 2,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "lamp", "workstation"},
}))

register(townhouse("urban_house_two_wide", {
  title = "Wide two-storey town house",
  footprint = {w = 7, d = 7},
  wall_height = 3,
  storeys = 2,
  door = {offset = -1},
  interior = {"bed", "bed", "chest", "table", "bench", "lamp", "workstation"},
}))

-- === Three storeys ===

register(townhouse("urban_house_three", {
  title = "Three-storey town house",
  footprint = {w = 5, d = 7},
  wall_height = 3,
  storeys = 3,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "shelf", "lamp", "workstation"},
}))

register(townhouse("urban_house_three_narrow", {
  title = "Narrow three-storey house",
  footprint = {w = 5, d = 5},
  wall_height = 3,
  storeys = 3,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "lamp", "workstation"},
}))

-- === Four storeys: the tallest thing in the place ===

register(townhouse("urban_tower_four", {
  title = "Four-storey town house",
  footprint = {w = 5, d = 5},
  wall_height = 3,
  storeys = 4,
  door = {offset = 0},
  -- A tall narrow building is somebody's whole holding: workshop at the bottom,
  -- rooms above.
  interior = {"bed", "chest", "table", "shelf", "lamp", "workstation"},
}))

register(townhouse("urban_tower_four_hip", {
  title = "Four-storey house under a hip roof",
  footprint = {w = 7, d = 7},
  wall_height = 3,
  storeys = 4,
  roof = "hip",
  door = {offset = -1},
  interior = {"bed", "bed", "chest", "table", "bench", "shelf", "lamp", "workstation"},
}))

-- === Trades that only a town supports ===

register(townhouse("urban_workshop_two", {
  title = "Two-storey workshop",
  roles = {"storage"},
  footprint = {w = 7, d = 7},
  wall_height = 4,
  storeys = 2,
  door = {offset = 0, wide = true},
  interior = {"workbench", "chest", "barrel", "lamp"},
}))
