-- styles/nordic.lua
--
-- Building for snow and wind: steep roofs that shed their load, few and small
-- windows, heavy timber, long halls rather than square cottages.
--
-- The style pins two materials and leaves the rest to the palette. The roof is
-- turf, because a turf roof is the single most recognisable thing about this
-- architecture and a spruce-planked one would read as any other cold-climate
-- village. Walls stay local wood, so a longhouse in a taiga and one on a tundra
-- edge are still made of what grows there.
--
-- Pitch 2 means the roof climbs two nodes for every node it steps inward: a
-- silhouette that sheds snow instead of collecting it.

local register = perfectworld.schemes.register

local function turf()
  for _, name in ipairs({"mcl_core:dirt_with_grass", "mcl_core:dirt"}) do
    if minetest.registered_nodes[name] then return name end
  end
  return nil
end

perfectworld.schemes.register_style({
  id = "nordic",
  title = "Nordic",
  description = "Steep turf roofs, long halls, heavy timber, small windows.",
  biomes = {"cold", "taiga", "tundra", "snowy", "mountain"},
  materials = {
    -- Left unset when the game has no turf: the palette then supplies a roof
    -- and the buildings simply lose their most distinctive feature rather than
    -- failing to build.
    roof_slab = turf(),
  },
  roof = {pitch = 2, eaves = 1},
  bed_colour = "brown",
})

local function scheme(id, extra)
  local base = {
    id = id,
    style = "nordic",
    plinth = true,
    posts = true,
    windows = {rows = 1, spacing = 3},
    roof = {kind = "gable", pitch = 2, eaves = 1},
  }
  for key, value in pairs(extra) do base[key] = value end
  return base
end

-- --- Dwellings ---------------------------------------------------------------

register(scheme("nord_longhouse", {
  title = "Longhouse",
  roles = {"dwelling", "civic"},
  footprint = {w = 7, d = 13},
  wall_height = 4,
  door = {offset = 0},
  interior = {"hearth", "bed", "bed", "bench", "bench", "chest", "table", "lamp"},
}))

register(scheme("nord_longhouse_small", {
  title = "Small longhouse",
  roles = {"dwelling"},
  footprint = {w = 5, d = 9},
  wall_height = 3,
  door = {offset = 0},
  interior = {"hearth", "bed", "chest", "bench", "lamp"},
}))

register(scheme("nord_turf_cottage", {
  title = "Turf cottage",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 3,
  door = {offset = 0},
  windows = {rows = 1, spacing = 4},
  interior = {"hearth", "bed", "chest", "lamp"},
}))

register(scheme("nord_pit_house", {
  title = "Pit house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 5},
  wall_height = 2,
  door = {offset = 0},
  windows = {rows = 0},
  roof = {kind = "gable", pitch = 2, eaves = 2},
  interior = {"hearth", "bed", "chest"},
}))

register(scheme("nord_stave_house", {
  title = "Stave house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 5,
  door = {offset = 0},
  windows = {rows = 2, spacing = 3},
  interior = {"bed", "chest", "shelf", "table", "lamp"},
}))

-- --- Working buildings -------------------------------------------------------

register(scheme("nord_boathouse", {
  title = "Boathouse",
  roles = {"workshop", "production", "storage"},
  footprint = {w = 7, d = 11},
  wall_height = 4,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  interior = {"barrel", "chest", "workbench", "lamp"},
}))

register(scheme("nord_smokehouse", {
  title = "Smokehouse",
  roles = {"workshop", "production"},
  footprint = {w = 5, d = 5},
  wall_height = 4,
  door = {offset = 0},
  windows = {rows = 0},
  roof = {kind = "gable", pitch = 2, eaves = 1},
  interior = {"hearth", "barrel", "chest"},
}))

register(scheme("nord_storehouse", {
  title = "Raised storehouse",
  roles = {"storage"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  raised_floor = 2,
  door = {offset = 0},
  windows = {rows = 0},
  interior = {"barrel", "barrel", "chest"},
}))

register(scheme("nord_forge", {
  title = "Forge",
  roles = {"workshop", "production"},
  footprint = {w = 7, d = 7},
  wall_height = 4,
  door = {offset = 0, wide = true},
  windows = {rows = 1, spacing = 3},
  interior = {"anvil", "hearth", "chest", "workbench", "lamp"},
}))

register(scheme("nord_byre", {
  title = "Byre",
  roles = {"barn"},
  footprint = {w = 7, d = 9},
  wall_height = 3,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  interior = {"hay", "hay", "barrel"},
}))

-- --- Civic -------------------------------------------------------------------

register(scheme("nord_mead_hall", {
  title = "Mead hall",
  roles = {"civic"},
  footprint = {w = 9, d = 15},
  wall_height = 6,
  door = {offset = 0, wide = true},
  windows = {rows = 1, spacing = 3},
  interior = {"hearth", "table", "bench", "bench", "bench", "chest", "lamp", "shelf"},
}))

register(scheme("nord_watchpost", {
  title = "Watchpost",
  roles = {"civic", "watch"},
  footprint = {w = 5, d = 5},
  wall_height = 7,
  raised_floor = 1,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  roof = {kind = "gable", pitch = 2, eaves = 1},
  interior = {"lamp", "chest"},
}))
