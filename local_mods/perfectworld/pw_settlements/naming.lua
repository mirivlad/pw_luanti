-- pw_settlements/naming.lua
--
-- What a place is called.
--
-- Names are built the way every other decision in this world is built: from
-- independent labelled hashes of the settlement's own id, so a place has the
-- same name in every world generated from the same seed, and asking twice gives
-- the same answer without anything being stored.
--
-- The parts are chosen by what the land actually is. A settlement in a marsh
-- draws on marsh words and one in the desert draws on dry ones, so the name is
-- evidence about the place rather than decoration on it — the same principle
-- the specializations follow. A fishing village called Saltmere tells you
-- something true; one called Saltmere in the middle of a desert tells you the
-- generator was not paying attention.
--
-- The suffix says what kind of place it is. -ton and -bury are towns because
-- they were towns; -thorpe and -cote are small because they were small. Getting
-- that backwards is the sort of thing that reads as wrong without the reader
-- being able to say why.

local settlements = perfectworld.settlements
local choice = perfectworld.core.choice

--- First elements, by what the ground is like.
local ROOTS = {
  cold      = {"Frost", "Rime", "Snow", "Win", "Bleak", "North", "Hoar", "Grim"},
  coastal   = {"Salt", "Wave", "Sea", "Tide", "Shell", "Gull", "Anchor", "Cliff"},
  dry       = {"Sun", "Dust", "Red", "Bare", "Scorch", "Ochre", "Flint", "Cinder"},
  forest    = {"Oak", "Elder", "Green", "Thorn", "Fern", "Bram", "Wold", "Birch"},
  rocky     = {"Stone", "Crag", "Grey", "Iron", "Slate", "Scree", "Tor", "Quarry"},
  temperate = {"Mill", "Barley", "Old", "King", "Church", "Long", "Little", "Fair"},
  wet       = {"Marsh", "Reed", "Mist", "Fen", "Willow", "Duck", "Bog", "Rain"},
}

--- Second elements. A place is named for what it stands on or beside.
local FEATURES = {
  cold      = {"holt", "fell", "dale", "ridge"},
  coastal   = {"haven", "strand", "cove", "wick"},
  dry       = {"reach", "flats", "hollow", "gate"},
  forest    = {"wood", "shaw", "glade", "hurst"},
  rocky     = {"crag", "scarp", "delve", "cleft"},
  temperate = {"field", "meadow", "green", "cross"},
  wet       = {"mere", "moss", "fen", "beck"},
}

--- What kind of place, said the way English place-names say it.
--
-- Small first, large last. A hamlet called Ashbury and a town called Ashcote
-- would both be wrong, and wrong in a way a reader feels before they can name.
local SUFFIXES = {
  farm    = {"cote", "thorpe", "croft", "stead"},
  hamlet  = {"thorpe", "wick", "worth", "ham"},
  village = {"ham", "ton", "field", "ford", "bridge"},
  town    = {"ton", "bury", "borough", "market", "port"},
  city    = {"bury", "borough", "minster", "chester"},
}

--- Trades leave their mark on a name when the settlement is known for one.
local TRADE_ROOTS = {
  fishing  = {"Net", "Herring", "Cod", "Oyster"},
  farming  = {"Barley", "Corn", "Plough", "Harvest"},
  forestry = {"Timber", "Saw", "Bark", "Charcoal"},
  mining   = {"Delve", "Pit", "Ore", "Forge"},
}

local function family_of(family)
  return ROOTS[family] and family or "temperate"
end

--- The name of a settlement.
--
-- `family` is the biome family and `specialization` the trade, both of which the
-- planner has already decided from measured ground. Neither is required: a
-- caller with only an id still gets a stable name, just a less apt one.
function settlements.name_for(settlement_id, family, specialization, kind)
  local seed_key = "pwname|" .. tostring(perfectworld.world_seed_string)
    .. "|" .. tostring(settlement_id)
  family = family_of(family)
  kind = SUFFIXES[kind] and kind or "village"

  -- A place named for its trade about a third of the time, for its ground the
  -- rest. Always naming it for the trade would make every fishing village on the
  -- map sound like the same fishing village.
  local roots = ROOTS[family]
  if TRADE_ROOTS[specialization]
    and choice.bool(seed_key, "name:after_trade", 0.35) then
    roots = TRADE_ROOTS[specialization]
  end

  local root = choice.pick(seed_key, "name:root", roots)
  local suffix = choice.pick(seed_key, "name:suffix", SUFFIXES[kind])

  -- Two-part names sound like places; three-part names sound like a generator.
  -- The middle element is used sparingly and only where it reads.
  if choice.bool(seed_key, "name:has_feature", 0.30) then
    -- Lower case, joined: Snowridge, not SnowRidge. A capital in the middle is
    -- how a program writes a name and not how a place is called.
    local feature = choice.pick(seed_key, "name:feature", FEATURES[family])
    return root .. feature
  end

  return root .. suffix
end

--- The name of a settlement, from its record, with everything already known.
function settlements.name_of(settlement)
  if type(settlement) ~= "table" then return nil end
  if settlement.name then return settlement.name end
  return settlements.name_for(
    settlement.settlement_id or settlement.candidate_id,
    settlement.biome_family
      or (settlement.environment_profile and settlement.environment_profile.biome_family),
    settlement.specialization,
    settlement.settlement_type or settlement.size_class == "town" and "town" or "village")
end
