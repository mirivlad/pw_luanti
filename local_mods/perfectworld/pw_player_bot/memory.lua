-- pw_player_bot/memory.lua
--
-- What the bot has seen. This is the thing the bridge deliberately refused to
-- keep, and the reason the split exists: senses report the present, memory
-- accumulates a past, and only one of those can be wrong about the world.
--
-- Three properties hold everything together.
--
-- **It is bounded.** Every store has a ceiling and evicts by least-recently
-- seen. A bot that remembers a whole world is a memory leak with a personality.
--
-- **It can be wrong.** Memory records when it last saw something, not what is
-- true now. A remembered doorway may have been walled up since. Everything
-- carries `last_seen_tick`, and anything older than the stale threshold is
-- reported as stale rather than quietly trusted.
--
-- **It is the bot's, not the world's.** Nothing here is read from the map. Every
-- entry arrives through a player-mode observation, which is what makes a route
-- planned over this memory an honest plan rather than omniscience.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = {}
P.impl.memory = memory

local STORAGE_KEY_PREFIX = "pw_player_bot_memory_v1:"
local STORAGE_VERSION = 1

local storage = minetest.get_mod_storage()

--- Luanti's own rounding: the node at integer n owns [n - 0.5, n + 0.5). A key
--- built with plain floor would put a player standing at x = -2.4 in column -3
--- while the observation that taught the bot about it said column -2, and every
--- route from that position would fail to find its own starting cell.
local function node_round(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

memory.node_round = node_round

--- Surface columns are keyed by x and z: a walker cares which column it can
--- stand in, and at what height, not about every voxel above it.
local function cell_key(x, z)
  return node_round(x) .. ":" .. node_round(z)
end

memory.cell_key = cell_key

local function point_key(pos)
  return node_round(pos.x) .. ":" .. node_round(pos.y) .. ":" .. node_round(pos.z)
end

memory.point_key = point_key

local function is_null(value)
  return value == nil or value == canonical.NULL
end

memory.is_null = is_null

-- === Construction ===

function memory.new(player_name)
  return {
    player_name = player_name,
    version = STORAGE_VERSION,
    tick = 0,
    -- "x:z" -> surface column the bot has stood on or seen
    cells = {},
    cell_count = 0,
    -- "feature@x:y:z" -> a recognised thing at a place
    features = {},
    feature_count = 0,
    -- "kind@x:y:z" -> an object, keyed by what and roughly where, because an
    -- observation id dies with the bridge session and this must outlive it
    entities = {},
    entity_count = 0,
    -- "x:z" of every column the bot has actually occupied
    visited = {},
    visited_count = 0,
    -- counters, for diagnostics and for the bot's own sense of progress
    stats = {
      observations = 0,
      cells_learned = 0,
      cells_evicted = 0,
      features_learned = 0,
      entities_learned = 0,
      contradictions = 0,
    },
  }
end

-- === Eviction ===
--
-- Least-recently-seen. Scanning the whole store to find the oldest entry would
-- be quadratic over a session, so eviction runs in one pass that drops
-- everything older than a computed cutoff — an approximate LRU that costs one
-- sweep instead of one search per insert.

local function evict(store, count_field, limit, keep_fraction, memo)
  local count = memo[count_field]
  if count <= limit then return 0 end

  local ticks = {}
  for _, entry in pairs(store) do
    ticks[#ticks + 1] = entry.last_seen_tick or 0
  end
  table.sort(ticks)
  local target = math.floor(limit * (keep_fraction or 0.85))
  local cutoff_index = math.max(1, #ticks - target)
  local cutoff = ticks[cutoff_index] or 0

  local removed = 0
  for key, entry in pairs(store) do
    if (entry.last_seen_tick or 0) < cutoff then
      store[key] = nil
      removed = removed + 1
    end
  end
  memo[count_field] = count - removed
  return removed
end

-- === Integrating an observation ===

--- Learn one surface column.
--
-- `confidence` separates standing on a block from glimpsing it twelve nodes
-- away. Both are knowledge; only one of them is knowledge a route should lean
-- on without hesitating.
local function learn_cell(memo, x, z, record, confidence)
  local key = cell_key(x, z)
  local existing = memo.cells[key]
  if existing then
    if existing.ground_y ~= record.ground_y and existing.confidence <= confidence then
      -- The world moved, or the earlier look was worse. Either way the older
      -- belief was wrong, and that is worth counting.
      memo.stats.contradictions = memo.stats.contradictions + 1
    end
    if confidence >= existing.confidence or record.ground_y ~= existing.ground_y then
      existing.ground_y = record.ground_y
      existing.walkable = record.walkable
      existing.water = record.water
      existing.hazard = record.hazard
      existing.head_clearance = record.head_clearance
      existing.node_name = record.node_name
      existing.semantics = record.semantics
      existing.confidence = math.max(existing.confidence, confidence)
    end
    existing.last_seen_tick = memo.tick
    existing.times_seen = (existing.times_seen or 1) + 1
    return false
  end

  memo.cells[key] = {
    x = node_round(x),
    z = node_round(z),
    ground_y = record.ground_y,
    walkable = record.walkable,
    water = record.water,
    hazard = record.hazard,
    head_clearance = record.head_clearance,
    node_name = record.node_name,
    semantics = record.semantics,
    confidence = confidence,
    first_seen_tick = memo.tick,
    last_seen_tick = memo.tick,
    times_seen = 1,
  }
  memo.cell_count = memo.cell_count + 1
  memo.stats.cells_learned = memo.stats.cells_learned + 1
  return true
end

memory.learn_cell = learn_cell

local function has_tag(list, wanted)
  for _, tag in ipairs(list or {}) do
    if tag == wanted then return true end
  end
  return false
end

memory.has_tag = has_tag

local HAZARD_TAGS = {hazard = true, lava = true}

local function tags_are_hazardous(tags)
  for _, tag in ipairs(tags or {}) do
    if HAZARD_TAGS[tag] then return true end
  end
  return false
end

--- Fold a player-mode observation into memory.
--
-- Every source below is something the bridge reported as *seen*. Nothing is
-- inferred about places the observation did not mention: an unmentioned column
-- stays unknown, and unknown is what drives the bot to go and look.
function memory.integrate(memo, observation)
  if type(observation) ~= "table" then return memo end
  memo.tick = memo.tick + 1
  memo.stats.observations = memo.stats.observations + 1

  local self_state = observation.self_state
  if type(self_state) == "table" and type(self_state.position) == "table" then
    local px = math.floor(self_state.position.x + 0.5)
    local pz = math.floor(self_state.position.z + 0.5)
    local py = math.floor(self_state.position.y + 0.5)
    local key = cell_key(px, pz)
    if not memo.visited[key] then
      memo.visited[key] = {x = px, z = pz, first_tick = memo.tick}
      memo.visited_count = memo.visited_count + 1
    end
    memo.visited[key].last_tick = memo.tick
    memo.last_position = {x = px, y = py, z = pz}
    memo.last_yaw = self_state.yaw
    memo.last_pitch = self_state.pitch
    memo.last_hp = self_state.hp
    memo.last_in_liquid = self_state.in_liquid and true or false
    memo.last_on_ground = self_state.on_ground and true or false

    -- Standing on a block is the strongest possible evidence about it.
    local under = self_state.node_under
    if type(under) == "table" and under.name then
      learn_cell(memo, px, pz, {
        ground_y = py - 1,
        walkable = true,
        water = self_state.in_liquid and true or false,
        hazard = tags_are_hazardous(under.semantics),
        head_clearance = 2,
        node_name = under.name,
        semantics = under.semantics or {},
      }, 1.0)
    end
  end

  -- The tactile probe: the cell the body is about to step into. This is the
  -- highest-confidence source after standing on a block, because it is contact
  -- rather than sight — and it works while the head is pointed elsewhere.
  local tactile = observation.tactile
  if type(tactile) == "table" and memo.last_position then
    local ahead = tactile.space_at_feet_ahead
    local body = tactile.space_at_body_ahead
    if type(ahead) == "table" and type(ahead.position) == "table" and ahead.name then
      -- The bridge reports the drop relative to the floor the bot stands on, so
      -- the ground level ahead follows from it rather than from a guess.
      local floor_y = memo.last_position.y - 1
      local ground_y
      if not is_null(tactile.drop_ahead) and type(tactile.drop_ahead) == "number" then
        ground_y = floor_y - tactile.drop_ahead
      elseif not is_null(tactile.step_height_ahead) and type(tactile.step_height_ahead) == "number" then
        ground_y = floor_y + tactile.step_height_ahead - 1
      end

      -- Steppable means the body has room: feet and chest free ahead.
      local feet_free = ahead.walkable == false
      local body_free = type(body) ~= "table" or body.walkable == false

      if ground_y then
        learn_cell(memo, ahead.position.x, ahead.position.z, {
          ground_y = ground_y,
          walkable = feet_free and body_free,
          water = (ahead.liquid_type or "none") ~= "none",
          hazard = (ahead.damage_per_second or 0) > 0 or tags_are_hazardous(ahead.semantics),
          head_clearance = (feet_free and body_free) and 2 or 0,
          node_name = ahead.name,
          semantics = ahead.semantics or {},
        }, 0.95)
      end
    end
  end

  -- The surface strip ahead: the bulk of what a walking bot learns.
  local profile = observation.surface_profile
  if type(profile) == "table" and type(profile.samples) == "table" then
    for _, sample in ipairs(profile.samples) do
      if sample.available ~= false and sample.ground_y and type(sample.position) == "table" then
        -- Confidence falls with distance: step one is almost underfoot, step
        -- twelve is a glimpse.
        local confidence = math.max(0.3, 0.85 - (sample.step or 1) * 0.04)
        learn_cell(memo, sample.position.x, sample.position.z, {
          ground_y = sample.ground_y,
          walkable = sample.walkable and true or false,
          water = sample.water and true or false,
          hazard = tags_are_hazardous(sample.semantics),
          head_clearance = sample.head_clearance or 0,
          node_name = sample.ground_node or "unknown",
          semantics = sample.semantics or {},
        }, confidence)
      end
    end
  end

  -- Recognised features: doors, roads, ladders, water, boats.
  for _, feature in ipairs(observation.visible_features or {}) do
    if feature.feature and type(feature.position) == "table" then
      local key = feature.feature .. "@" .. point_key(feature.position)
      local existing = memo.features[key]
      if existing then
        existing.last_seen_tick = memo.tick
        existing.times_seen = existing.times_seen + 1
      else
        memo.features[key] = {
          feature = feature.feature,
          position = canonical.node_vector(feature.position),
          node_name = feature.node_name or "unknown",
          first_seen_tick = memo.tick,
          last_seen_tick = memo.tick,
          times_seen = 1,
          visited = false,
        }
        memo.feature_count = memo.feature_count + 1
        memo.stats.features_learned = memo.stats.features_learned + 1
      end
    end
  end

  -- Objects. Keyed by kind and place rather than by observation id, because an
  -- observation id is only valid for the current bridge session and memory has
  -- to outlive a reconnection.
  for _, entity in ipairs(observation.visible_entities or {}) do
    if entity.kind and type(entity.position) == "table" then
      local key = entity.kind .. "@" .. point_key(entity.position)
      local existing = memo.entities[key]
      if existing then
        existing.last_seen_tick = memo.tick
        existing.times_seen = existing.times_seen + 1
        existing.observation_id = entity.observation_id
      else
        memo.entities[key] = {
          kind = entity.kind,
          name = entity.name or "unknown",
          position = canonical.vector(entity.position),
          semantic_tags = entity.semantic_tags or {},
          observation_id = entity.observation_id,
          first_seen_tick = memo.tick,
          last_seen_tick = memo.tick,
          times_seen = 1,
        }
        memo.entity_count = memo.entity_count + 1
        memo.stats.entities_learned = memo.stats.entities_learned + 1
      end
    end
  end

  -- Obstacles the rays struck. A ray hit is not a surface, so it does not make
  -- a walkable column; it makes a column the bot should not expect to walk
  -- through.
  for _, ray in ipairs(observation.rays or {}) do
    if ray.hit_type == "node" and type(ray.position) == "table"
      and type(ray.node) == "table" and ray.node.properties then
      if ray.node.properties.walkable and ray.distance and ray.distance <= 6 then
        local key = cell_key(ray.position.x, ray.position.z)
        local cell = memo.cells[key]
        if cell and ray.position.y > cell.ground_y + 1 then
          -- Something solid stands above the remembered floor here.
          cell.blocked_above = true
          cell.last_seen_tick = memo.tick
        end
      end
    end
  end

  local evicted = evict(memo.cells, "cell_count", settings.memory_max_cells, 0.85, memo)
  memo.stats.cells_evicted = memo.stats.cells_evicted + evicted
  evict(memo.features, "feature_count", settings.memory_max_features, 0.85, memo)
  evict(memo.entities, "entity_count", settings.memory_max_entities, 0.85, memo)

  return memo
end

-- === Queries ===

function memory.get_cell(memo, x, z)
  return memo.cells[cell_key(x, z)]
end

function memory.knows_cell(memo, x, z)
  return memo.cells[cell_key(x, z)] ~= nil
end

function memory.has_visited(memo, x, z)
  return memo.visited[cell_key(x, z)] ~= nil
end

function memory.is_stale(memo, entry)
  if not entry then return true end
  return (memo.tick - (entry.last_seen_tick or 0)) > settings.memory_stale_ticks
end

--- Features of a kind, nearest first, staleness reported rather than hidden.
function memory.features_of(memo, feature_name, origin)
  local out = {}
  for key, entry in pairs(memo.features) do
    if (not feature_name) or entry.feature == feature_name then
      local distance = 0
      if origin then
        local dx = entry.position.x - origin.x
        local dz = entry.position.z - origin.z
        distance = math.sqrt(dx * dx + dz * dz)
      end
      out[#out + 1] = {
        key = key,
        feature = entry.feature,
        position = entry.position,
        node_name = entry.node_name,
        distance = canonical.round(distance),
        last_seen_tick = entry.last_seen_tick,
        stale = memory.is_stale(memo, entry),
        visited = entry.visited and true or false,
      }
    end
  end
  -- Sorted by distance then key, so the same memory always yields the same
  -- order and the same decision.
  table.sort(out, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.key < b.key
  end)
  return out
end

function memory.mark_feature_visited(memo, key)
  local entry = memo.features[key]
  if entry then entry.visited = true end
end

function memory.summary(memo)
  return {
    player_name = memo.player_name,
    tick = memo.tick,
    cells = memo.cell_count,
    features = memo.feature_count,
    entities = memo.entity_count,
    visited = memo.visited_count,
    last_position = memo.last_position and canonical.node_vector(memo.last_position) or canonical.NULL,
    stats = {
      observations = memo.stats.observations,
      cells_learned = memo.stats.cells_learned,
      cells_evicted = memo.stats.cells_evicted,
      features_learned = memo.stats.features_learned,
      entities_learned = memo.stats.entities_learned,
      contradictions = memo.stats.contradictions,
    },
    limits = {
      max_cells = settings.memory_max_cells,
      max_features = settings.memory_max_features,
      max_entities = settings.memory_max_entities,
      stale_after_ticks = settings.memory_stale_ticks,
    },
  }
end

-- === Persistence ===
--
-- Memory survives a restart, because a bot that forgets the village every time
-- the server bounces would never accumulate anything worth calling knowledge.
-- Observation ids do not survive, and are dropped on the way out: they address
-- a bridge session that no longer exists.

function memory.save(memo)
  local cells = {}
  for _, cell in pairs(memo.cells) do
    cells[#cells + 1] = {
      x = cell.x, z = cell.z, y = cell.ground_y,
      w = cell.walkable and 1 or 0,
      q = canonical.round(cell.confidence, 2),
      t = cell.last_seen_tick,
      n = cell.node_name,
      h = cell.head_clearance,
      l = cell.water and 1 or 0,
      d = cell.hazard and 1 or 0,
    }
  end
  table.sort(cells, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.z < b.z
  end)

  local features = {}
  for key, entry in pairs(memo.features) do
    features[#features + 1] = {
      k = key, f = entry.feature, p = entry.position, n = entry.node_name,
      t = entry.last_seen_tick, v = entry.visited and 1 or 0,
    }
  end
  table.sort(features, function(a, b) return a.k < b.k end)

  local visited = {}
  for key, entry in pairs(memo.visited) do
    visited[#visited + 1] = {k = key, x = entry.x, z = entry.z, t = entry.last_tick}
  end
  table.sort(visited, function(a, b) return a.k < b.k end)

  local ok, err = pcall(function()
    storage:set_string(STORAGE_KEY_PREFIX .. memo.player_name, minetest.write_json({
      version = STORAGE_VERSION,
      player_name = memo.player_name,
      tick = memo.tick,
      cells = cells,
      features = features,
      visited = visited,
      stats = memo.stats,
    }))
  end)
  if not ok then
    minetest.log("error", "[pw_player_bot] could not persist memory: " .. tostring(err))
    return false
  end
  return true
end

function memory.load(player_name)
  local memo = memory.new(player_name)
  local raw = storage:get_string(STORAGE_KEY_PREFIX .. player_name)
  if not raw or raw == "" then return memo, {loaded = false} end

  local ok, data = pcall(minetest.parse_json, raw, nil, true)
  if not ok or type(data) ~= "table" or tonumber(data.version) ~= STORAGE_VERSION then
    minetest.log("warning", "[pw_player_bot] memory for " .. player_name
      .. " is unreadable or of an unknown version; starting fresh")
    return memo, {loaded = false, reason = "unreadable"}
  end

  memo.tick = math.floor(tonumber(data.tick) or 0)
  for _, cell in ipairs(data.cells or {}) do
    local key = cell_key(cell.x, cell.z)
    memo.cells[key] = {
      x = math.floor(cell.x), z = math.floor(cell.z),
      ground_y = math.floor(cell.y or 0),
      walkable = cell.w == 1,
      water = cell.l == 1,
      hazard = cell.d == 1,
      head_clearance = math.floor(cell.h or 2),
      node_name = cell.n or "unknown",
      semantics = {},
      confidence = tonumber(cell.q) or 0.5,
      first_seen_tick = math.floor(cell.t or 0),
      last_seen_tick = math.floor(cell.t or 0),
      times_seen = 1,
    }
    memo.cell_count = memo.cell_count + 1
  end
  for _, entry in ipairs(data.features or {}) do
    if entry.k and entry.f and type(entry.p) == "table" then
      memo.features[entry.k] = {
        feature = entry.f,
        position = canonical.node_vector(entry.p),
        node_name = entry.n or "unknown",
        first_seen_tick = math.floor(entry.t or 0),
        last_seen_tick = math.floor(entry.t or 0),
        times_seen = 1,
        visited = entry.v == 1,
      }
      memo.feature_count = memo.feature_count + 1
    end
  end
  for _, entry in ipairs(data.visited or {}) do
    if entry.k then
      memo.visited[entry.k] = {
        x = math.floor(entry.x or 0), z = math.floor(entry.z or 0),
        first_tick = math.floor(entry.t or 0), last_tick = math.floor(entry.t or 0),
      }
      memo.visited_count = memo.visited_count + 1
    end
  end
  if type(data.stats) == "table" then
    for key, value in pairs(memo.stats) do
      memo.stats[key] = math.floor(tonumber(data.stats[key]) or value)
    end
  end
  return memo, {loaded = true, cells = memo.cell_count, features = memo.feature_count}
end

function memory.forget(player_name)
  storage:set_string(STORAGE_KEY_PREFIX .. player_name, "")
  return memory.new(player_name)
end

--- Exactly what is written to storage. Exposed so a test can assert what the
--- persistence contract forbids, not just what it promises.
function memory.storage_string(player_name)
  return storage:get_string(STORAGE_KEY_PREFIX .. player_name)
end

--- Test hook: plant raw storage content. `minetest.get_mod_storage()` may only
--- be called while mods load, so a test cannot reach the handle itself.
function memory._test_write_storage(player_name, raw)
  storage:set_string(STORAGE_KEY_PREFIX .. player_name, raw or "")
  return true
end

return memory
