-- pw_bot_bridge/tests/support.lua
--
-- Shared helpers for the bridge tests: a scratch bot that is not a real player,
-- a scratch area of the map that is snapshotted and restored, and the guards
-- that decide when a test must SKIP instead of lying.

local B = pw_bot_bridge
local support = {}
B.impl.test_support = support

support.SCRATCH_BOT = "pw_bridge_probe"
support.ACTOR = B.SERVER_ACTOR

--- Register a bot that no player is behind. Enough to exercise the registry,
--- validation and limits; every observation against it fails with
--- player_not_connected, which is itself worth asserting.
function support.scratch_bot(mode, limits)
  B.unregister_bot(support.SCRATCH_BOT, support.ACTOR)
  return B.register_bot(support.SCRATCH_BOT, {
    mode = mode or "player",
    limits = limits,
    note = "test scratch bot",
  }, support.ACTOR)
end

function support.drop_scratch_bot()
  B.unregister_bot(support.SCRATCH_BOT, support.ACTOR)
end

function support.test_player_name()
  return minetest.settings:get("perfectworld.test_player") or "pwbot"
end

--- The connected test player, or nil with a reason.
function support.require_player(ctx)
  local name = ctx.player_name
  if not name or name == "" then name = support.test_player_name() end
  local player = minetest.get_player_by_name(name)
  if not player then
    return nil, nil, "test player '" .. tostring(name) .. "' is not connected"
  end
  return player, name
end

-- === Scratch area ===
--
-- Scenes are built in the air above wherever the test player stands. That
-- guarantees the blocks are loaded (the player is keeping them loaded) without
-- disturbing generated terrain, and everything is put back afterwards.

-- The box must be deep enough to hold every scene feature, including a pit:
-- anything a scene writes outside these bounds would never be restored.
support.SCENE_HEIGHT = 30
support.SCENE_RADIUS = 12
support.SCENE_UP = 10
support.SCENE_DOWN = 7

function support.scene_origin(player)
  local pos = player:get_pos()
  return {
    x = math.floor(pos.x + 0.5),
    y = math.floor(pos.y + 0.5) + support.SCENE_HEIGHT,
    z = math.floor(pos.z + 0.5),
  }
end

function support.scene_bounds(origin)
  return {
    x = origin.x - support.SCENE_RADIUS,
    y = origin.y - support.SCENE_DOWN,
    z = origin.z - support.SCENE_RADIUS,
  }, {
    x = origin.x + support.SCENE_RADIUS,
    y = origin.y + support.SCENE_UP,
    z = origin.z + support.SCENE_RADIUS,
  }
end

--- Is every node of the scene box loaded? Building into an unloaded block would
--- silently do nothing, and a test that asserts against nothing is worthless.
function support.area_is_loaded(min, max)
  for y = min.y, max.y, 4 do
    for z = min.z, max.z, 4 do
      for x = min.x, max.x, 4 do
        if not minetest.get_node_or_nil({x = x, y = y, z = z}) then
          return false, {x = x, y = y, z = z}
        end
      end
    end
  end
  return true
end

--- Capture and restore through a voxel manipulator.
--
-- Thousands of set_node calls would be both slow and loud: every one of them
-- fires the game's own node callbacks, and Mineclonia's redstone queue fills up
-- long before a scene is finished. A voxel manipulator writes the same nodes
-- without waking any of that, which keeps the server log clean enough for the
-- project's error scan to mean something.
function support.snapshot(min, max)
  local vm = minetest.get_voxel_manip()
  local emin, emax = vm:read_from_map(min, max)
  return {
    min = min,
    max = max,
    emin = emin,
    emax = emax,
    data = vm:get_data(),
    param2 = vm:get_param2_data(),
  }
end

function support.restore(snapshot)
  local vm = minetest.get_voxel_manip()
  local emin, emax = vm:read_from_map(snapshot.min, snapshot.max)
  if not vector.equals(emin, snapshot.emin) or not vector.equals(emax, snapshot.emax) then
    -- The emerged area moved, so the captured arrays no longer line up with it.
    -- Restoring them would scramble the map; refusing is the safe answer.
    minetest.log("error", "[pw_bot_bridge] scene restore skipped: emerged area changed")
    return false
  end
  vm:set_data(snapshot.data)
  vm:set_param2_data(snapshot.param2)
  vm:write_to_map(true)
  return true
end

function support.fill(min, max, node_name)
  local content = minetest.get_content_id(node_name)
  local vm = minetest.get_voxel_manip()
  local emin, emax = vm:read_from_map(min, max)
  local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
  local data = vm:get_data()
  local param2 = vm:get_param2_data()
  for z = min.z, max.z do
    for y = min.y, max.y do
      local index = area:index(min.x, y, z)
      for _ = min.x, max.x do
        data[index] = content
        param2[index] = 0
        index = index + 1
      end
    end
  end
  vm:set_data(data)
  vm:set_param2_data(param2)
  vm:write_to_map(true)
end

--- Objects the scene spawned, so they can be removed whatever happens.
function support.new_spawn_tracker()
  local spawned = {}
  return {
    add = function(object)
      if object then spawned[#spawned + 1] = object end
      return object
    end,
    clear = function()
      for _, object in ipairs(spawned) do
        if object and object.remove then pcall(function() object:remove() end) end
      end
      spawned = {}
    end,
  }
end

--- Spawn something a bot can plausibly see. Prefers a boat, because that is the
--- object PerfectWorld's future harbour work cares about; falls back to a
--- dropped item, and returns nil when neither is available.
function support.spawn_visible_object(pos)
  if minetest.registered_entities["mcl_boats:boat"] then
    local ok, object = pcall(minetest.add_entity, pos, "mcl_boats:boat")
    if ok and object then return object, "mcl_boats:boat" end
  end
  local item = perfectworld.compat and perfectworld.compat.get_material("cobble", {required = false})
  if item and item ~= "air" then
    local ok, object = pcall(minetest.add_item, pos, item)
    if ok and object then return object, "__builtin:item" end
  end
  return nil
end

-- === Player state that the harness, not the bridge, is allowed to change ===
--
-- The bridge never moves a player or turns a head. A test harness must, because
-- that is what a real client would do, so those actions live here where they are
-- obvious and always undone.

function support.capture_player(player)
  return {
    pos = player:get_pos(),
    yaw = player:get_look_horizontal(),
    pitch = player:get_look_vertical(),
  }
end

function support.restore_player(player, state)
  pcall(function()
    if player:get_attach() then player:set_detach() end
  end)
  player:set_pos(state.pos)
  player:set_look_horizontal(state.yaw)
  player:set_look_vertical(state.pitch)
end

function support.place_player(player, pos, yaw, pitch)
  player:set_pos(pos)
  player:set_look_horizontal(yaw or 0)
  player:set_look_vertical(pitch or 0)

  -- And stop them falling.
  --
  -- `set_pos` moves a player without touching their velocity, so one who was
  -- dropping when the test began is still dropping after it has stood them on
  -- the scene's floor — and `on_ground` is derived from vertical velocity, so
  -- the scene reports a player in mid-air on solid ground. It passed for as
  -- long as the test world happened to leave the player standing still, and
  -- failed the first time a fresh world spawned them on a slope.
  if player.get_velocity and player.add_velocity then
    local velocity = player:get_velocity()
    if velocity then
      player:add_velocity({x = -velocity.x, y = -velocity.y, z = -velocity.z})
    end
  end
end

-- === Request helpers ===

local counter = 0

function support.request(operation, params)
  counter = counter + 1
  return {
    protocol = B.PROTOCOL,
    request_id = string.format("test-%06d", counter),
    operation = operation,
    parameters = params or {},
  }
end

function support.observe(player_name, operation, params)
  return B.observe(player_name, support.request(operation, params))
end

--- Does a response mention this string anywhere? The bluntest possible leak
--- check, and the right one: if a hidden node's name appears anywhere in the
--- canonical JSON, player mode leaked it, whatever field it hid in.
function support.mentions(envelope, needle)
  return B.encode_canonical(envelope):find(needle, 1, true) ~= nil
end

--- Restore a bot to a known registration when a test is done with it.
function support.with_bot_state(player_name, fn)
  local before = B.get_bot(player_name)
  local ok, err = pcall(fn)
  if before then
    B.register_bot(before.player_name, {
      mode = before.mode,
      enabled = before.enabled,
      limits = before.limits,
      note = before.note,
    }, support.ACTOR)
  else
    B.unregister_bot(player_name, support.ACTOR)
  end
  if not ok then error(err) end
end

return support
