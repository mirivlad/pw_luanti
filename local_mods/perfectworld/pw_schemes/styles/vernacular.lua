-- styles/vernacular.lua
--
-- The plain building of no particular place: timber posts, plank infill, a
-- stone plinth, glazed windows and a 45-degree gable. This is what the project
-- already built, written down as data instead of as a generator, and it is the
-- fallback style — it names no biomes, so it is at home anywhere.
--
-- Every material is left to the palette, which is the point: a vernacular
-- village is made of whatever its own forest is made of, so the same schemes
-- come out oak in a plains valley and spruce in a mountain one.

local register = perfectworld.schemes.register

perfectworld.schemes.register_style({
  id = "vernacular",
  title = "Vernacular",
  description = "Timber-framed cottages under 45-degree gables. Local wood, local stone.",
  -- No `materials` and no `biomes`: the palette decides, and it fits anywhere.
  roof = {pitch = 1, eaves = 1},
  bed_colour = "red",
})

local function scheme(id, extra)
  local base = {
    id = id,
    style = "vernacular",
    plinth = true,
    posts = true,
    windows = {rows = 1, spacing = 2},
    roof = {kind = "gable", pitch = 1, eaves = 1},
  }
  for key, value in pairs(extra) do base[key] = value end
  return base
end

-- --- Dwellings ---------------------------------------------------------------

register(scheme("vern_cottage_small", {
  title = "Small cottage",
  roles = {"dwelling"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "lamp"},
}))

register(scheme("vern_cottage_wide", {
  title = "Wide cottage",
  roles = {"dwelling"},
  footprint = {w = 7, d = 5},
  wall_height = 3,
  door = {offset = -1},
  interior = {"bed", "chest", "table", "bench", "lamp"},
}))

register(scheme("vern_house_tall", {
  title = "Two-storey house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 5,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  interior = {"bed", "chest", "table", "shelf", "lamp"},
}))

register(scheme("vern_house_long", {
  title = "Long house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 9},
  wall_height = 4,
  door = {offset = 0},
  interior = {"bed", "bed", "chest", "table", "bench", "lamp"},
}))

register(scheme("vern_cottage_corner", {
  title = "Corner cottage",
  roles = {"dwelling"},
  footprint = {w = 7, d = 7},
  wall_height = 4,
  door = {offset = 2},
  roof = {kind = "hip", pitch = 1, eaves = 1},
  interior = {"bed", "chest", "table", "shelf", "lamp"},
}))

-- --- Working buildings -------------------------------------------------------

register(scheme("vern_barn", {
  title = "Barn",
  roles = {"barn", "storage"},
  footprint = {w = 7, d = 9},
  wall_height = 5,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  interior = {"hay", "barrel", "chest", "lamp"},
}))

register(scheme("vern_granary", {
  title = "Granary",
  roles = {"storage"},
  footprint = {w = 5, d = 5},
  wall_height = 4,
  raised_floor = 1,
  door = {offset = 0},
  windows = {rows = 0},
  interior = {"barrel", "barrel", "chest"},
}))

register(scheme("vern_workshop", {
  title = "Workshop",
  roles = {"workshop", "production", "sawmill"},
  footprint = {w = 7, d = 7},
  wall_height = 4,
  door = {offset = 0, wide = true},
  interior = {"workbench", "chest", "anvil", "lamp"},
}))

register(scheme("vern_smithy", {
  title = "Smithy",
  roles = {"workshop", "production", "mine_workshop"},
  footprint = {w = 5, d = 7},
  wall_height = 4,
  door = {offset = 0, wide = true},
  roof = {kind = "pent", pitch = 1, eaves = 1},
  interior = {"anvil", "hearth", "chest", "workbench", "lamp"},
}))

register(scheme("vern_bakehouse", {
  title = "Bakehouse",
  roles = {"workshop", "production"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  door = {offset = 0},
  interior = {"hearth", "table", "chest", "lamp"},
}))

register(scheme("vern_stable", {
  title = "Stable",
  roles = {"barn"},
  footprint = {w = 7, d = 7},
  wall_height = 4,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  interior = {"hay", "hay", "barrel"},
}))

register(scheme("vern_shed", {
  title = "Shed",
  roles = {"storage"},
  footprint = {w = 3, d = 5},
  wall_height = 3,
  door = {offset = 0},
  windows = {rows = 0},
  roof = {kind = "pent", pitch = 1, eaves = 1},
  interior = {"barrel", "chest"},
}))

-- --- Civic -------------------------------------------------------------------

register(scheme("vern_hall", {
  title = "Village hall",
  roles = {"civic"},
  footprint = {w = 9, d = 11},
  wall_height = 6,
  door = {offset = 0, wide = true},
  windows = {rows = 2, spacing = 2},
  roof = {kind = "hip", pitch = 1, eaves = 1},
  interior = {"table", "bench", "bench", "shelf", "lamp", "chest"},
}))

register(scheme("vern_market_stall", {
  title = "Market stall",
  roles = {"civic", "market"},
  footprint = {w = 5, d = 5},
  wall_height = 2,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  posts = true,
  plinth = false,
  roof = {kind = "pent", pitch = 1, eaves = 2},
  interior = {"table", "barrel"},
}))

register(scheme("vern_watchtower", {
  title = "Watchtower",
  roles = {"civic", "watch"},
  footprint = {w = 5, d = 5},
  wall_height = 8,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  roof = {kind = "flat", eaves = 1, parapet = true},
  interior = {"lamp", "chest"},
}))
