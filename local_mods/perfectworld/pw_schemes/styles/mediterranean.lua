-- styles/mediterranean.lua
--
-- Building for heat and drought: thick pale walls that hold the night's cool,
-- flat roofs used as terraces, small windows that keep the sun out, and stone
-- rather than timber because there is not much timber.
--
-- The flat roof is the whole silhouette. Where a nordic village is a row of
-- steep triangles against the sky, this one is a stack of cubes with parapets,
-- and the difference is visible from further away than any texture.

local register = perfectworld.schemes.register

local function first(...)
  for _, name in ipairs({...}) do
    if minetest.registered_nodes[name] then return name end
  end
  return nil
end

perfectworld.schemes.register_style({
  id = "mediterranean",
  title = "Mediterranean",
  description = "Pale stone, flat terraced roofs, deep small windows, stacked cubes.",
  biomes = {"desert", "savanna", "warm", "dry", "mesa"},
  materials = {
    wall_primary = first("mcl_colorblocks:hardened_clay_white",
                         "mcl_core:sandstonesmooth", "mcl_core:sandstone"),
    wall_secondary = first("mcl_core:sandstone", "mcl_core:stone"),
    roof_slab = first("mcl_stairs:slab_sandstone", "mcl_stairs:slab_stone"),
    roof_stair = first("mcl_stairs:stair_sandstone", "mcl_stairs:stair_stone"),
  },
  roof = {pitch = 1, eaves = 0},
  bed_colour = "white",
})

local function scheme(id, extra)
  local base = {
    id = id,
    style = "mediterranean",
    plinth = true,
    posts = false,
    windows = {rows = 1, spacing = 3},
    roof = {kind = "flat", eaves = 0, parapet = true},
  }
  for key, value in pairs(extra) do base[key] = value end
  return base
end

-- --- Dwellings ---------------------------------------------------------------

register(scheme("med_courtyard_house", {
  title = "Courtyard house",
  roles = {"dwelling"},
  footprint = {w = 9, d = 9},
  wall_height = 4,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "cauldron", "lamp"},
}))

register(scheme("med_cube_house", {
  title = "Cube house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 5},
  wall_height = 4,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "lamp"},
}))

register(scheme("med_terrace_house", {
  title = "Terrace house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 9},
  wall_height = 6,
  door = {offset = 0},
  windows = {rows = 2, spacing = 3},
  interior = {"bed", "bed", "chest", "table", "shelf", "lamp"},
}))

register(scheme("med_tower_house", {
  title = "Tower house",
  roles = {"dwelling", "watch"},
  footprint = {w = 5, d = 5},
  wall_height = 8,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  interior = {"bed", "chest", "shelf", "lamp"},
}))

register(scheme("med_row_house", {
  title = "Row house",
  roles = {"dwelling", "market"},
  footprint = {w = 5, d = 7},
  wall_height = 5,
  door = {offset = 0},
  windows = {rows = 2, spacing = 2},
  interior = {"bed", "chest", "table", "lamp"},
}))

-- --- Working buildings -------------------------------------------------------

register(scheme("med_press_house", {
  title = "Press house",
  roles = {"workshop", "production"},
  footprint = {w = 7, d = 9},
  wall_height = 4,
  door = {offset = 0, wide = true},
  interior = {"barrel", "barrel", "cauldron", "chest", "workbench"},
}))

register(scheme("med_kiln", {
  title = "Kiln",
  roles = {"workshop", "production"},
  footprint = {w = 5, d = 5},
  wall_height = 5,
  door = {offset = 0},
  windows = {rows = 0},
  interior = {"hearth", "chest", "barrel"},
}))

register(scheme("med_cistern", {
  title = "Cistern house",
  roles = {"storage", "civic"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  door = {offset = 0},
  windows = {rows = 0},
  interior = {"cauldron", "barrel"},
}))

register(scheme("med_granary", {
  title = "Granary",
  roles = {"storage"},
  footprint = {w = 7, d = 7},
  wall_height = 5,
  door = {offset = 0, wide = true},
  windows = {rows = 0},
  interior = {"barrel", "barrel", "hay", "chest"},
}))

-- --- Civic -------------------------------------------------------------------

register(scheme("med_market_hall", {
  title = "Market hall",
  roles = {"civic", "market"},
  footprint = {w = 11, d = 9},
  wall_height = 5,
  door = {offset = 0, wide = true},
  windows = {rows = 2, spacing = 2},
  interior = {"table", "table", "barrel", "chest", "bench", "lamp"},
}))

register(scheme("med_bath_house", {
  title = "Bath house",
  roles = {"civic"},
  footprint = {w = 9, d = 7},
  wall_height = 4,
  door = {offset = 0, wide = true},
  windows = {rows = 1, spacing = 3},
  interior = {"cauldron", "cauldron", "bench", "lamp"},
}))
