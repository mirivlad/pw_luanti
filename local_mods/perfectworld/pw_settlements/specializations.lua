-- Pure domain definitions and scoring for physical village specializations.

local settlements = perfectworld.settlements
local deep_copy = perfectworld.core.deep_copy

settlements.SPECIALIZATION_VERSION = 1

local shared_variants = {
  dwelling = {
    "pw_house_small_v1",
    "pw_house_small_v2",
    "pw_house_long_v1",
    "pw_house_tall_v1",
  },
  central = {"pw_well_v1"},
}

local definitions = {
  fishing = {
    required_role_counts = {dwelling = 2, fishery = 1},
    optional_roles = {"storage", "central", "dwelling"},
    role_variants = {
      fishery = {"pw_fishery_v1"},
      storage = {"pw_barn_v1"},
    },
    resource_features = {"fish", "smoking", "boatwork"},
    required_worksite = "dock",
  },
  farming = {
    required_role_counts = {dwelling = 2, farm = 1},
    optional_roles = {"barn", "central", "dwelling"},
    role_variants = {
      farm = {"pw_farmstead_v1"},
      barn = {"pw_barn_v1"},
    },
    resource_features = {"crops", "livestock", "hay"},
    required_worksite = "field",
  },
  forestry = {
    required_role_counts = {dwelling = 2, sawmill = 1},
    optional_roles = {"apiary", "storage", "central", "dwelling"},
    role_variants = {
      sawmill = {"pw_sawmill_v1"},
      apiary = {"pw_sawmill_v1"},
      storage = {"pw_barn_v1"},
    },
    resource_features = {"lumber", "honey", "game", "hides"},
    required_worksite = "forestry_yard",
  },
  mining = {
    required_role_counts = {dwelling = 2, mine_workshop = 1},
    optional_roles = {"storage", "central", "dwelling"},
    role_variants = {
      mine_workshop = {"pw_mine_workshop_v1"},
      storage = {"pw_barn_v1"},
    },
    resource_features = {"stone", "ore", "gems"},
    required_worksite = "minehead",
  },
}

--- What people in a settlement of each kind do for a living.
--
-- A settlement's specialization is already decided from physical evidence —
-- water, soil, trees, stone — so the trades follow from the land rather than
-- being assigned. A fishing village fills with fishermen and fletchers because
-- that is what a place on a shore with wood behind it supports.
--
-- Each name is a Mineclonia profession, and each maps to the workstation node
-- that profession claims. Listing them here rather than in the building
-- catalogue keeps the question "what does this settlement do" in one place.
local trades = {
  fishing  = {"fisherman", "fisherman", "fletcher", "cartographer", "leatherworker"},
  farming  = {"farmer", "farmer", "shepherd", "butcher", "librarian"},
  forestry = {"fletcher", "shepherd", "librarian", "leatherworker", "farmer"},
  -- `miner` is this project's own profession, not one of the game's. A world
  -- whose settlements are sited on measured ore should have somebody whose
  -- living is ore, and Mineclonia has a mason who cuts stone and a toolsmith
  -- who works iron and nobody who goes and gets it.
  mining   = {"miner", "miner", "mason", "toolsmith", "weaponsmith", "armorer"},
}

--- Trades that only a town is large enough to support.
--
-- A hamlet does not have a caravan. Somebody whose living is carrying other
-- places' goods needs somewhere those goods are worth carrying to.
local town_trades = {"caravaneer", "cartographer", "librarian"}

--- The trades a settlement of this kind offers, in a fixed order.
--
-- Repeats are deliberate: a fishing village should be mostly fishermen, and
-- weighting by repetition keeps the choice a plain indexed pick rather than a
-- second scoring system.
function settlements.trades_for(specialization, opts)
  local list = deep_copy(trades[specialization] or trades.farming)
  if opts and opts.town then
    for _, trade in ipairs(town_trades) do list[#list + 1] = trade end
  end
  return list
end

--- The material role of the workstation a trade claims.
function settlements.workstation_for(trade)
  return "job_" .. tostring(trade)
end

local function definition_copy(id)
  local definition = definitions[id]
  if not definition then return nil end
  local result = deep_copy(definition)
  result.id = id
  result.role_variants = result.role_variants or {}
  for role, variants in pairs(shared_variants) do
    if not result.role_variants[role] then
      result.role_variants[role] = deep_copy(variants)
    end
  end
  return result
end

function settlements.get_specialization(id)
  return definition_copy(id)
end

function settlements.list_specializations()
  local ids = {}
  for id in pairs(definitions) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function unit(value)
  return clamp(tonumber(value) or 0, 0, 1)
end

local function result(id, viable, score, reasons)
  return {
    id = id,
    viable = viable and true or false,
    score = clamp(score, 0, 1),
    reasons = reasons,
    definition = definition_copy(id),
  }
end

local function fishing(evidence)
  local shore = tonumber(evidence.shore_distance)
  local water = unit(evidence.water_ratio)
  local buildable = unit(evidence.buildable_ratio)
  local reasons = {}
  if not shore or shore > 30 then reasons[#reasons + 1] = "shore_distance" end
  if water < 0.08 then reasons[#reasons + 1] = "water_ratio" end
  if buildable < 0.55 then reasons[#reasons + 1] = "buildable_ratio" end
  local shore_term = shore and clamp(1 - shore / 30, 0, 1) or 0
  local water_term = clamp(water / 0.35, 0, 1)
  local family_bonus = evidence.biome_family == "coastal" and 1 or 0
  return result("fishing", #reasons == 0,
    shore_term * 0.45 + water_term * 0.25 + buildable * 0.20
      + family_bonus * 0.10,
    reasons)
end

local function farming(evidence)
  local soil = unit(evidence.soil_ratio)
  local buildable = unit(evidence.buildable_ratio)
  local roughness = math.max(tonumber(evidence.roughness) or 0, 0)
  local reasons = {}
  if soil < 0.60 then reasons[#reasons + 1] = "soil_ratio" end
  if buildable < 0.70 then reasons[#reasons + 1] = "buildable_ratio" end
  if roughness > 3.5 then reasons[#reasons + 1] = "roughness" end
  local family = evidence.biome_family
  local family_bonus = (family == "temperate" or family == "dry"
    or family == "cold") and 1 or 0
  return result("farming", #reasons == 0,
    soil * 0.40 + buildable * 0.25
      + clamp(1 - roughness / 3.5, 0, 1) * 0.25
      + family_bonus * 0.10,
    reasons)
end

local function forestry(evidence)
  local trees = unit(evidence.tree_ratio)
  local buildable = unit(evidence.buildable_ratio)
  local humidity = unit(evidence.humidity)
  local reasons = {}
  if trees < 0.18 then reasons[#reasons + 1] = "tree_ratio" end
  if buildable < 0.45 then reasons[#reasons + 1] = "buildable_ratio" end
  local family = evidence.biome_family
  local family_bonus = (family == "forest" or family == "cold"
    or family == "wet") and 1 or 0
  return result("forestry", #reasons == 0,
    clamp(trees / 0.60, 0, 1) * 0.50 + buildable * 0.20
      + humidity * 0.15 + family_bonus * 0.15,
    reasons)
end

local function mining(evidence)
  local stone = unit(evidence.exposed_stone_ratio)
  local buildable = unit(evidence.buildable_ratio)
  local roughness = math.max(tonumber(evidence.roughness) or 0, 0)
  local rocky_relief = evidence.biome_family == "rocky" and roughness >= 2
  local reasons = {}
  if buildable < 0.45 then reasons[#reasons + 1] = "buildable_ratio" end
  if stone < 0.12 and not rocky_relief then
    reasons[#reasons + 1] = "stone_or_rocky_relief"
  end
  local family_bonus = evidence.biome_family == "rocky" and 1 or 0
  return result("mining", #reasons == 0,
    clamp(stone / 0.60, 0, 1) * 0.40
      + clamp(roughness / 8, 0, 1) * 0.25
      + buildable * 0.20 + family_bonus * 0.15,
    reasons)
end

function settlements.evaluate_specializations(evidence)
  evidence = evidence or {}
  local ranked = {
    fishing(evidence),
    farming(evidence),
    forestry(evidence),
    mining(evidence),
  }
  table.sort(ranked, function(a, b)
    if a.viable ~= b.viable then return a.viable end
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)
  return ranked
end
