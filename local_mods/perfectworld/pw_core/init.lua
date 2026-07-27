perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld

local HASH_MOD = 2147483647
local DEFAULT_REGION_SIZE = 1024
local WORLD_FORMAT_VERSION = 1
local WORLD_LOCK_KEY = "pw_world_format_lock"

local function setting_int(name, default)
  local raw = minetest.settings:get(name)
  local value = tonumber(raw)
  if not value or value < 1 then
    return default
  end
  return math.floor(value)
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- Polynomial string hash. Every intermediate stays below 2^41, so IEEE-754
-- doubles (the only numeric type in LuaJIT) represent it exactly.
local function stable_hash(value)
  local text = tostring(value)
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 131 + text:byte(i) + i * 17) % HASH_MOD
  end
  return hash
end

-- === Exact 32-bit integer hashing ===
--
-- Lua numbers here are doubles: products above 2^53 silently lose low bits.
-- Every multiplication below is split into 16-bit limbs so the largest
-- intermediate is 2^16 * 2^32 = 2^48, which is exact with 32x headroom.

local TWO32 = 4294967296

-- (a * b) mod 2^32, exact for 0 <= a, b < 2^32
local function mul32(a, b)
  local ah = math.floor(a / 65536) % 65536
  local al = a % 65536
  return ((ah * b) % 65536 * 65536 + al * b) % TWO32
end

local function mix32(h)
  h = mul32(h + 2127912214, 2246822519)
  h = mul32(h + math.floor(h / 65536), 3266489917)
  h = mul32(h + math.floor(h / 4096), 668265263)
  return (h + math.floor(h / 32768)) % TWO32
end

--- Hash an arbitrary string to a well-distributed integer in [0, 2^32).
local function hash32(value)
  local text = tostring(value)
  local h = 2166136261
  for i = 1, #text do
    h = mul32(h + text:byte(i) + i, 16777619)
    h = (h + math.floor(h / 256)) % TWO32
  end
  return mix32(h + #text)
end

local function to_base36(num)
  local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
  num = math.floor(math.abs(tonumber(num) or 0))
  if num == 0 then
    return "0"
  end
  local out = {}
  while num > 0 do
    local index = (num % 36) + 1
    table.insert(out, 1, alphabet:sub(index, index))
    num = math.floor(num / 36)
  end
  return table.concat(out)
end

perfectworld.VERSION = "0.1.0"
perfectworld.PLANNER_VERSION = 1
perfectworld.WORLD_FORMAT_VERSION = WORLD_FORMAT_VERSION
perfectworld.REGION_SIZE = setting_int("perfectworld.region_size", DEFAULT_REGION_SIZE)
perfectworld.settings = {
  region_size = perfectworld.REGION_SIZE,
}

perfectworld.world_seed_string = tostring(minetest.get_mapgen_setting("seed")
  or minetest.settings:get("fixed_map_seed")
  or "0")
perfectworld.world_seed = tonumber(perfectworld.world_seed_string)

perfectworld.core = perfectworld.core or {}
perfectworld.core.deep_copy = deep_copy
perfectworld.core.stable_hash = stable_hash
perfectworld.core.to_base36 = to_base36
perfectworld.core.mul32 = mul32
perfectworld.core.hash32 = hash32
perfectworld.core.HASH32_MAX = TWO32

-- === Stable variation contract ===
--
-- Planning decisions are NOT drawn from a sequential PRNG. Each decision is an
-- independent hash of (seed_key, label):
--
--   hash32(seed_key .. "#" .. label)
--
-- Consequences that a stream generator cannot offer:
--   * adding a new decision somewhere does not shift any other decision;
--   * decisions can be evaluated in any order, or not at all;
--   * a decision is reproducible in isolation, which makes golden tests cheap.
--
-- Labels must be stable strings. Use ':' to namespace them, e.g.
-- "road:segment:3:direction", "lot:5:rotation".

local choice = {}
perfectworld.core.choice = choice

local function decision_hash(seed_key, label)
  return hash32(tostring(seed_key) .. "#" .. tostring(label))
end

choice.decision_hash = decision_hash

--- Uniform float in [0, 1).
function choice.unit(seed_key, label)
  return decision_hash(seed_key, label) / TWO32
end

--- Uniform integer in [1, n].
function choice.index(seed_key, label, n)
  if not n or n < 1 then return 1 end
  return 1 + decision_hash(seed_key, label) % n
end

--- Uniform integer in [min, max] (inclusive).
function choice.int(seed_key, label, min, max)
  if max < min then min, max = max, min end
  return min + decision_hash(seed_key, label) % (max - min + 1)
end

--- Uniform float in [min, max).
function choice.range(seed_key, label, min, max)
  return min + choice.unit(seed_key, label) * (max - min)
end

--- Pick one element of a non-empty array.
function choice.pick(seed_key, label, list)
  if type(list) ~= "table" or #list == 0 then return nil end
  return list[choice.index(seed_key, label, #list)]
end

--- True with probability p.
function choice.bool(seed_key, label, p)
  return choice.unit(seed_key, label) < (p or 0.5)
end

--- Weighted pick. `entries` is an array of {value = ..., weight = number}.
function choice.weighted(seed_key, label, entries)
  local total = 0
  for _, entry in ipairs(entries) do
    if (entry.weight or 0) > 0 then total = total + entry.weight end
  end
  if total <= 0 then
    return entries[1] and entries[1].value
  end
  local roll = choice.unit(seed_key, label) * total
  local acc = 0
  for _, entry in ipairs(entries) do
    if (entry.weight or 0) > 0 then
      acc = acc + entry.weight
      if roll < acc then return entry.value end
    end
  end
  return entries[#entries].value
end

--- Deterministic Fisher-Yates over a copy of `list`.
-- Each swap uses its own label, so the shuffle of a list of length n is
-- unaffected by decisions made anywhere else.
function choice.shuffle(seed_key, label, list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  for i = #out, 2, -1 do
    local j = choice.index(seed_key, label .. ":swap:" .. i, i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

local function coord_tag(value)
  value = math.floor(tonumber(value) or 0)
  if value < 0 then
    return "n" .. tostring(math.abs(value))
  end
  return "p" .. tostring(value)
end

perfectworld.core.coord_tag = coord_tag

local function object_id(kind, rx, rz, index)
  return table.concat({
    kind,
    "v" .. tostring(perfectworld.PLANNER_VERSION),
    coord_tag(rx),
    coord_tag(rz),
    tostring(index),
  }, "_")
end

function perfectworld.core.region_id(rx, rz)
  return table.concat({
    "region",
    "v" .. tostring(perfectworld.PLANNER_VERSION),
    coord_tag(rx),
    coord_tag(rz),
  }, "_")
end

function perfectworld.core.settlement_id(rx, rz, index)
  return object_id("settlement", rx, rz, index)
end

function perfectworld.core.road_anchor_id(rx, rz, index)
  return object_id("road_anchor", rx, rz, index)
end

function perfectworld.core.reserve_id(rx, rz, index)
  return object_id("reserve", rx, rz, index)
end

function perfectworld.core.structure_id(settlement_id, index)
  return "structure_v" .. tostring(perfectworld.PLANNER_VERSION) .. "_" .. tostring(settlement_id) .. "_" .. tostring(index)
end

function perfectworld.core.seed_fingerprint(seed_string)
  return "seed_" .. to_base36(stable_hash(tostring(seed_string or "")))
end

function perfectworld.core.make_world_format_record()
  return {
    world_format_version = perfectworld.WORLD_FORMAT_VERSION,
    planner_version = perfectworld.PLANNER_VERSION,
    region_size = perfectworld.REGION_SIZE,
    world_seed_fingerprint = perfectworld.core.seed_fingerprint(perfectworld.world_seed_string),
  }
end

function perfectworld.core.check_world_format(saved, current)
  local reasons = {}
  for _, key in ipairs({
    "world_format_version",
    "planner_version",
    "region_size",
    "world_seed_fingerprint",
  }) do
    if tostring(saved and saved[key]) ~= tostring(current and current[key]) then
      table.insert(reasons, key)
    end
  end
  return {
    ok = #reasons == 0,
    reasons = reasons,
  }
end

function perfectworld.core.init_world_format(storage)
  storage = storage or minetest.get_mod_storage()
  local current = perfectworld.core.make_world_format_record()
  local raw = storage:get_string(WORLD_LOCK_KEY)
  if not raw or raw == "" then
    storage:set_string(WORLD_LOCK_KEY, minetest.write_json(current))
    perfectworld.materialization_enabled = true
    perfectworld.world_format_error = nil
    return true, current
  end

  local ok, saved = pcall(minetest.parse_json, raw)
  if not ok or type(saved) ~= "table" then
    perfectworld.materialization_enabled = false
    perfectworld.world_format_error = "invalid_saved_world_format"
    minetest.log("error", "[pw_core] materialization disabled: invalid saved world format lock")
    return false, perfectworld.world_format_error
  end

  local check = perfectworld.core.check_world_format(saved, current)
  if not check.ok then
    perfectworld.materialization_enabled = false
    perfectworld.world_format_error = "incompatible_world_format:" .. table.concat(check.reasons, ",")
    minetest.log("error", "[pw_core] materialization disabled: " .. perfectworld.world_format_error)
    return false, check
  end

  perfectworld.materialization_enabled = true
  perfectworld.world_format_error = nil
  return true, saved
end

function perfectworld.get_version()
  return perfectworld.VERSION
end

function perfectworld.get_region_coords(pos)
  local rx = math.floor(pos.x / perfectworld.REGION_SIZE)
  local rz = math.floor(pos.z / perfectworld.REGION_SIZE)
  return rx, rz
end

function perfectworld.get_region_id(rx, rz)
  return perfectworld.core.region_id(rx, rz)
end

function perfectworld.core.stable_id(prefix, ...)
  local parts = {
    perfectworld.world_seed_string,
    tostring(perfectworld.PLANNER_VERSION),
    tostring(perfectworld.REGION_SIZE),
  }
  for i = 1, select("#", ...) do
    table.insert(parts, tostring(select(i, ...)))
  end
  return prefix .. "_" .. to_base36(stable_hash(table.concat(parts, "|")))
end

function perfectworld.region_seed(rx, rz, planner_version)
  planner_version = planner_version or perfectworld.PLANNER_VERSION
  return stable_hash(table.concat({
    "seed", perfectworld.world_seed_string,
    "rx", tostring(rx),
    "rz", tostring(rz),
    "planner", tostring(planner_version),
    "region_size", tostring(perfectworld.REGION_SIZE),
  }, "|"))
end

perfectworld.planner = {}
perfectworld.structures = {}
perfectworld.roads = {}
perfectworld.settlements = {}

perfectworld.core.init_world_format()

minetest.log("action", "[pw_core] loaded")
