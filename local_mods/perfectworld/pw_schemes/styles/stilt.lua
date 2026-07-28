-- styles/stilt.lua
--
-- Building over water, or over ground that is water half the year: everything
-- stands on posts, nothing has a plinth, and the walkway matters as much as the
-- house because there is no street.
--
-- The planner already knows how to want a fishing village — it measures shore
-- and open water and refuses to site one without them. What it did not have was
-- anywhere for that village to live that looked like it belonged over water.
-- Every scheme here is raised, so the shore geometry the ecology survey insists
-- on finding is finally worth finding.
--
-- Roofs are light: a shallow pent or gable in thatch and plank, because a heavy
-- roof on stilts is a bad idea in any architecture.

local register = perfectworld.schemes.register

local function first(...)
  for _, name in ipairs({...}) do
    if minetest.registered_nodes[name] then return name end
  end
  return nil
end

perfectworld.schemes.register_style({
  id = "stilt",
  title = "Stilt",
  description = "Houses on posts over shallow water, light roofs, walkways instead of streets.",
  biomes = {"wet", "coastal"},
  materials = {
    -- Thatch where the game has it. It reads as light and cheap, which is what
    -- a roof carried on posts over water has to be.
    roof_slab = first("mcl_stairs:slab_hay_block", "mcl_stairs:slab_oak"),
    roof_stair = first("mcl_stairs:stair_hay_block", "mcl_stairs:stair_oak"),
  },
  roof = {pitch = 1, eaves = 2},
  bed_colour = "green",
})

local function scheme(id, extra)
  local base = {
    id = id,
    style = "stilt",
    plinth = false,
    posts = true,
    raised_floor = 2,
    veranda = true,
    windows = {rows = 1, spacing = 2},
    roof = {kind = "gable", pitch = 1, eaves = 2},
  }
  for key, value in pairs(extra) do base[key] = value end
  return base
end

-- --- Dwellings ---------------------------------------------------------------

register(scheme("stilt_hut", {
  title = "Stilt hut",
  roles = {"dwelling"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  door = {offset = 0},
  interior = {"bed", "chest", "lamp"},
}))

register(scheme("stilt_house", {
  title = "Stilt house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 3,
  door = {offset = 0},
  interior = {"bed", "chest", "table", "lamp"},
}))

register(scheme("stilt_long_house", {
  title = "Long stilt house",
  roles = {"dwelling"},
  footprint = {w = 7, d = 11},
  wall_height = 4,
  door = {offset = 0},
  interior = {"bed", "bed", "chest", "table", "bench", "lamp"},
}))

register(scheme("stilt_high_house", {
  title = "High stilt house",
  roles = {"dwelling"},
  footprint = {w = 5, d = 7},
  wall_height = 4,
  raised_floor = 3,
  windows = {rows = 2, spacing = 2},
  door = {offset = 0},
  interior = {"bed", "chest", "shelf", "table", "lamp"},
}))

-- --- Working buildings -------------------------------------------------------

register(scheme("stilt_fish_house", {
  title = "Fish house",
  roles = {"workshop", "production"},
  footprint = {w = 7, d = 9},
  wall_height = 3,
  door = {offset = 0, wide = true},
  interior = {"barrel", "barrel", "chest", "workbench", "lamp"},
}))

register(scheme("stilt_smokehouse", {
  title = "Smokehouse",
  roles = {"workshop", "production"},
  footprint = {w = 5, d = 5},
  wall_height = 4,
  windows = {rows = 0},
  door = {offset = 0},
  interior = {"hearth", "barrel", "chest"},
}))

register(scheme("stilt_net_store", {
  title = "Net store",
  roles = {"storage"},
  footprint = {w = 5, d = 7},
  wall_height = 3,
  windows = {rows = 0},
  door = {offset = 0, wide = true},
  roof = {kind = "pent", pitch = 1, eaves = 2},
  interior = {"barrel", "chest", "chest"},
}))

register(scheme("stilt_boat_shed", {
  title = "Boat shed",
  roles = {"storage", "workshop"},
  footprint = {w = 7, d = 11},
  wall_height = 3,
  raised_floor = 1,
  windows = {rows = 0},
  door = {offset = 0, wide = true},
  roof = {kind = "pent", pitch = 1, eaves = 2},
  interior = {"workbench", "barrel", "chest"},
}))

register(scheme("stilt_drying_rack", {
  title = "Drying rack house",
  roles = {"production"},
  footprint = {w = 5, d = 9},
  wall_height = 2,
  windows = {rows = 0},
  door = {offset = 0, wide = true},
  roof = {kind = "pent", pitch = 1, eaves = 2},
  interior = {"barrel", "chest"},
}))

-- --- Civic -------------------------------------------------------------------

register(scheme("stilt_moot_house", {
  title = "Moot house",
  roles = {"civic"},
  footprint = {w = 9, d = 11},
  wall_height = 4,
  raised_floor = 2,
  door = {offset = 0, wide = true},
  interior = {"table", "bench", "bench", "chest", "shelf", "lamp"},
}))

register(scheme("stilt_watch_hut", {
  title = "Watch hut",
  roles = {"civic", "watch"},
  footprint = {w = 5, d = 5},
  wall_height = 3,
  raised_floor = 4,
  windows = {rows = 1, spacing = 2},
  door = {offset = 0},
  interior = {"lamp", "chest"},
}))
