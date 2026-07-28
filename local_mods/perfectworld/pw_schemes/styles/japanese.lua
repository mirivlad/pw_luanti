-- styles/japanese.lua
--
-- Building for rain and heat rather than for snow: shallow roofs with eaves
-- that reach far past the wall, floors lifted off wet ground, and a veranda
-- running along the front under the overhang.
--
-- The three things that carry the style are all structural rather than
-- decorative, which is why they belong in the schemes and not in a texture:
-- `raised_floor` lifts the building onto posts, `veranda` decks the strip under
-- the eaves, and the wide-eaved roof gives the long horizontal shadow that
-- makes the silhouette recognisable from a distance.
--
-- Walls are pinned to a pale material because paper-and-plaster panels are the
-- point; the timber frame is still local, so a village in a jungle and one in a
-- temperate valley share a language without sharing a colour.

local register = perfectworld.schemes.register

local function first(...)
  for _, name in ipairs({...}) do
    if minetest.registered_nodes[name] then return name end
  end
  return nil
end

perfectworld.schemes.register_style({
  id = "japanese",
  title = "Japanese",
  description = "Shallow wide-eaved roofs, raised floors, verandas, pale panelled walls.",
  biomes = {"temperate", "warm", "jungle", "wet"},
  materials = {
    -- Pale panels between the posts. Left to the palette if the game has
    -- neither, which costs the colour and keeps the shape.
    wall_primary = first("mcl_core:birchwood", "mcl_trees:wood_birch", "mcl_colorblocks:hardened_clay_white"),
    -- Dark tile, deliberately not local: a tiled roof is a manufactured thing
    -- and looks it.
    roof_stair = first("mcl_stairs:stair_dark_oak", "mcl_stairs:stair_stone"),
    roof_slab = first("mcl_stairs:slab_dark_oak", "mcl_stairs:slab_stone"),
  },
  roof = {pitch = 1, eaves = 2},
  bed_colour = "white",
})

local function scheme(id, extra)
  local base = {
    id = id,
    style = "japanese",
    plinth = false,
    posts = true,
    raised_floor = 1,
    veranda = true,
    windows = {rows = 1, spacing = 2},
    roof = {kind = "wide_eaved_gable", pitch = 1, eaves = 2},
  }
  for key, value in pairs(extra) do base[key] = value end
  return base
end

-- --- Dwellings ---------------------------------------------------------------

register(scheme("jp_minka_small", {
  title = "Small minka",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 3,
  door = {offset = 0},
  interior = {"table", "chest", "bed", "lamp"},
}))

register(scheme("jp_minka", {
  title = "Minka",
  roles = {"dwelling"},
  footprint = {w = 7, d = 9},
  wall_height = 4,
  door = {offset = 0},
  interior = {"hearth", "table", "bed", "chest", "shelf", "lamp"},
}))

register(scheme("jp_machiya", {
  title = "Machiya townhouse",
  roles = {"dwelling", "market"},
  footprint = {w = 5, d = 11},
  wall_height = 5,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  veranda = false,
  raised_floor = 0,
  interior = {"table", "shelf", "chest", "bed", "lamp"},
}))

register(scheme("jp_farmhouse", {
  title = "Farmhouse",
  roles = {"dwelling"},
  footprint = {w = 9, d = 9},
  wall_height = 4,
  door = {offset = -2},
  roof = {kind = "hip", pitch = 1, eaves = 2},
  interior = {"hearth", "table", "bed", "bed", "chest", "lamp"},
}))

register(scheme("jp_cottage_hip", {
  title = "Hipped cottage",
  roles = {"dwelling"},
  footprint = {w = 7, d = 7},
  wall_height = 3,
  door = {offset = 0},
  roof = {kind = "hip", pitch = 1, eaves = 2},
  interior = {"table", "bed", "chest", "lamp"},
}))

-- --- Working buildings -------------------------------------------------------

register(scheme("jp_kura_storehouse", {
  title = "Kura storehouse",
  roles = {"storage"},
  footprint = {w = 5, d = 5},
  wall_height = 5,
  raised_floor = 1,
  veranda = false,
  windows = {rows = 0},
  door = {offset = 0},
  roof = {kind = "hip", pitch = 1, eaves = 2},
  interior = {"barrel", "barrel", "chest", "chest"},
}))

register(scheme("jp_workshop", {
  title = "Workshop",
  roles = {"workshop", "production"},
  footprint = {w = 7, d = 7},
  wall_height = 3,
  door = {offset = 0, wide = true},
  interior = {"workbench", "chest", "table", "lamp"},
}))

register(scheme("jp_dye_house", {
  title = "Dye house",
  roles = {"workshop", "production"},
  footprint = {w = 7, d = 9},
  wall_height = 3,
  door = {offset = 0, wide = true},
  interior = {"cauldron", "loom", "barrel", "chest", "lamp"},
}))

register(scheme("jp_rice_barn", {
  title = "Rice barn",
  roles = {"barn", "storage"},
  footprint = {w = 7, d = 9},
  wall_height = 4,
  raised_floor = 2,
  veranda = false,
  windows = {rows = 0},
  door = {offset = 0, wide = true},
  interior = {"hay", "barrel", "chest"},
}))

register(scheme("jp_tea_house", {
  title = "Tea house",
  roles = {"civic"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  door = {offset = 0},
  interior = {"table", "cauldron", "shelf", "lamp"},
}))

-- --- Civic -------------------------------------------------------------------

register(scheme("jp_gatehouse", {
  title = "Gatehouse",
  roles = {"civic", "watch"},
  footprint = {w = 7, d = 5},
  wall_height = 5,
  raised_floor = 0,
  veranda = false,
  door = {offset = 0, wide = true},
  windows = {rows = 1, spacing = 2},
  roof = {kind = "wide_eaved_gable", pitch = 1, eaves = 3},
  interior = {"lamp", "chest"},
}))

register(scheme("jp_meeting_hall", {
  title = "Meeting hall",
  roles = {"civic"},
  footprint = {w = 11, d = 11},
  wall_height = 5,
  door = {offset = 0, wide = true},
  windows = {rows = 2, spacing = 2},
  roof = {kind = "hip", pitch = 1, eaves = 3},
  interior = {"table", "bench", "bench", "shelf", "lamp", "chest"},
}))
