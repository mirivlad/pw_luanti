-- pw_bot_bridge/perception.lua
--
-- The geometry both providers share: where the eye is, which way it points,
-- what a ray runs into, and whether one point can see another.
--
-- Everything here is a *server-side approximation*. The server knows the
-- player's position, yaw and pitch, the nodes and the objects. It does not know
-- the client's FOV setting, its render distance, its texture pack or which
-- pixels the GPU actually drew. See docs/pw-bot/limitations.md.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local semantics = B.impl.semantics
local settings = B.impl.settings
local perception = {}
B.impl.perception = perception

local EPSILON = 1e-9
local DEG = math.pi / 180

perception.DEG = DEG

-- === Budgets ===
--
-- A budget makes an observation refuse to become a server stall. Every loop
-- that touches the map spends from it, and the caller reports the truncation
-- instead of silently returning a short answer.

function perception.new_budget(node_allowance, microseconds)
  return {
    nodes_left = node_allowance or settings.oracle_max_nodes,
    nodes_used = 0,
    started_us = minetest.get_us_time(),
    deadline_us = minetest.get_us_time() + (microseconds or settings.HARD.request_budget_us),
    truncated = false,
    truncated_reason = nil,
  }
end

function perception.spend(budget, count)
  if not budget then return true end
  count = count or 1
  budget.nodes_left = budget.nodes_left - count
  budget.nodes_used = budget.nodes_used + count
  if budget.nodes_left < 0 then
    budget.truncated = true
    budget.truncated_reason = budget.truncated_reason or "node_budget_exhausted"
    return false
  end
  -- Checking the clock on every node would cost more than it saves; every 256
  -- nodes is fine granularity for a 40 ms budget.
  if budget.nodes_used % 256 == 0 and minetest.get_us_time() > budget.deadline_us then
    budget.truncated = true
    budget.truncated_reason = budget.truncated_reason or "time_budget_exhausted"
    return false
  end
  return true
end

function perception.budget_report(budget)
  if not budget then return nil end
  return {
    nodes_examined = budget.nodes_used,
    elapsed_us = minetest.get_us_time() - budget.started_us,
    truncated = budget.truncated,
    truncated_reason = budget.truncated_reason or canonical.NULL,
  }
end

-- === Map access ===

--- Read a node without ever asking the engine to generate or load anything.
--
-- Three different "nothing here" answers must stay distinguishable:
--   not_loaded  -- the server has no data for this block
--   ignore      -- the block exists but this node is the ignore placeholder
--   unknown     -- a real node whose name no mod registered
function perception.node_at(pos)
  local node = minetest.get_node_or_nil(pos)
  if not node then
    return {name = "ignore", param2 = 0, state = "not_loaded"}
  end
  if node.name == "ignore" then
    return {name = "ignore", param2 = node.param2 or 0, state = "ignore"}
  end
  if node.name ~= "air" and not minetest.registered_nodes[node.name] then
    return {name = node.name, param2 = node.param2 or 0, state = "unknown"}
  end
  return {name = node.name, param2 = node.param2 or 0, state = "loaded"}
end

--- Would a sight line stop at this node?
local function stops_sight(sample)
  if sample.state == "not_loaded" or sample.state == "ignore" then
    -- The bridge cannot claim to see through data it does not have.
    return true
  end
  if sample.state == "unknown" then return true end
  return semantics.blocks_sight(minetest.registered_nodes[sample.name])
end

perception.stops_sight = stops_sight

-- === Angles ===

--- Luanti's own convention: yaw 0 looks towards +Z, positive pitch looks up.
function perception.dir_from_angles(yaw, pitch)
  local cp = math.cos(pitch)
  return {
    x = -math.sin(yaw) * cp,
    y = math.sin(pitch),
    z = math.cos(yaw) * cp,
  }
end

function perception.normalize(v)
  local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  if len < EPSILON then return {x = 0, y = 0, z = 1}, 0 end
  return {x = v.x / len, y = v.y / len, z = v.z / len}, len
end

function perception.distance(a, b)
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Horizontal and vertical offset of `target` from a look direction, in degrees.
--
-- Horizontal is the angle between the two directions projected onto XZ;
-- vertical is the difference of elevation angles. Splitting them this way
-- matches how a rectangular screen clips, which a single cone angle does not.
function perception.angular_offset(dir, to_target)
  local dh = math.sqrt(dir.x * dir.x + dir.z * dir.z)
  local th = math.sqrt(to_target.x * to_target.x + to_target.z * to_target.z)
  local horizontal
  if dh < EPSILON or th < EPSILON then
    horizontal = 0
  else
    local dot = (dir.x * to_target.x + dir.z * to_target.z) / (dh * th)
    dot = math.max(-1, math.min(1, dot))
    horizontal = math.acos(dot) / DEG
  end
  local dir_len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
  local tgt_len = math.sqrt(to_target.x * to_target.x + to_target.y * to_target.y + to_target.z * to_target.z)
  local elev_dir = dir_len < EPSILON and 0 or math.asin(math.max(-1, math.min(1, dir.y / dir_len)))
  local elev_tgt = tgt_len < EPSILON and 0 or math.asin(math.max(-1, math.min(1, to_target.y / tgt_len)))
  local vertical = (elev_tgt - elev_dir) / DEG
  return horizontal, vertical
end

--- Signed horizontal offset: negative left of the look direction, positive right.
function perception.signed_horizontal_offset(dir, to_target)
  local horizontal = select(1, perception.angular_offset(dir, to_target))
  -- Cross product of the XZ projections tells which side the target is on.
  local cross = dir.z * to_target.x - dir.x * to_target.z
  if cross < 0 then return -horizontal end
  return horizontal
end

-- === Player body ===

perception.DEFAULT_EYE_HEIGHT = 1.625

function perception.eye_height(player)
  local props = player.get_properties and player:get_properties() or nil
  local height = props and tonumber(props.eye_height) or nil
  if not height or height <= 0 then return perception.DEFAULT_EYE_HEIGHT end
  return height
end

function perception.eye_position(player)
  local pos = player:get_pos()
  return {x = pos.x, y = pos.y + perception.eye_height(player), z = pos.z}, pos
end

function perception.look(player)
  local yaw = player:get_look_horizontal()
  local pitch = player:get_look_vertical()
  return yaw, pitch, perception.dir_from_angles(yaw, pitch)
end

-- === Voxel traversal ===

--- Amanatides & Woo grid traversal.
--
-- Node (x, y, z) owns the cube [x-0.5, x+0.5) on each axis, which is what
-- `math.floor(v + 0.5)` implements. `visit(x, y, z, t)` returns false to stop.
function perception.dda(origin, dir, max_distance, visit)
  local d = select(1, perception.normalize(dir))
  local ix = math.floor(origin.x + 0.5)
  local iy = math.floor(origin.y + 0.5)
  local iz = math.floor(origin.z + 0.5)

  local function axis_setup(o, i, delta)
    if math.abs(delta) < EPSILON then
      return 0, math.huge, math.huge
    end
    local step = delta > 0 and 1 or -1
    local boundary = i + step * 0.5
    return step, (boundary - o) / delta, math.abs(1 / delta)
  end

  local sx, tx, dx = axis_setup(origin.x, ix, d.x)
  local sy, ty, dy = axis_setup(origin.y, iy, d.y)
  local sz, tz, dz = axis_setup(origin.z, iz, d.z)

  local t = 0
  -- Each step crosses one plane; a ray of length L crosses at most 3L+3.
  local guard = math.floor(max_distance * 3) + 8
  while t <= max_distance and guard > 0 do
    if visit(ix, iy, iz, t) == false then return end
    guard = guard - 1
    if tx <= ty and tx <= tz then
      t = tx; ix = ix + sx; tx = tx + dx
    elseif ty <= tz then
      t = ty; iy = iy + sy; ty = ty + dy
    else
      t = tz; iz = iz + sz; tz = tz + dz
    end
  end
end

--- Cast one ray and report where sight stops.
--
-- Returns a hit table. `hit_type` is one of:
--   node      -- a sight-blocking node
--   unloaded  -- the server has no map data there
--   ignore    -- an ignore placeholder
--   none      -- nothing blocked sight inside max_distance
--
-- The terminal hit is not the whole story. A closed door, a pane of glass and a
-- ladder are all things a player plainly sees and none of them stop light, so
-- the ray also records the solid-but-see-through nodes it passed through, up to
-- `opts.max_passed`. Without that, "is there a door ahead?" could never be
-- answered from a ray fan.
perception.MAX_PASSED_NODES = 4

function perception.cast_ray(origin, dir, max_distance, budget, opts)
  opts = opts or {}
  local max_passed = opts.max_passed or perception.MAX_PASSED_NODES
  local result = {
    hit_type = "none",
    distance = max_distance,
    position = nil,
    sample = nil,
    passed_through = 0,
    passed_nodes = {},
    attenuated = false,
  }
  local skip_origin = opts.skip_origin ~= false
  perception.dda(origin, dir, max_distance, function(x, y, z, t)
    if skip_origin and t == 0 then return true end
    if not perception.spend(budget, 1) then
      result.hit_type = "budget"
      result.distance = t
      result.position = {x = x, y = y, z = z}
      return false
    end
    local pos = {x = x, y = y, z = z}
    local sample = perception.node_at(pos)
    if sample.state == "not_loaded" then
      result.hit_type = "unloaded"
      result.distance = t
      result.position = pos
      result.sample = sample
      return false
    end
    if sample.state == "ignore" then
      result.hit_type = "ignore"
      result.distance = t
      result.position = pos
      result.sample = sample
      return false
    end
    local def = minetest.registered_nodes[sample.name]
    if semantics.attenuates_sight(def) then
      result.attenuated = true
    end
    if stops_sight(sample) then
      result.hit_type = "node"
      result.distance = t
      result.position = pos
      result.sample = sample
      return false
    end
    result.passed_through = result.passed_through + 1
    if sample.name ~= "air" and #result.passed_nodes < max_passed then
      result.passed_nodes[#result.passed_nodes + 1] = {
        position = pos,
        sample = sample,
        distance = t,
      }
    end
    return true
  end)
  return result
end

--- Can `from` see `to`?
--
-- The voxel holding the target is excluded, otherwise a solid target would
-- always occlude itself. Returns ok, blocking position, reason.
function perception.line_of_sight(from, to, budget)
  local dir, length = perception.normalize({
    x = to.x - from.x, y = to.y - from.y, z = to.z - from.z,
  })
  if length < EPSILON then return true end
  local target = {
    x = math.floor(to.x + 0.5),
    y = math.floor(to.y + 0.5),
    z = math.floor(to.z + 0.5),
  }
  local blocked, blocker, reason = false, nil, nil
  perception.dda(from, dir, length, function(x, y, z, t)
    if t == 0 then return true end
    if x == target.x and y == target.y and z == target.z then return false end
    if not perception.spend(budget, 1) then
      blocked, reason = true, "budget"
      return false
    end
    local sample = perception.node_at({x = x, y = y, z = z})
    if sample.state == "not_loaded" then
      blocked, blocker, reason = true, {x = x, y = y, z = z}, "not_loaded"
      return false
    end
    if stops_sight(sample) then
      blocked, blocker, reason = true, {x = x, y = y, z = z}, "occluded"
      return false
    end
    return true
  end)
  if blocked then return false, blocker, reason end
  return true
end

-- === Field of view ===

--- Is `target` inside the permitted view sector?
-- `sector` narrows the FOV further (used by scan_left and friends) and is given
-- as {h_min, h_max, v_min, v_max} in degrees, signed relative to the look
-- direction. It can only ever be a subset of the configured FOV.
function perception.in_view_sector(eye, dir, target, limits, sector)
  local to_target = {x = target.x - eye.x, y = target.y - eye.y, z = target.z - eye.z}
  local distance = math.sqrt(to_target.x ^ 2 + to_target.y ^ 2 + to_target.z ^ 2)
  if distance > limits.view_distance then
    return false, "out_of_range", distance
  end
  local horizontal = perception.signed_horizontal_offset(dir, to_target)
  local _, vertical = perception.angular_offset(dir, to_target)
  local h_half = limits.horizontal_fov / 2
  local v_half = limits.vertical_fov / 2
  if math.abs(horizontal) > h_half then
    return false, "outside_horizontal_fov", distance, horizontal, vertical
  end
  if math.abs(vertical) > v_half then
    return false, "outside_vertical_fov", distance, horizontal, vertical
  end
  if sector then
    if horizontal < sector.h_min or horizontal > sector.h_max
      or vertical < sector.v_min or vertical > sector.v_max then
      return false, "outside_scan_sector", distance, horizontal, vertical
    end
  end
  return true, nil, distance, horizontal, vertical
end

-- === Surfaces ===

--- Find the ground in a column, searching downwards from `from_y`.
--
-- `opts.clearance` is what makes this useful to a walker rather than to a map
-- viewer. With 0 it returns the topmost surface, which is what a diagnostic
-- wants. With 2 it returns the topmost surface that has room to stand on,
-- which is what a body wants: the floor of a covered passage rather than its
-- roof.
--
-- A liquid counts as a surface. A walker needs to know that the ground ahead is
-- water; reporting the stone under the water instead would hide exactly the
-- fact that matters.
--
-- Returns ground_y, reason, sample, info. `info.top_y` is the highest solid
-- node seen, whether or not it was standable. nil ground_y with a reason keeps
-- "nothing here", "not loaded" and "out of budget" distinguishable.
function perception.surface_in_column(x, z, from_y, depth, budget, opts)
  opts = opts or {}
  local need_clearance = opts.clearance or 0
  local top_y, top_sample = nil, nil
  local free_run = 0
  for y = from_y, from_y - depth, -1 do
    if not perception.spend(budget, 1) then
      return nil, "budget", nil, {top_y = top_y, top_sample = top_sample}
    end
    local sample = perception.node_at({x = x, y = y, z = z})
    if sample.state == "not_loaded" then
      return nil, "not_loaded", nil, {top_y = top_y, top_sample = top_sample}
    end
    if sample.state == "ignore" then
      return nil, "ignore", nil, {top_y = top_y, top_sample = top_sample}
    end
    local def = minetest.registered_nodes[sample.name]
    local liquid = (def and def.liquidtype) or "none"
    local is_surface = (def and def.walkable ~= false) or liquid ~= "none"
    if is_surface then
      if not top_y then top_y, top_sample = y, sample end
      if free_run >= need_clearance then
        return y, nil, sample, {
          top_y = top_y, top_sample = top_sample, clearance = free_run,
        }
      end
      free_run = 0
    else
      free_run = free_run + 1
    end
  end
  return nil, "no_surface", nil, {top_y = top_y, top_sample = top_sample}
end

--- How much empty space stands above a node, up to `max_height`.
function perception.head_clearance(x, y, z, max_height, budget)
  local clearance = 0
  for step = 1, max_height do
    if not perception.spend(budget, 1) then break end
    local sample = perception.node_at({x = x, y = y + step, z = z})
    if sample.state ~= "loaded" then break end
    local def = minetest.registered_nodes[sample.name]
    if def and def.walkable ~= false then break end
    clearance = clearance + 1
  end
  return clearance
end

--- Node description with position, ready to embed in a response.
function perception.describe_at(pos, budget)
  perception.spend(budget, 1)
  local sample = perception.node_at(pos)
  if sample.state == "not_loaded" then
    return {
      position = canonical.node_vector(pos),
      available = false,
      reason = "map_not_loaded",
    }
  end
  local described = semantics.describe_node(sample.name, sample.param2, pos)
  described.position = canonical.node_vector(pos)
  described.state = sample.state
  return described
end

return perception
