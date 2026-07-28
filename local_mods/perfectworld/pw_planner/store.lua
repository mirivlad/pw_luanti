-- pw_planner/store.lua
--
-- Sharded persistence for settlements, structures, roads and placement marks.
--
-- The problem this solves: every record kind used to live in one flat
-- `id -> record` map under a single mod-storage key, so saving one barn
-- serialized every settlement, every structure and every road in the world.
-- Reads were cached, writes were not, and the cost grew with the world rather
-- than with the change. A world with cities and roads between them would have
-- spent its time in `write_json` rather than in the generator.
--
-- Records are now grouped by the region they belong to. Every id the project
-- mints carries its region in it — `settlement_v1_p2_n3_1`,
-- `structure_v1_settlement_v1_p2_n3_1_1`, `settlement_v1_p2_n3_1_road_main_0` —
-- so the shard is derivable from the id alone and nothing has to remember which
-- shard a record went into.
--
--     pw_store_format          -> {version = N}
--     pw_<kind>__shards        -> {["p2_n3"] = true, ...}
--     pw_<kind>:p2_n3          -> {id = record, ...}
--
-- Writing a record rewrites one region's map. Reading one reads one region's
-- map, once, and keeps it. Listing everything still costs everything, which is
-- honest: enumerating the world is an expensive question and callers that ask
-- it are rare.

local store = {}

local storage = minetest.get_mod_storage()

--- Bumped when the on-disk layout changes in a way old data cannot be read as.
store.FORMAT_VERSION = 2
local FORMAT_KEY = "pw_store_format"

--- Records whose id carries no region tag. They still work; they just all live
--- together, which is fine because nothing mints such ids today.
local UNSHARDED = "misc"

--- The kinds, and the single flat key each used to live under.
--
-- The legacy key is kept in the table rather than in a migration script,
-- because a migration that cannot say what it is reading from is a migration
-- nobody can check.
store.KINDS = {
  placed      = {prefix = "pw_placed",      legacy = "pw_placed_settlements"},
  structures  = {prefix = "pw_structures",  legacy = "pw_materialized_structures"},
  settlements = {prefix = "pw_settlements", legacy = "pw_settlement_plans"},
  roads       = {prefix = "pw_roads_store", legacy = "pw_roads"},
  -- Who lives where. No legacy key: nothing has ever written this before.
  population  = {prefix = "pw_population",  legacy = "pw_population_legacy"},
}

--- Decoded shards, by storage key. Same contract as the cache this replaces:
--- a decoded map is kept until the next write to it.
local decoded = {}

local function read_map(key)
  local cached = decoded[key]
  if cached then return cached end
  local raw = storage:get_string(key)
  if raw and raw ~= "" then
    local ok, data = pcall(minetest.parse_json, raw)
    if ok and type(data) == "table" then
      decoded[key] = data
      return data
    end
  end
  local empty = {}
  decoded[key] = empty
  return empty
end

local function write_map(key, data)
  storage:set_string(key, minetest.write_json(data))
  decoded[key] = data
end

--- Which region a record belongs to, read out of its own id.
--
-- Every id is built by `perfectworld.core` from coordinate tags, so the first
-- `<tag>_<tag>` pair in an id is its region. A structure id embeds its
-- settlement id, and a road id embeds it too, so all three land in the same
-- shard as the settlement they belong to — which is the grouping that matters,
-- because they are written together and read together.
function store.shard_for(id)
  if type(id) ~= "string" then return UNSHARDED end
  local tag = id:match("([pn]%d+_[pn]%d+)")
  return tag or UNSHARDED
end

local function kind_def(kind)
  local def = store.KINDS[kind]
  if not def then error("unknown store kind: " .. tostring(kind)) end
  return def
end

local function shard_key(kind, shard)
  return kind_def(kind).prefix .. ":" .. shard
end

local function index_key(kind)
  return kind_def(kind).prefix .. "__shards"
end

--- Shard names that hold at least one record of this kind.
--
-- Kept explicitly rather than discovered by scanning mod storage: the engine
-- will hand over every key in the mod's storage, but doing that on every list
-- would trade one whole-world read for another.
local function shards_of(kind)
  return read_map(index_key(kind))
end

local function remember_shard(kind, shard)
  local index = shards_of(kind)
  if not index[shard] then
    index[shard] = true
    write_map(index_key(kind), index)
  end
end

local function forget_shard_if_empty(kind, shard)
  if next(read_map(shard_key(kind, shard))) ~= nil then return end
  local index = shards_of(kind)
  if index[shard] then
    index[shard] = nil
    write_map(index_key(kind), index)
  end
end

-- === The API =================================================================

function store.get(kind, id)
  return read_map(shard_key(kind, store.shard_for(id)))[id]
end

function store.put(kind, id, record)
  local shard = store.shard_for(id)
  local key = shard_key(kind, shard)
  local data = read_map(key)
  data[id] = record
  write_map(key, data)
  remember_shard(kind, shard)
end

function store.delete(kind, id)
  local shard = store.shard_for(id)
  local key = shard_key(kind, shard)
  local data = read_map(key)
  if data[id] == nil then return end
  data[id] = nil
  write_map(key, data)
  forget_shard_if_empty(kind, shard)
end

--- Every id of this kind, sorted. Costs one read per non-empty region.
function store.ids(kind)
  local ids = {}
  for shard, _ in pairs(shards_of(kind)) do
    for id, _ in pairs(read_map(shard_key(kind, shard))) do
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

--- Every record of this kind, as `id -> record`. Same cost as `ids`.
function store.all(kind)
  local out = {}
  for shard, _ in pairs(shards_of(kind)) do
    for id, record in pairs(read_map(shard_key(kind, shard))) do
      out[id] = record
    end
  end
  return out
end

--- Every record of this kind that belongs to one region, as `id -> record`.
--
-- The point of sharding is that a caller who knows where it is looking should
-- not pay for the rest of the world. Mapchunk generation asks this on every
-- chunk; `all` would have made it read every region that has ever been built.
function store.region(kind, shard)
  local out = {}
  for id, record in pairs(read_map(shard_key(kind, shard))) do
    out[id] = record
  end
  return out
end

--- Forget every decoded map. For tests that write storage behind the API.
function store.drop_cache()
  decoded = {}
end

--- The serialized bytes of one shard, or "" if it has never been written.
--
-- Mod storage belongs to the mod that opened it, so a test living in `pw_tests`
-- cannot read `pw_planner`'s storage directly. This is the window it looks
-- through — read-only, and the only way to check the claim that matters: that
-- writing one region leaves another region's bytes alone.
function store.shard_blob(kind, shard)
  return storage:get_string(shard_key(kind, shard))
end

-- === Migration ===============================================================

--- What version the data on disk is written in. Absent means version 1: the
--- original flat maps, which had no version marker at all.
function store.format_version()
  local raw = storage:get_string(FORMAT_KEY)
  if not raw or raw == "" then return 1 end
  local ok, data = pcall(minetest.parse_json, raw)
  if ok and type(data) == "table" and tonumber(data.version) then
    return math.floor(tonumber(data.version))
  end
  return 1
end

local function set_format_version(version)
  storage:set_string(FORMAT_KEY, minetest.write_json({version = version}))
end

--- Split one kind's flat legacy map into per-region shards.
--
-- Returns how many records moved. The legacy key is cleared only after every
-- shard has been written, so an interruption leaves the old data readable
-- rather than half of it gone.
local function migrate_kind(kind)
  local def = kind_def(kind)
  local raw = storage:get_string(def.legacy)
  if not raw or raw == "" then return 0 end
  local ok, data = pcall(minetest.parse_json, raw)
  if not ok or type(data) ~= "table" then return 0 end

  local by_shard, moved = {}, 0
  for id, record in pairs(data) do
    local shard = store.shard_for(id)
    by_shard[shard] = by_shard[shard] or {}
    by_shard[shard][id] = record
    moved = moved + 1
  end

  local index = shards_of(kind)
  for shard, records in pairs(by_shard) do
    local key = shard_key(kind, shard)
    local existing = read_map(key)
    for id, record in pairs(records) do existing[id] = record end
    write_map(key, existing)
    index[shard] = true
  end
  write_map(index_key(kind), index)

  storage:set_string(def.legacy, "")
  return moved
end

--- Put a flat legacy map back on disk and forget the format marker, so that
--- migration can be exercised against real storage rather than a fake.
--
-- Only a test has any business calling this: it deliberately writes the old
-- layout that the current code no longer produces.
function store._test_seed_legacy(kind, records)
  storage:set_string(kind_def(kind).legacy, minetest.write_json(records))
  storage:set_string(FORMAT_KEY, "")
  store.drop_cache()
end

function store._test_legacy_blob(kind)
  return storage:get_string(kind_def(kind).legacy)
end

--- Bring storage up to the current format. Safe to call when already current.
function store.migrate()
  local from = store.format_version()
  if from >= store.FORMAT_VERSION then return from, 0 end

  local moved = 0
  for kind, _ in pairs(store.KINDS) do
    moved = moved + migrate_kind(kind)
  end
  set_format_version(store.FORMAT_VERSION)

  minetest.log("action", string.format(
    "[pw_planner] storage migrated from format %d to %d: %d record(s) sharded by region",
    from, store.FORMAT_VERSION, moved))
  return from, moved
end

return store
