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

local function stable_hash(value)
  local text = tostring(value)
  local hash = 5381
  for i = 1, #text do
    hash = (hash * 131 + text:byte(i) + i * 17) % HASH_MOD
  end
  return hash
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
