-- pw_player_bot/tests/support.lua
--
-- Helpers for the bot tests: a scratch memory built by hand, and a synthetic
-- observation so the decision layers can be exercised without a world.
--
-- Building memory directly is not a shortcut around the real path — the
-- integration tests take that path in full. It is how the routing and scoring
-- layers get deterministic, legible inputs, which a live world cannot give.

local P = pw_player_bot
local bridge = pw_bot_bridge
local support = {}
P.impl.test_support = support

support.SCRATCH_BOT = "pw_brain_probe"
support.ACTOR = bridge.SERVER_ACTOR

function support.test_player_name()
  return minetest.settings:get("perfectworld.test_player") or "pwbot"
end

function support.require_player(ctx)
  local name = ctx.player_name
  if not name or name == "" then name = support.test_player_name() end
  local player = minetest.get_player_by_name(name)
  if not player then
    return nil, nil, "test player '" .. tostring(name) .. "' is not connected"
  end
  return player, name
end

-- === Synthetic memory ===

--- A flat, fully remembered plateau of walkable ground.
function support.flat_memory(radius, ground_y, options)
  options = options or {}
  local memory = P.impl.memory
  local memo = memory.new(support.SCRATCH_BOT)
  memo.tick = options.tick or 10
  radius = radius or 6
  ground_y = ground_y or 10
  for x = -radius, radius do
    for z = -radius, radius do
      memory.learn_cell(memo, x, z, {
        ground_y = ground_y,
        walkable = true,
        water = false,
        hazard = false,
        head_clearance = 3,
        node_name = "test:ground",
        semantics = {"ground"},
      }, options.confidence or 0.9)
    end
  end
  memo.last_position = {x = 0, y = ground_y + 1, z = 0}
  memo.last_yaw = 0
  memo.last_pitch = 0
  memo.last_hp = options.hp or 20
  memo.last_in_liquid = options.in_liquid or false
  memo.last_on_ground = true
  return memo
end

--- Replace one column, so a test can carve a wall, a pit or a pool.
function support.set_cell(memo, x, z, fields)
  local memory = P.impl.memory
  local key = memory.cell_key(x, z)
  local cell = memo.cells[key]
  if not cell then return nil end
  for name, value in pairs(fields) do cell[name] = value end
  return cell
end

--- Remove a column entirely: the bot has never seen this place.
function support.forget_cell(memo, x, z)
  local memory = P.impl.memory
  local key = memory.cell_key(x, z)
  if memo.cells[key] then
    memo.cells[key] = nil
    memo.cell_count = memo.cell_count - 1
    return true
  end
  return false
end

--- A wall of unremembered columns at a given x, splitting the plateau in two.
function support.forget_column(memo, x, from_z, to_z)
  local removed = 0
  for z = from_z, to_z do
    if support.forget_cell(memo, x, z) then removed = removed + 1 end
  end
  return removed
end

-- === Synthetic observation ===

--- The shape of a player-mode observation, filled in enough for memory to
--- integrate it. Fields the bot does not read are omitted rather than faked.
function support.observation(options)
  options = options or {}
  local position = options.position or {x = 0, y = 11, z = 0}
  local ground_y = position.y - 1
  local samples = {}
  for step = 1, (options.strip or 6) do
    samples[#samples + 1] = {
      step = step,
      position = {x = position.x, z = position.z + step},
      ground_y = ground_y,
      ground_node = "test:ground",
      slope = 0,
      gap = false,
      water = false,
      obstacle_height = 0,
      head_clearance = 3,
      walkable = true,
      semantics = {"ground"},
    }
  end
  return {
    mode = "player",
    profile = "navigation",
    contract = "server_side_approximation",
    self_state = {
      player_name = support.SCRATCH_BOT,
      connected = true,
      position = position,
      yaw = options.yaw or 0,
      pitch = 0,
      hp = options.hp or 20,
      on_ground = true,
      in_liquid = options.in_liquid or false,
      node_under = {
        name = "test:ground",
        state = "loaded",
        position = {x = position.x, y = ground_y, z = position.z},
        semantics = {"ground"},
      },
    },
    tactile = {
      radius = 2,
      ground_under_feet = {name = "test:ground", walkable = true, semantics = {"ground"}},
      space_at_feet_ahead = {
        name = "air", walkable = false, liquid_type = "none",
        damage_per_second = 0, semantics = {"passable"},
        position = {x = position.x, y = position.y, z = position.z + 1},
      },
      space_at_body_ahead = {name = "air", walkable = false, semantics = {"passable"}},
      head_clearance = 3,
      drop_ahead = 0,
      step_height_ahead = 0,
    },
    rays = options.rays or {},
    visible_entities = options.entities or {},
    visible_features = options.features or {},
    surface_profile = {length = #samples, samples = samples},
  }
end

--- A feature record as the bridge would report it.
function support.feature(name, x, y, z)
  return {
    feature = name,
    position = {x = x, y = y, z = z},
    relative_position = {x = x, y = y, z = z},
    distance = math.sqrt(x * x + z * z),
    node_name = "test:" .. name,
    ray_id = "body_c",
  }
end

-- === Bot lifecycle ===

--- Register the scratch bot with the bridge and start a brain for it.
function support.scratch_brain()
  bridge.unregister_bot(support.SCRATCH_BOT, support.ACTOR)
  bridge.register_bot(support.SCRATCH_BOT, {mode = "player"}, support.ACTOR)
  P.forget(support.SCRATCH_BOT, support.ACTOR)
  P.stop(support.SCRATCH_BOT, support.ACTOR)
  return P.start(support.SCRATCH_BOT, support.ACTOR)
end

function support.drop_scratch_brain()
  P.stop(support.SCRATCH_BOT, support.ACTOR)
  P.forget(support.SCRATCH_BOT, support.ACTOR)
  bridge.unregister_bot(support.SCRATCH_BOT, support.ACTOR)
end

--- Somewhere flat, dry and dull to run an integration test from.
support.SCRATCH_GROUND = {x = 31337, y = 24, z = -31337}

--- Put the test player on ordinary ground for the duration of `fn`.
--
-- Integration tests otherwise inherit whatever position the world last left the
-- player in — after a diagnostic that teleported them into a lake, for one. A
-- bot standing in water is *right* to re-decide every tick, because safety
-- overrides holding on to a plan, so a test about not dithering that runs from
-- a lake is measuring the lake.
--
-- The platform is built rather than searched for: a test that goes looking for
-- suitable ground is only as reliable as the ground it happens to find.
function support.on_ordinary_ground(player, fn)
  local origin = support.SCRATCH_GROUND
  local ground = (perfectworld and perfectworld.compat
    and perfectworld.compat.get_material("ground", {required = false}))
    or "mcl_core:dirt"
  local radius = 10
  for x = origin.x - radius, origin.x + radius do
    for z = origin.z - radius, origin.z + radius do
      minetest.set_node({x = x, y = origin.y - 1, z = z}, {name = ground})
      for dy = 0, 4 do
        minetest.set_node({x = x, y = origin.y + dy, z = z}, {name = "air"})
      end
    end
  end

  local previous = player:get_pos()
  player:set_pos({x = origin.x, y = origin.y, z = origin.z})
  local ok, err = pcall(fn)
  if previous then player:set_pos(previous) end
  if not ok then error(err, 0) end
end

--- Restore whatever brain and bridge state a real player had.
function support.with_bot_state(player_name, fn)
  local was_thinking = P.is_thinking(player_name)
  local bridge_bot = bridge.get_bot(player_name)
  local ok, err = pcall(fn)
  if not was_thinking then
    P.stop(player_name, support.ACTOR)
  end
  if bridge_bot then
    bridge.register_bot(bridge_bot.player_name, {
      mode = bridge_bot.mode,
      enabled = bridge_bot.enabled,
      limits = bridge_bot.limits,
    }, support.ACTOR)
  else
    bridge.unregister_bot(player_name, support.ACTOR)
  end
  if not ok then error(err) end
end

return support
