perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.population = perfectworld.population or {}

-- pw_population
--
-- The people who live in the settlements the planner builds.
--
-- They are ordinary Mineclonia villagers, not a simulation of our own. That is
-- deliberate: Mineclonia already knows how a villager sleeps, claims a bed,
-- takes a profession from a job block, panics at night and flees a zombie. A
-- parallel implementation would have to be as good as that before it was worth
-- anything, and would still not interoperate with the rest of the game.
--
-- So this module does the one thing the game cannot do for itself: decide how
-- many people a settlement holds and put them there. Everything after that —
-- professions, homes, schedules — the villagers work out on their own by
-- looking at the beds and workstations our buildings already contain.
--
-- === What counts as a place to live ===
--
-- A bed. Not a house, not a lot, not a planned dwelling: an actual bed node
-- standing in the world. Counting planned dwellings would put people inside
-- buildings that failed to materialize, and counting lots would put them in
-- barns. Mineclonia's own villages use the same rule, which also means our
-- villagers and its villagers behave identically once they are there.

local population = perfectworld.population

population.VILLAGER_ENTITY = "mobs_mc:villager"

--- The most people one settlement will be given, however many beds it has.
--
-- Not a statement about how large a settlement may be — a bound on how many
-- active mobs one place may add to the server. A village that materialized
-- oddly and ended up with sixty beds must not become sixty entities.
population.MAX_PER_SETTLEMENT = 24

--- How far outside the recorded bounds to look for beds.
--
-- Bounds are computed from roads and lot footprints, and a bed sits inside a
-- building whose footprint is included — but a building placed at the edge can
-- reach a node or two past what was planned.
population.BOUNDS_MARGIN = 4

local store

local function get_store()
  store = store or (perfectworld.planner and perfectworld.planner.store)
  return store
end

-- === Finding the beds ===

--- Every bed in a settlement's bounds, in a stable order.
--
-- `bed_bottom` rather than `bed`: a bed is two nodes and only the lower one is
-- the sleeping place a villager claims, so counting both would double the
-- population of every settlement.
function population.find_beds(bounds, opts)
  opts = opts or {}
  if type(bounds) ~= "table" or not bounds.min_x then return {} end
  local margin = opts.margin or population.BOUNDS_MARGIN
  local minp = {
    x = math.floor(bounds.min_x - margin),
    y = opts.min_y or -64,
    z = math.floor(bounds.min_z - margin),
  }
  local maxp = {
    x = math.ceil(bounds.max_x + margin),
    y = opts.max_y or 200,
    z = math.ceil(bounds.max_z + margin),
  }

  local positions = minetest.find_nodes_in_area(minp, maxp, {"group:bed_bottom"})
  local beds = {}
  for _, pos in ipairs(positions or {}) do
    beds[#beds + 1] = {x = pos.x, y = pos.y, z = pos.z}
  end
  -- A stable order, so that a settlement with more beds than it is allowed
  -- people always houses the same ones.
  table.sort(beds, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    return a.y < b.y
  end)
  return beds
end

--- Somewhere a villager can actually stand, next to a bed.
--
-- Spawning on the bed itself puts the mob inside a node, and a mob inside a
-- node either suffocates or is shoved somewhere arbitrary. The bedside is
-- tried first, then a wider ring — a bed in a one-block alcove still has floor
-- beside it somewhere.
function population.standing_spot_near(pos)
  local offsets = {
    {x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1},
    {x = 1, z = 1}, {x = -1, z = 1}, {x = 1, z = -1}, {x = -1, z = -1},
    {x = 2, z = 0}, {x = -2, z = 0}, {x = 0, z = 2}, {x = 0, z = -2},
  }
  for _, offset in ipairs(offsets) do
    local x, z = pos.x + offset.x, pos.z + offset.z
    for dy = 0, 2 do
      local foot = minetest.get_node({x = x, y = pos.y + dy, z = z}).name
      local head = minetest.get_node({x = x, y = pos.y + dy + 1, z = z}).name
      local below = minetest.get_node({x = x, y = pos.y + dy - 1, z = z}).name
      local below_def = minetest.registered_nodes[below]
      if foot == "air" and head == "air"
        and below ~= "air" and below ~= "ignore"
        and below_def and below_def.walkable then
        return {x = x + 0.5, y = pos.y + dy, z = z + 0.5}
      end
    end
  end
  return nil
end

--- Is the settlement actually in memory to be looked at?
--
-- A node search over unloaded mapblocks does not fail, it returns nothing, and
-- nothing is indistinguishable from an empty village. Probing a lattice of
-- columns for `ignore` is what tells the two apart: `ignore` is the engine
-- saying "I do not have this", and any real node means the ground is here.
function population.is_loaded(bounds)
  if type(bounds) ~= "table" or not bounds.min_x then return false end
  local samples = {
    {x = (bounds.min_x + bounds.max_x) / 2, z = (bounds.min_z + bounds.max_z) / 2},
    {x = bounds.min_x, z = bounds.min_z},
    {x = bounds.max_x, z = bounds.max_z},
    {x = bounds.min_x, z = bounds.max_z},
    {x = bounds.max_x, z = bounds.min_z},
  }
  for _, sample in ipairs(samples) do
    local x, z = math.floor(sample.x), math.floor(sample.z)
    for y = 200, -64, -4 do
      local name = minetest.get_node({x = x, y = y, z = z}).name
      if name ~= "ignore" and name ~= "air" then return true end
    end
  end
  return false
end

-- === Who is already there ===

--- Villagers currently loaded inside a settlement's bounds.
--
-- A count of what the server has in memory, not of who lives there. Entities in
-- unloaded mapblocks are on disk and invisible to this, which is exactly why
-- the record below exists rather than the world being asked every time.
function population.count_villagers(bounds, margin)
  if type(bounds) ~= "table" or not bounds.min_x then return 0 end
  margin = margin or population.BOUNDS_MARGIN
  local centre_x = (bounds.min_x + bounds.max_x) / 2
  local centre_z = (bounds.min_z + bounds.max_z) / 2
  local half_x = (bounds.max_x - bounds.min_x) / 2 + margin
  local half_z = (bounds.max_z - bounds.min_z) / 2 + margin
  -- A generous sphere and then an exact box test: the objects call takes a
  -- radius, and a settlement is a rectangle that can be much longer than wide.
  local radius = math.sqrt(half_x * half_x + half_z * half_z) + 128

  local found = 0
  for _, object in ipairs(minetest.get_objects_inside_radius(
    {x = centre_x, y = 32, z = centre_z}, radius)) do
    local entity = object:get_luaentity()
    if entity and entity.name == population.VILLAGER_ENTITY then
      local pos = object:get_pos()
      if pos and pos.x >= bounds.min_x - margin and pos.x <= bounds.max_x + margin
        and pos.z >= bounds.min_z - margin and pos.z <= bounds.max_z + margin then
        found = found + 1
      end
    end
  end
  return found
end

-- === The record ===

function population.get_record(settlement_id)
  local s = get_store()
  if not s then return nil end
  return s.get("population", settlement_id)
end

function population.save_record(settlement_id, record)
  local s = get_store()
  if not s then return false end
  s.put("population", settlement_id, record)
  return true
end

function population.list_ids()
  local s = get_store()
  if not s then return {} end
  return s.ids("population")
end

function population._test_forget(settlement_id)
  local s = get_store()
  if s then s.delete("population", settlement_id) end
end

-- === Putting people in a settlement ===

--- How many people a settlement holds, given the beds standing in it.
function population.capacity(bed_count)
  return math.min(math.max(math.floor(tonumber(bed_count) or 0), 0),
    population.MAX_PER_SETTLEMENT)
end

--- Move people into anything that has beds in it.
--
-- Takes bounds rather than a settlement, because most of the places people live
-- in this world are not settlements. Region planning makes a village one time
-- in five; the other four are a single farmstead, and a farmstead has a bed in
-- it. Routing everything through a settlement record left four fifths of the
-- inhabited buildings empty, and the lookup would have refused them anyway:
-- a lone farmstead has no settlement record to find.
--
-- Returns `ok, result`. Idempotent by record: a place that has already been
-- given its people is left alone unless `opts.force` says otherwise, so walking
-- past a village twice does not double its population.
function population.settle(id, bounds, opts)
  opts = opts or {}
  if not minetest.registered_entities[population.VILLAGER_ENTITY] then
    return false, {reason = "no_villager_entity"}
  end
  if type(bounds) ~= "table" or not bounds.min_x then
    return false, {reason = "no_bounds"}
  end

  local settlement_id = id
  local record = population.get_record(settlement_id)
  if record and record.settled and not opts.force then
    return false, {reason = "already_settled", record = record}
  end

  -- "I could not see any beds" and "there are no beds" are different answers,
  -- and only one of them is worth writing down. A settlement whose mapblocks
  -- are not loaded reports nothing from every node search, so recording that as
  -- "no beds" would mark a perfectly good village as permanently uninhabitable
  -- the first time anyone asked about it from far away.
  if not population.is_loaded(bounds) then
    return false, {reason = "not_loaded"}
  end

  local beds = population.find_beds(bounds)
  local wanted = population.capacity(#beds)
  if wanted == 0 then
    -- Recording the visit matters. A settlement with no beds is not one that is
    -- waiting to be populated, and asking the world again on every pass would
    -- be a search of the whole village for a guaranteed nothing.
    population.save_record(settlement_id, {
      settlement_id = settlement_id,
      settled = true,
      beds = 0,
      spawned = 0,
      reason = "no_beds",
      at = minetest.get_gametime(),
    })
    return false, {reason = "no_beds", beds = 0}
  end

  local standing = population.count_villagers(bounds)
  local missing = math.max(wanted - standing, 0)

  local spawned, unreachable = 0, 0
  for index = 1, #beds do
    if spawned >= missing then break end
    local spot = population.standing_spot_near(beds[index])
    if spot and minetest.add_entity(spot, population.VILLAGER_ENTITY) then
      spawned = spawned + 1
    else
      unreachable = unreachable + 1
    end
  end

  local result = {
    settlement_id = settlement_id,
    settled = true,
    bounds = {
      min_x = bounds.min_x, max_x = bounds.max_x,
      min_z = bounds.min_z, max_z = bounds.max_z,
    },
    beds = #beds,
    capacity = wanted,
    already_there = standing,
    spawned = spawned,
    unreachable_beds = unreachable,
    at = minetest.get_gametime(),
  }
  population.save_record(settlement_id, result)
  minetest.log("action", string.format(
    "[pw_population] %s: %d bed(s), %d already there, %d moved in",
    settlement_id, #beds, standing, spawned))
  return true, result
end

--- Move people into a planned settlement.
function population.populate(settlement_id, opts)
  local settlement = perfectworld.settlements
    and perfectworld.settlements.get(settlement_id)
  if not settlement then return false, {reason = "unknown_settlement"} end
  if settlement.status == "failed" then
    return false, {reason = "settlement_never_built"}
  end
  return population.settle(settlement_id, settlement.bounds, opts)
end

--- Move people into a single building that was placed on its own.
--
-- Farms and hamlets are one farmstead, not a settlement: they have no plan, no
-- lots and no streets, so there is no settlement record to look them up by. The
-- footprint is derived from the structure definition rather than stored,
-- because the single-structure record keeps a position and a rotation and not a
-- box.
function population.populate_structure(record, opts)
  if type(record) ~= "table" or not record.position then
    return false, {reason = "no_structure_record"}
  end
  local def = perfectworld.structures and perfectworld.structures.get(record.structure_name)
  if not def then return false, {reason = "unregistered_structure"} end

  local minp, maxp = perfectworld.structures.get_footprint(
    def, record.position, record.rotation or 0)
  return population.settle(record.settlement_id or record.structure_id, {
    min_x = minp.x, max_x = maxp.x,
    min_z = minp.z, max_z = maxp.z,
  }, opts)
end

--- What the villagers standing in a place have made of themselves.
--
-- Professions are Mineclonia's business, not ours: a villager claims a job
-- block it can find and becomes a farmer or a fisherman by doing so. This asks
-- what they chose, which is the only way to know whether the workstations our
-- buildings contain are reachable and recognised.
function population.professions(bounds, margin)
  if type(bounds) ~= "table" or not bounds.min_x then return {} end
  margin = margin or population.BOUNDS_MARGIN
  local centre_x = (bounds.min_x + bounds.max_x) / 2
  local centre_z = (bounds.min_z + bounds.max_z) / 2
  local half_x = (bounds.max_x - bounds.min_x) / 2 + margin
  local half_z = (bounds.max_z - bounds.min_z) / 2 + margin
  local radius = math.sqrt(half_x * half_x + half_z * half_z) + 128

  local counts = {}
  for _, object in ipairs(minetest.get_objects_inside_radius(
    {x = centre_x, y = 32, z = centre_z}, radius)) do
    local entity = object:get_luaentity()
    if entity and entity.name == population.VILLAGER_ENTITY then
      local pos = object:get_pos()
      if pos and pos.x >= bounds.min_x - margin and pos.x <= bounds.max_x + margin
        and pos.z >= bounds.min_z - margin and pos.z <= bounds.max_z + margin then
        local trade = entity._profession or "unemployed"
        counts[trade] = (counts[trade] or 0) + 1
      end
    end
  end
  return counts
end

--- What the record and the world each say about a settlement's people.
function population.status(settlement_id)
  local settlement = perfectworld.settlements
    and perfectworld.settlements.get(settlement_id)
  local record = population.get_record(settlement_id)
  -- A lone farmstead has people and no settlement record. Refusing to report on
  -- it because it is not a settlement would hide four fifths of the inhabited
  -- buildings in the world.
  if not settlement and not record then return nil end
  local bounds = settlement and settlement.bounds or (record and record.bounds)
  return {
    settlement_id = settlement_id,
    status = settlement and settlement.status or "structure",
    settled = (record and record.settled) or false,
    recorded_beds = (record and record.beds) or 0,
    recorded_spawned = (record and record.spawned) or 0,
    -- Asked of the world, so a record claiming people who are no longer there
    -- shows up as a disagreement rather than being believed.
    loaded_villagers = population.count_villagers(bounds),
    professions = population.professions(bounds),
  }
end

minetest.log("action", "[pw_population] loaded")
