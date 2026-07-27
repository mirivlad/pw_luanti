-- pw_bot_bridge/player_perception.lua
--
-- What a connected player could plausibly know from where they stand and where
-- they look.
--
-- The contract, stated once so nothing downstream has to guess:
--
--   Player mode is a deterministic server-side approximation of the programmatic
--   perception available to a player, bounded by position, look direction,
--   field of view, view distance and line of sight.
--
-- It is not a copy of the screen. The server does not know the client's FOV
-- setting, its view range, or what the renderer actually drew. What it does
-- know is position, yaw, pitch, the nodes and the objects — and that is what is
-- reported, filtered by the bounds above.
--
-- Perception is composite on purpose. A cube of every node within N blocks
-- would be both a leak and useless; instead the bot gets proprioception, a
-- tactile probe of the space its body occupies, a fan of vision rays, the
-- objects it can see, the features it can recognise, and a short surface
-- profile ahead of it.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local semantics = B.impl.semantics
local perception = B.impl.perception
local entities = B.impl.entities
local settings = B.impl.settings
local player_perception = {}
B.impl.player_perception = player_perception

local DEG = perception.DEG

-- === Ray fans ===
--
-- Ray origins are body levels, not just the eye: a ray from the feet is the one
-- that tells a walker about a kerb, and a ray from the eye cannot.

local LEVEL_HEIGHTS = {
  feet = 0.3,
  body = 1.0,
  head = nil,   -- resolved to the real eye height at cast time
  up = nil,
  down = nil,
}

local function ray_tag(offset)
  if offset == 0 then return "c" end
  if offset < 0 then return "l" .. math.floor(-offset) end
  return "r" .. math.floor(offset)
end

local function fan(levels, horizontals, pitch_offset)
  local rays = {}
  for _, level in ipairs(levels) do
    for _, h in ipairs(horizontals) do
      rays[#rays + 1] = {
        id = level .. "_" .. ray_tag(h),
        level = level,
        yaw_offset = h,
        pitch_offset = pitch_offset or 0,
      }
    end
  end
  return rays
end

local function concat_rays(...)
  local out = {}
  for _, list in ipairs({...}) do
    for _, ray in ipairs(list) do out[#out + 1] = ray end
  end
  return out
end

player_perception.PROFILES = {
  minimal = concat_rays(
    fan({"body"}, {0}),
    fan({"up"}, {0}, 35),
    fan({"down"}, {0}, -35)
  ),
  navigation = concat_rays(
    fan({"feet", "body", "head"}, {-30, -15, 0, 15, 30}),
    fan({"up"}, {0}, 35),
    fan({"down"}, {0}, -35)
  ),
  detailed = concat_rays(
    fan({"feet", "body", "head"}, {-45, -30, -15, 0, 15, 30, 45}),
    fan({"up"}, {-20, 0, 20}, 35),
    fan({"down"}, {-20, 0, 20}, -35)
  ),
}

-- Dense internal fan used by find_visible_feature. It is not a public profile:
-- it exists so a feature search covers the permitted sector rather than the
-- handful of directions a navigation fan happens to sample.
local function build_feature_fan()
  local rays = {}
  for h = -60, 60, 8 do
    for v = -40, 40, 10 do
      rays[#rays + 1] = {
        id = string.format("scan_%s_%s", ray_tag(h), v < 0 and ("d" .. -v) or ("u" .. v)),
        level = "head",
        yaw_offset = h,
        pitch_offset = v,
      }
    end
  end
  return rays
end

player_perception.FEATURE_FAN = build_feature_fan()

function player_perception.list_profiles()
  local out = {}
  for name in pairs(player_perception.PROFILES) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function player_perception.is_profile(name)
  return player_perception.PROFILES[name] ~= nil
end

-- === Scan sectors ===
--
-- A scan never turns the player. It narrows the sector the bridge is willing to
-- describe to a sub-range of the field of view that is already permitted, so
-- `scan_left` means "the left half of what I can see", not "look left".

function player_perception.sector_for(operation, limits)
  local h = limits.horizontal_fov / 2
  local v = limits.vertical_fov / 2
  if operation == "scan_forward" then
    return {h_min = -h / 3, h_max = h / 3, v_min = -v / 3, v_max = v / 3}
  elseif operation == "scan_left" then
    return {h_min = -h, h_max = 0, v_min = -v, v_max = v}
  elseif operation == "scan_right" then
    return {h_min = 0, h_max = h, v_min = -v, v_max = v}
  elseif operation == "scan_up" then
    return {h_min = -h, h_max = h, v_min = 0, v_max = v}
  elseif operation == "scan_down" then
    return {h_min = -h, h_max = h, v_min = -v, v_max = 0}
  end
  return nil
end

-- === Proprioception ===

local function node_field(pos, budget)
  perception.spend(budget, 1)
  local sample = perception.node_at(pos)
  if sample.state == "not_loaded" then
    return {available = false, reason = "map_not_loaded"}
  end
  return {
    name = sample.name,
    state = sample.state,
    position = canonical.node_vector(pos),
    semantics = semantics.tags_for_node_name(sample.name),
  }
end

--- The body's own state.
--
-- Fields the server API cannot answer are reported as
-- {available = false, reason = ...} rather than invented. `on_ground` is the
-- one derived field: Luanti exposes no server-side ground flag for players, so
-- it is inferred from the node under the feet and the vertical velocity, and
-- says so.
function player_perception.self_state(player, session, budget)
  local pos = player:get_pos()
  local yaw, pitch = perception.look(player)
  local velocity = player.get_velocity and player:get_velocity() or nil
  local eye_height = perception.eye_height(player)

  local base = {
    x = math.floor(pos.x + 0.5),
    y = math.floor(pos.y + 0.5),
    z = math.floor(pos.z + 0.5),
  }
  local under = node_field({x = base.x, y = base.y - 1, z = base.z}, budget)
  local feet = node_field({x = base.x, y = base.y, z = base.z}, budget)
  local body = node_field({x = base.x, y = base.y + 1, z = base.z}, budget)
  local head = node_field({
    x = base.x, y = math.floor(pos.y + eye_height + 0.5), z = base.z,
  }, budget)

  local feet_def = feet.name and minetest.registered_nodes[feet.name] or nil
  local liquid = feet_def and feet_def.liquidtype or "none"
  local in_liquid = liquid == "source" or liquid == "flowing"

  local under_def = under.name and minetest.registered_nodes[under.name] or nil
  local under_walkable = under_def and under_def.walkable ~= false or false
  local vy = velocity and velocity.y or 0
  local on_ground = under_walkable and math.abs(vy) < 0.05 and not in_liquid

  local attach = player.get_attach and player:get_attach() or nil
  local wielded = player:get_wielded_item()

  local breath
  if player.get_breath then
    breath = player:get_breath()
  end

  return {
    player_name = player:get_player_name(),
    connected = true,
    position = canonical.vector(pos),
    eye_position = canonical.vector({x = pos.x, y = pos.y + eye_height, z = pos.z}),
    eye_height = canonical.round(eye_height),
    velocity = velocity and canonical.vector(velocity)
      or {available = false, reason = "unsupported_by_server_api"},
    yaw = canonical.round(yaw),
    pitch = canonical.round(pitch),
    look_dir = canonical.vector(perception.dir_from_angles(yaw, pitch)),
    on_ground = on_ground,
    on_ground_source = "derived_from_node_under_and_velocity",
    in_liquid = in_liquid,
    liquid_type = in_liquid and liquid or canonical.NULL,
    hp = math.floor(player:get_hp() or 0),
    breath = breath and math.floor(breath)
      or {available = false, reason = "unsupported_by_server_api"},
    wielded_item = wielded and wielded:get_name() or "",
    attached = attach ~= nil,
    attached_entity = attach and entities.id_for(session, attach) or canonical.NULL,
    node_under = under,
    node_at_feet = feet,
    node_at_body = body,
    node_at_head = head,
  }
end

-- === Tactile / collision vicinity ===
--
-- The space the body occupies and the block it is about to walk into. This is
-- allowed outside the field of view — at arm's length it models physical
-- contact, not sight — and it is why the radius is two nodes, not twenty.

function player_perception.tactile(player, budget)
  local pos = player:get_pos()
  local _, _, dir = perception.look(player)
  local horizontal = select(1, perception.normalize({x = dir.x, y = 0, z = dir.z}))
  local base = {
    x = math.floor(pos.x + 0.5),
    y = math.floor(pos.y + 0.5),
    z = math.floor(pos.z + 0.5),
  }
  local ahead = {
    x = math.floor(pos.x + horizontal.x + 0.5),
    y = base.y,
    z = math.floor(pos.z + horizontal.z + 0.5),
  }
  local ahead2 = {
    x = math.floor(pos.x + horizontal.x * 2 + 0.5),
    y = base.y,
    z = math.floor(pos.z + horizontal.z * 2 + 0.5),
  }

  local function probe(p)
    perception.spend(budget, 1)
    local sample = perception.node_at(p)
    local def = minetest.registered_nodes[sample.name]
    return {
      position = canonical.node_vector(p),
      name = sample.name,
      state = sample.state,
      walkable = def and def.walkable ~= false or false,
      climbable = (def and def.climbable) and true or false,
      liquid_type = (def and def.liquidtype) or "none",
      damage_per_second = math.floor((def and def.damage_per_second) or 0),
      semantics = semantics.tags_for_node_name(sample.name),
    }
  end

  local ground = probe({x = base.x, y = base.y - 1, z = base.z})
  local feet_ahead = probe(ahead)
  local body_ahead = probe({x = ahead.x, y = ahead.y + 1, z = ahead.z})
  local head_ahead = probe({x = ahead.x, y = ahead.y + 2, z = ahead.z})
  local above_head = probe({x = base.x, y = base.y + 2, z = base.z})

  -- Step height ahead: how far up the first standable surface sits. A value of
  -- one is a kerb a walker climbs; two or more is a wall.
  local step_height = canonical.NULL
  local step_reason = "no_surface"
  for dy = 0, 3 do
    perception.spend(budget, 1)
    local at = perception.node_at({x = ahead.x, y = ahead.y + dy, z = ahead.z})
    local above = perception.node_at({x = ahead.x, y = ahead.y + dy + 1, z = ahead.z})
    local at_def = minetest.registered_nodes[at.name]
    local above_def = minetest.registered_nodes[above.name]
    local at_solid = at_def and at_def.walkable ~= false
    local above_free = above.state == "loaded" and (not above_def or above_def.walkable == false)
    if at_solid and above_free then
      step_height = dy + 1
      step_reason = "standable"
      break
    end
    if not at_solid and dy == 0 then
      step_height = 0
      step_reason = "level_or_gap"
      break
    end
  end

  -- A pit ahead: how far down the ground goes in the next cell.
  local drop_ahead = canonical.NULL
  local surface_y = perception.surface_in_column(ahead.x, ahead.z, base.y, 6, budget,
    {clearance = 2})
  if surface_y then
    drop_ahead = (base.y - 1) - surface_y
  end

  local clearance = perception.head_clearance(base.x, base.y - 1, base.z, 4, budget)

  return {
    radius = settings.HARD.tactile_radius,
    ground_under_feet = ground,
    space_at_feet_ahead = feet_ahead,
    space_at_body_ahead = body_ahead,
    space_at_head_ahead = head_ahead,
    space_above_head = above_head,
    step_height_ahead = step_height,
    step_reason = step_reason,
    drop_ahead = drop_ahead,
    head_clearance = clearance,
    in_liquid = ground.liquid_type ~= "none",
    obstacle_ahead = feet_ahead.walkable or body_ahead.walkable,
    climbable_ahead = feet_ahead.climbable or body_ahead.climbable,
    two_ahead_position = canonical.node_vector(ahead2),
  }
end

-- === Vision rays ===

local function cast_fan(player, rays, limits, sector, budget)
  local pos = player:get_pos()
  local yaw, pitch = perception.look(player)
  local eye_height = perception.eye_height(player)
  local out, skipped = {}, 0

  local h_half = limits.horizontal_fov / 2
  local v_half = limits.vertical_fov / 2

  for _, ray in ipairs(rays) do
    local h = ray.yaw_offset
    local v = ray.pitch_offset
    local within = math.abs(h) <= h_half and math.abs(v) <= v_half
    if within and sector then
      within = h >= sector.h_min and h <= sector.h_max
        and v >= sector.v_min and v <= sector.v_max
    end
    if not within then
      skipped = skipped + 1
    else
      local height = LEVEL_HEIGHTS[ray.level] or eye_height
      local origin = {x = pos.x, y = pos.y + height, z = pos.z}
      -- Positive yaw offset means "to the right of the look direction"; the
      -- engine's yaw grows anticlockwise, hence the sign flip.
      local dir = perception.dir_from_angles(yaw - h * DEG, pitch + v * DEG)
      local hit = perception.cast_ray(origin, dir, limits.view_distance, budget)

      local record = {
        ray_id = ray.id,
        origin_level = ray.level,
        yaw_offset_deg = canonical.round(h),
        pitch_offset_deg = canonical.round(v),
        hit_type = hit.hit_type,
        distance = canonical.round(hit.distance),
        visible = hit.hit_type == "node",
        attenuated = hit.attenuated,
      }
      if hit.position then
        record.position = canonical.node_vector(hit.position)
        record.relative_position = canonical.node_vector({
          x = hit.position.x - math.floor(pos.x + 0.5),
          y = hit.position.y - math.floor(pos.y + 0.5),
          z = hit.position.z - math.floor(pos.z + 0.5),
        })
      else
        record.position = canonical.NULL
        record.relative_position = canonical.NULL
      end
      -- Things the ray went through on the way: a closed door, a pane of glass,
      -- a ladder. They are seen, so they are reported, but compactly.
      local passed = {}
      for _, entry in ipairs(hit.passed_nodes or {}) do
        passed[#passed + 1] = {
          position = canonical.node_vector(entry.position),
          name = entry.sample.name,
          distance = canonical.round(entry.distance),
          semantics = semantics.tags_for_node_name(entry.sample.name),
        }
      end
      record.passed_nodes = #passed > 0 and passed or canonical.EMPTY_ARRAY

      if hit.hit_type == "node" and hit.sample then
        record.node = semantics.describe_node(hit.sample.name, hit.sample.param2, hit.position)
      elseif hit.hit_type == "unloaded" then
        record.node = {available = false, reason = "map_not_loaded"}
      elseif hit.hit_type == "ignore" then
        record.node = {available = false, reason = "ignore"}
      else
        record.node = canonical.NULL
      end
      out[#out + 1] = record
    end
  end

  -- Sorted by id so the ray order in a response never depends on how the
  -- profile table happened to be built.
  table.sort(out, function(a, b) return a.ray_id < b.ray_id end)
  if #out == 0 then out = canonical.EMPTY_ARRAY end
  return out, skipped
end

player_perception.cast_fan = cast_fan

-- === Surface profile ===
--
-- A short strip of ground in the direction of view.
--
-- Two filters apply, and they model two different senses. The first few steps
-- are body space: a walker knows the ground under and immediately around its
-- feet by standing on it, so those samples are reported whatever the head is
-- doing. Every step beyond that must be inside the field of view *and* in line
-- of sight, exactly like anything else that is seen — a dip behind a wall stays
-- hidden.

--- Steps close enough to count as body space rather than sight.
player_perception.SURFACE_TACTILE_STEPS = 3

function player_perception.surface_profile(player, limits, budget)
  local pos = player:get_pos()
  local eye = perception.eye_position(player)
  local _, _, dir = perception.look(player)
  local horizontal = select(1, perception.normalize({x = dir.x, y = 0, z = dir.z}))
  local length = math.min(settings.HARD.surface_profile_length, math.floor(limits.view_distance))

  local base_y = math.floor(pos.y + 0.5) - 1
  local samples = {}
  local previous_y = base_y

  for step = 1, length do
    local x = math.floor(pos.x + horizontal.x * step + 0.5)
    local z = math.floor(pos.z + horizontal.z * step + 0.5)
    -- A walker's surface: the highest place with room to stand, searched from
    -- high enough above to catch a ledge it might climb.
    local ground_y, reason, sample, info = perception.surface_in_column(
      x, z, base_y + 6, 14, budget, {clearance = 2})
    local record = {
      step = step,
      relative_direction = "forward",
      position = {x = x, z = z},
    }
    if not ground_y then
      record.available = false
      record.reason = reason or "no_surface"
      record.gap = true
      samples[#samples + 1] = record
      if reason == "budget" then break end
    else
      -- Beyond body space, report only what the eye can actually reach.
      -- Without this the profile would leak terrain behind a wall, which is
      -- exactly what player mode must not do.
      local ground_point = {x = x, y = ground_y + 0.5, z = z}
      local visible, reject_reason = true, nil
      if step > player_perception.SURFACE_TACTILE_STEPS then
        local in_sector, sector_reason = perception.in_view_sector(eye, dir, ground_point, limits, nil)
        if not in_sector then
          visible, reject_reason = false, sector_reason
        else
          local clear = perception.line_of_sight(eye, ground_point, budget)
          if not clear then visible, reject_reason = false, "not_visible" end
        end
      end
      if not visible then
        record.available = false
        record.reason = reject_reason or "not_visible"
        samples[#samples + 1] = record
      else
        local def = sample and minetest.registered_nodes[sample.name] or nil
        local clearance = perception.head_clearance(x, ground_y, z, 4, budget)
        record.ground_y = ground_y
        record.ground_node = sample and sample.name or "unknown"
        record.slope = ground_y - previous_y
        record.gap = (ground_y < base_y - 2)
        record.water = (def and def.liquidtype or "none") ~= "none"
        record.obstacle_height = math.max(0, ground_y - base_y)
        record.head_clearance = clearance
        record.walkable = clearance >= 2
        -- The highest solid node in the column, which is not always the one a
        -- body would stand on: an overhang sits above its own floor.
        record.top_y = (info and info.top_y) or ground_y
        record.semantics = semantics.tags_for_node_name(sample and sample.name or "air")
        previous_y = ground_y
        samples[#samples + 1] = record
      end
    end
  end

  if #samples == 0 then samples = canonical.EMPTY_ARRAY end
  return {
    length = length,
    direction = canonical.vector(horizontal),
    samples = samples,
  }
end

-- === Visible semantic features ===
--
-- Recognition, not disclosure. A stretch of road the bot can see is reported as
-- road; where that road goes is not, because a player standing there would not
-- know either.

function player_perception.visible_features(player, limits, sector, budget, wanted)
  local hits = cast_fan(player, player_perception.FEATURE_FAN, limits, sector, budget)
  local found = {}
  local seen = {}
  local pos = player:get_pos()

  local base = {
    x = math.floor(pos.x + 0.5),
    y = math.floor(pos.y + 0.5),
    z = math.floor(pos.z + 0.5),
  }

  --- Record every recognised feature a node carries at a seen position.
  local function collect(node_name, node_semantics, position, distance, ray_id)
    for _, tag in ipairs(node_semantics or {}) do
      if ((not wanted) or tag == wanted) and semantics.is_known_feature(tag) then
        local key = tag .. "@" .. position.x .. ":" .. position.y .. ":" .. position.z
        if not seen[key] then
          seen[key] = true
          found[#found + 1] = {
            feature = tag,
            position = position,
            relative_position = {
              x = position.x - base.x, y = position.y - base.y, z = position.z - base.z,
            },
            distance = distance,
            node_name = node_name,
            ray_id = ray_id,
          }
        end
      end
    end
  end

  for _, hit in ipairs(hits == canonical.EMPTY_ARRAY and {} or hits) do
    -- Both what stopped the ray and what it passed through are seen: a door
    -- lets light past and is still perfectly visible.
    if hit.hit_type == "node" and type(hit.node) == "table" and hit.node.semantics then
      collect(hit.node.name, hit.node.semantics, hit.position, hit.distance, hit.ray_id)
    end
    for _, passed in ipairs(hit.passed_nodes == canonical.EMPTY_ARRAY and {} or (hit.passed_nodes or {})) do
      collect(passed.name, passed.semantics, passed.position, passed.distance, hit.ray_id)
    end
  end

  table.sort(found, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.feature ~= b.feature then return a.feature < b.feature end
    return a.ray_id < b.ray_id
  end)
  -- Keep the answer bounded; a dense fan across a village can see a lot of road.
  local capped = {}
  for i = 1, math.min(#found, 64) do capped[i] = found[i] end
  if #capped == 0 then capped = canonical.EMPTY_ARRAY end
  return capped, #found
end

-- === Operations ===

local function limits_of(bot)
  return bot.limits
end

--- Full observation.
function player_perception.observe(player, session, bot, params, budget)
  local limits = limits_of(bot)
  local profile = params.profile or settings.player_ray_profile
  local rays = player_perception.PROFILES[profile]
  local sector = params.sector

  -- Built cheapest and most essential first. If the budget runs out, what
  -- degrades is the wide feature sweep, never the body's own state or the
  -- ground it is standing on.
  local self_state = player_perception.self_state(player, session, budget)
  local tactile = player_perception.tactile(player, budget)
  local surface = player_perception.surface_profile(player, limits, budget)
  local ray_records, skipped = cast_fan(player, rays, limits, sector, budget)
  local visible, rejected = entities.visible_for(player, session, limits, sector, budget, {})
  local features = select(1, player_perception.visible_features(player, limits, sector, budget, nil))

  return {
    mode = "player",
    profile = profile,
    contract = "server_side_approximation",
    limits = {
      view_distance = limits.view_distance,
      horizontal_fov_deg = limits.horizontal_fov,
      vertical_fov_deg = limits.vertical_fov,
      max_entities = limits.max_entities,
    },
    self_state = self_state,
    tactile = tactile,
    rays = ray_records,
    rays_skipped_outside_sector = skipped,
    visible_entities = visible,
    entity_rejections = next(rejected) and rejected or {},
    visible_features = features,
    surface_profile = surface,
    budget = perception.budget_report(budget),
  }
end

--- A scan: the same machinery, restricted to a sub-sector of the field of view.
function player_perception.scan(player, session, bot, operation, params, budget)
  local limits = limits_of(bot)
  local sector = player_perception.sector_for(operation, limits)
  local profile = params.profile or settings.player_ray_profile
  local rays = player_perception.PROFILES[profile]
  local ray_records, skipped = cast_fan(player, rays, limits, sector, budget)
  local visible = entities.visible_for(player, session, limits, sector, budget, {})
  local features = select(1, player_perception.visible_features(player, limits, sector, budget, nil))

  return {
    mode = "player",
    operation = operation,
    profile = profile,
    sector_deg = {
      h_min = canonical.round(sector.h_min),
      h_max = canonical.round(sector.h_max),
      v_min = canonical.round(sector.v_min),
      v_max = canonical.round(sector.v_max),
    },
    note = "a scan narrows the reported sector; it never turns the player",
    rays = ray_records,
    rays_skipped_outside_sector = skipped,
    visible_entities = visible,
    visible_features = features,
    surface_profile = operation == "scan_forward"
      and player_perception.surface_profile(player, limits, budget) or canonical.NULL,
    budget = perception.budget_report(budget),
  }
end

--- What the crosshair points at.
--
-- This is the one place that uses the engine raycast, because "what would this
-- player select" is a question about pointability, which is exactly what
-- minetest.raycast answers. Sight-blocking and pointability are different
-- properties, and the answer says which one it used.
function player_perception.inspect_target(player, session, bot, params, budget)
  local limits = limits_of(bot)
  local eye = perception.eye_position(player)
  local _, _, dir = perception.look(player)
  local range = math.min(tonumber(params.max_distance) or limits.view_distance, limits.view_distance)
  local to = {
    x = eye.x + dir.x * range,
    y = eye.y + dir.y * range,
    z = eye.z + dir.z * range,
  }

  local result = {
    mode = "player",
    method = "engine_raycast_pointability",
    max_distance = canonical.round(range),
    target = canonical.NULL,
  }

  local ok, iterator = pcall(minetest.raycast, eye, to, true, false)
  if not ok or not iterator then
    result.target = {available = false, reason = "unsupported_by_server_api"}
    return result
  end

  for pointed in iterator do
    if pointed.type == "node" and pointed.under then
      local sample = perception.node_at(pointed.under)
      local distance = perception.distance(eye, pointed.under)
      result.target = {
        hit_type = "node",
        position = canonical.node_vector(pointed.under),
        place_position = canonical.node_vector(pointed.above or pointed.under),
        distance = canonical.round(distance),
        within_reach = distance <= 5,
        node = semantics.describe_node(sample.name, sample.param2, pointed.under),
      }
      return result
    elseif pointed.type == "object" and pointed.ref then
      if pointed.ref ~= player then
        local descriptor = entities.describe(session, pointed.ref, eye,
          {observer_id = entities.id_for(session, player)})
        if descriptor then
          result.target = {
            hit_type = "object",
            distance = descriptor.distance,
            within_reach = descriptor.distance <= 5,
            entity = descriptor,
          }
          return result
        end
      end
    end
  end
  return result
end

--- Objects the bot can see, optionally filtered by kind or semantic tag.
function player_perception.find_visible_entity(player, session, bot, params, budget)
  local limits = limits_of(bot)
  local visible, rejected = entities.visible_for(player, session, limits, params.sector, budget, {})
  local wanted_kind = params.kind
  local wanted_tag = params.tag
  local matches = {}
  for _, descriptor in ipairs(visible == canonical.EMPTY_ARRAY and {} or visible) do
    local ok = true
    if wanted_kind and descriptor.kind ~= wanted_kind then ok = false end
    if ok and wanted_tag and not semantics.has_tag(descriptor.semantic_tags, wanted_tag) then
      ok = false
    end
    if ok then matches[#matches + 1] = descriptor end
  end
  return {
    mode = "player",
    kind = wanted_kind or canonical.NULL,
    tag = wanted_tag or canonical.NULL,
    matches = #matches > 0 and matches or canonical.EMPTY_ARRAY,
    match_count = #matches,
    considered = (visible == canonical.EMPTY_ARRAY) and 0 or #visible,
    rejections = next(rejected) and rejected or {},
    budget = perception.budget_report(budget),
  }
end

--- Features the bot can see, optionally filtered to one feature name.
function player_perception.find_visible_feature(player, session, bot, params, budget)
  local limits = limits_of(bot)
  local matches, total = player_perception.visible_features(
    player, limits, params.sector, budget, params.feature)
  return {
    mode = "player",
    feature = params.feature or canonical.NULL,
    matches = matches,
    match_count = total,
    truncated = total > ((matches == canonical.EMPTY_ARRAY) and 0 or #matches),
    known_features = semantics.FEATURES,
    budget = perception.budget_report(budget),
  }
end

function player_perception.get_self_state(player, session, bot, params, budget)
  return {
    mode = "player",
    self_state = player_perception.self_state(player, session, budget),
    budget = perception.budget_report(budget),
  }
end

--- Operations player mode answers. Anything else is refused with
--- operation_not_allowed, which is how an arbitrary get_nodes request dies.
player_perception.OPERATIONS = {
  observe = player_perception.observe,
  scan_forward = true,
  scan_left = true,
  scan_right = true,
  scan_up = true,
  scan_down = true,
  inspect_target = player_perception.inspect_target,
  find_visible_entity = player_perception.find_visible_entity,
  find_visible_feature = player_perception.find_visible_feature,
  get_self_state = player_perception.get_self_state,
}

function player_perception.list_operations()
  local out = {}
  for name in pairs(player_perception.OPERATIONS) do out[#out + 1] = name end
  out[#out + 1] = "poll_events"
  table.sort(out)
  return out
end

function player_perception.dispatch(operation, player, session, bot, params, budget)
  if operation:sub(1, 5) == "scan_" then
    return player_perception.scan(player, session, bot, operation, params, budget)
  end
  local handler = player_perception.OPERATIONS[operation]
  if type(handler) ~= "function" then return nil end
  return handler(player, session, bot, params, budget)
end

return player_perception
