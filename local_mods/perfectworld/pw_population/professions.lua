-- pw_population/professions.lua
--
-- Trades this world has that Mineclonia does not.
--
-- Nothing here is copied. `mobs_mc.register_villager` is a public entry point:
-- a profession is a name, a point-of-interest id, the workstation node it
-- claims, a texture, a trade list and a gift list. Everything a villager then
-- does with it — finding the workstation, claiming it, walking to it on a
-- schedule, working, trading, going home to bed — is the game's own behaviour,
-- generic over the profession, and it applies to ours exactly as to its own.
--
-- Two are added, and they are added for different reasons.
--
--   miner       Mineclonia has a mason who cuts stone and a toolsmith who
--               works iron, and nobody who goes and gets it. A world whose
--               settlements are sited on measured ore should have somebody
--               whose living is ore.
--
--   caravaneer  The roads between settlements exist and nothing uses them.
--
-- Be clear about what the caravaneer is and is not, today. Registering the
-- profession gives a villager who claims a loading stage, works at it and
-- trades the goods of other places. It does **not** give a villager who walks
-- to the next town with a load: that is new behaviour, not a new profession,
-- and it is not written yet. `mcl_mobs` has `gopath`, and the polylines of the
-- settlement links are the waypoints it would need, so the road is open — but
-- claiming the profession works today and the journey does not.

local population = perfectworld.population

--- Our own workstation nodes.
--
-- Registered rather than borrowed. Every node the game uses as a workstation is
-- already spoken for by one of its own professions, so reusing one would mean
-- two trades competing for the same block, and whichever villager arrived first
-- would decide what the building was for.
local WORKSTATIONS = {
  {
    name = "pw_population:ore_table",
    description = "Ore Sorting Table",
    tiles = {"default_stone.png", "default_stone.png", "mcl_core_coarse_dirt.png"},
  },
  {
    name = "pw_population:loading_stage",
    description = "Loading Stage",
    tiles = {"default_wood.png", "default_wood.png", "mcl_core_coarse_dirt.png"},
  },
}

local function register_workstations()
  for _, station in ipairs(WORKSTATIONS) do
    -- Textures are borrowed from the game's own atlas on purpose: a node that
    -- cannot find its texture renders as an unmissable placeholder, and a
    -- borrowed stone face is a better lie than a magenta cube while these are
    -- still new.
    minetest.register_node(station.name, {
      description = station.description,
      tiles = station.tiles,
      groups = {
        handy = 1, axey = 1, pickaxey = 1,
        material_wood = 1, deco_block = 1,
        -- The group a villager's node search runs over. Naming it here is what
        -- makes the search cheap: the game resolves the group into a node list
        -- once, after every mod has loaded.
        [station.name:gsub("^pw_population:", "pw_job_")] = 1,
      },
      _mcl_hardness = 2.5,
      _mcl_blast_resistance = 2.5,
    })
  end
end

--- Emeralds, the way the game's own trade lists write them.
local function emeralds(count)
  count = count or 1
  return {"mcl_core:emerald", count, count}
end

local function nothing()
  return {"", 0, 0}
end

--- What each new trade buys and sells.
--
-- Modelled on the shape of the game's own lists — a want, a give, a use count
-- and an experience value — and on its economy: raw material in at the bottom
-- tiers, worked goods out at the top.
local TRADES = {
  miner = {
    {
      {{"mcl_core:coal_lump", 15, 15}, emeralds(), 16, 2},
      {{"mcl_core:iron_ingot", 4, 4}, emeralds(), 16, 2},
      {emeralds(), {"mcl_torches:torch", 12, 12}, 16, 1},
    },
    {
      {{"mcl_core:gold_ingot", 3, 3}, emeralds(), 12, 10},
      {emeralds(2), {"mcl_tools:pick_iron", 1, 1}, 12, 5},
    },
    {
      {{"mcl_core:lapis", 6, 6}, emeralds(), 12, 20},
      {emeralds(4), {"mcl_core:iron_ingot", 4, 4}, 12, 10},
    },
    {
      {emeralds(8), {"mcl_core:diamond", 1, 1}, 6, 15},
    },
    {
      {emeralds(12), {"mcl_tools:pick_diamond", 1, 1}, 4, 30},
    },
  },
  caravaneer = {
    {
      {{"mcl_farming:wheat_item", 20, 20}, emeralds(), 16, 2},
      {emeralds(), {"mcl_core:paper", 12, 12}, 16, 1},
    },
    {
      {emeralds(2), {"mcl_farming:bread", 6, 6}, 12, 5},
      {{"mcl_mobitems:leather", 6, 6}, emeralds(), 12, 10},
    },
    {
      -- The goods of somewhere else, which is the whole point of the trade.
      {emeralds(3), {"mcl_ocean:kelp", 8, 8}, 12, 10},
      {emeralds(3), {"mcl_core:cactus", 6, 6}, 12, 10},
    },
    {
      {emeralds(5), {"mcl_minecarts:minecart", 1, 1}, 6, 15},
    },
    {
      {emeralds(6), {"mcl_mobitems:saddle", 1, 1}, 4, 30},
    },
  },
}

--- What a villager of each trade will accept as a gift.
local GIFTS = {
  miner = {{"mcl_core:coal_lump", 4, 4}},
  caravaneer = {{"mcl_core:paper", 4, 4}},
}

--- The professions themselves.
local PROFESSIONS = {
  {
    name = "miner",
    description = "Miner",
    poi = "pw_population:miner",
    workstation = "pw_population:ore_table",
    -- Borrowed for now: the mason is the nearest thing the game draws, and a
    -- villager in the wrong coat is better than a villager with no texture.
    texture = "mobs_mc_villager_profession_mason.png",
    extra_pick_up = {"mcl_core:coal_lump", "mcl_core:iron_ingot"},
  },
  {
    name = "caravaneer",
    description = "Caravaneer",
    poi = "pw_population:caravaneer",
    workstation = "pw_population:loading_stage",
    texture = "mobs_mc_villager_profession_cartographer.png",
    extra_pick_up = {"mcl_farming:wheat_item", "mcl_core:paper"},
  },
}

population.CUSTOM_PROFESSIONS = {}
for _, profession in ipairs(PROFESSIONS) do
  population.CUSTOM_PROFESSIONS[profession.name] = profession
end

--- Register everything, if this game is one that can take it.
function population.register_professions()
  if not mobs_mc or type(mobs_mc.register_villager) ~= "function" then
    minetest.log("warning",
      "[pw_population] this game has no villager profession API; "
        .. "the miner and the caravaneer are not registered")
    return 0
  end

  register_workstations()

  local registered = 0
  for _, profession in ipairs(PROFESSIONS) do
    local group = profession.workstation:gsub("^pw_population:", "pw_job_")
    mobs_mc.register_villager({
      description = profession.description,
      name = profession.name,
      poi = profession.poi,
      group = "group:" .. group,
      texture = profession.texture,
      extra_pick_up = profession.extra_pick_up,
    }, {
      -- The point-of-interest definition, in the shape the game's own use.
      -- `ignore` counts as valid: a claim made in a mapblock that has since
      -- been unloaded must survive until somebody can look at it again.
      is_valid = function(nodepos)
        local node = minetest.get_node(nodepos)
        return node.name == "ignore" or node.name == profession.workstation
      end,
      village_center = true,
    }, TRADES[profession.name], GIFTS[profession.name])
    registered = registered + 1
  end

  minetest.log("action", "[pw_population] registered " .. registered
    .. " profession(s) this game did not have")
  return registered
end
