-- pw_bot_bridge/tests/scenes.lua
--
-- Deterministic scenes built in the real world, observed through the real API.
--
-- Every scene is assembled in the air above the connected test player, so the
-- blocks are certainly loaded and no generated terrain is disturbed, and every
-- scene is put back exactly as it was afterwards.
--
--   A  visibility wall     -- what a wall hides, and from whom
--   B  doorway             -- a path, a step, a door, a room
--   C  terrain             -- slope, step, ledge, pit, water, low ceiling
--   D  road semantics      -- a fork, partly hidden
--   E  entity target       -- visible, occluded, out of view, attached

local B = pw_bot_bridge
local support = B.impl.test_support
local canonical = B.impl.canonical

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local MARKER_VISIBLE = "mcl_core:goldblock"
local MARKER_HIDDEN = "mcl_core:diamondblock"
local MARKER_AWAY = "mcl_core:emeraldblock"

local function material(role, fallback)
  local name = perfectworld.compat.get_material(role, {required = false})
  if name and name ~= "air" and minetest.registered_nodes[name] then return name end
  return fallback
end

local function markers_available()
  return minetest.registered_nodes[MARKER_VISIBLE]
    and minetest.registered_nodes[MARKER_HIDDEN]
    and minetest.registered_nodes[MARKER_AWAY]
end

--- Build a scene, run a body against it, and always put the world back.
--
-- `build(origin, helpers)` returns a table the body receives. The player is
-- placed by the harness, never by the bridge: turning a head is a client
-- action, and the test is standing in for the client.
local function run_scene(ctx, build, body)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  if not markers_available() then
    return ctx.skip("marker nodes are not registered in this game")
  end

  local origin = support.scene_origin(player)
  local min, max = support.scene_bounds(origin)
  local loaded, missing = support.area_is_loaded(min, max)
  if not loaded then
    return ctx.skip("scene area is not loaded at " .. minetest.pos_to_string(missing))
  end

  local player_state = support.capture_player(player)
  local snapshot = support.snapshot(min, max)
  local spawned = support.new_spawn_tracker()

  local ok, err = pcall(function()
    -- Clear the volume, then build.
    support.fill(min, max, "air")
    local scene = build(origin, {spawn = spawned.add, min = min, max = max})
    body(scene, player, name, origin)
  end)

  spawned.clear()
  support.restore(snapshot)
  support.restore_player(player, player_state)

  if not ok then error(err) end
end

--- Register the test player as a bot in a given mode for the duration.
local function as_bot(name, mode, fn)
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = mode}, B.SERVER_ACTOR)
    fn()
  end)
end

local function floor_slab(min, max, y, node_name)
  for z = min.z, max.z do
    for x = min.x, max.x do
      minetest.set_node({x = x, y = y, z = z}, {name = node_name})
    end
  end
end

local function wall(origin, z_offset, half_width, height, node_name)
  for x = origin.x - half_width, origin.x + half_width do
    for y = origin.y, origin.y + height - 1 do
      minetest.set_node({x = x, y = y, z = origin.z + z_offset}, {name = node_name})
    end
  end
end

local function ray_hit_names(data)
  local names = {}
  for _, ray in ipairs(data.rays == canonical.EMPTY_ARRAY and {} or data.rays) do
    if ray.hit_type == "node" and type(ray.node) == "table" and ray.node.name then
      names[ray.node.name] = true
    end
  end
  return names
end

-- === Scene A: visibility wall ===

local function build_scene_a(origin, helpers)
  local stone = material("stone", "mcl_core:stone")
  floor_slab(helpers.min, helpers.max, origin.y - 1, stone)
  wall(origin, 8, 4, 5, stone)
  -- The visible marker stands dead ahead at body height, so a ray must find it;
  -- the hidden one stands directly behind the wall, so nothing may.
  minetest.set_node({x = origin.x, y = origin.y + 1, z = origin.z + 5},
    {name = MARKER_VISIBLE})
  minetest.set_node({x = origin.x, y = origin.y + 1, z = origin.z + 10},
    {name = MARKER_HIDDEN})
  local visible_object = helpers.spawn(select(1,
    support.spawn_visible_object({x = origin.x - 2, y = origin.y + 0.5, z = origin.z + 5})))
  local hidden_object = helpers.spawn(select(1,
    support.spawn_visible_object({x = origin.x - 2, y = origin.y + 0.5, z = origin.z + 10})))
  return {
    stone = stone,
    wall_z = origin.z + 8,
    visible_marker = {x = origin.x, y = origin.y + 1, z = origin.z + 5},
    hidden_marker = {x = origin.x, y = origin.y + 1, z = origin.z + 10},
    visible_object = visible_object,
    hidden_object = hidden_object,
  }
end

test("scene_a_player_sees_the_near_block_and_not_the_hidden_one", function(ctx)
  run_scene(ctx, build_scene_a, function(scene, player, name, origin)
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "observe", {profile = "detailed"})
      ctx.assert.is_true(envelope.ok, "the observation succeeded: "
        .. (envelope.ok and "" or envelope.error.code))

      local names = ray_hit_names(envelope.data)
      ctx.assert.is_true(names[MARKER_VISIBLE] == true,
        "the block in front of the player was found by a ray")
      ctx.assert.is_true(names[scene.stone] == true,
        "and so was the wall behind it")

      ctx.assert.is_false(support.mentions(envelope, MARKER_HIDDEN),
        "the block behind the wall is absent from the whole response")

      -- Two more channels that could leak it, checked separately: the feature
      -- sweep casts a much denser fan, and inspect_target uses the engine.
      local swept = support.observe(name, "find_visible_feature", {})
      ctx.assert.is_true(swept.ok, "a feature sweep runs")
      ctx.assert.is_false(support.mentions(swept, MARKER_HIDDEN),
        "the dense feature sweep does not reach behind the wall either")

      local target = support.observe(name, "inspect_target", {})
      ctx.assert.is_true(target.ok, "inspect_target runs")
      ctx.assert.is_false(support.mentions(target, MARKER_HIDDEN),
        "and the crosshair cannot select through the wall")
    end)
  end)
end)

test("scene_a_player_sees_the_near_entity_and_not_the_hidden_one", function(ctx)
  run_scene(ctx, build_scene_a, function(scene, player, name, origin)
    if not scene.visible_object or not scene.hidden_object then
      return ctx.skip("no spawnable object available in this game")
    end
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "find_visible_entity", {})
      ctx.assert.is_true(envelope.ok, "the search succeeded")
      local matches = envelope.data.matches
      matches = (matches == canonical.EMPTY_ARRAY) and {} or matches
      ctx.assert.equal(#matches, 1, "exactly one object is visible")
      if #matches == 1 then
        ctx.assert.is_true(matches[1].position.z < scene.wall_z,
          "the visible object stands in front of the wall")
        ctx.assert.is_true(matches[1].observation_id:find("ent-", 1, true) == 1,
          "objects are named by an opaque id, not a Lua reference")
      end
      ctx.assert.is_true(envelope.data.rejections.occluded ~= nil,
        "the hidden object was rejected as occluded")
    end)
  end)
end)

test("scene_a_oracle_sees_everything_inside_its_scope", function(ctx)
  run_scene(ctx, build_scene_a, function(scene, player, name, origin)
    as_bot(name, "oracle", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "get_area", {
        min = {x = origin.x - 4, y = origin.y, z = origin.z + 1},
        max = {x = origin.x + 4, y = origin.y + 2, z = origin.z + 12},
        include = {"nodes", "semantics"},
      })
      ctx.assert.is_true(envelope.ok, "the oracle answered")
      ctx.assert.is_true(support.mentions(envelope, MARKER_HIDDEN),
        "oracle mode reports the block behind the wall")
      ctx.assert.is_true(support.mentions(envelope, MARKER_VISIBLE),
        "oracle mode reports the block in front of it too")

      if scene.hidden_object then
        local objects = support.observe(name, "get_entities", {
          min = {x = origin.x - 6, y = origin.y - 2, z = origin.z + 1},
          max = {x = origin.x + 6, y = origin.y + 4, z = origin.z + 12},
        })
        ctx.assert.is_true(objects.ok, "the object query answered")
        ctx.assert.is_true(objects.data.entity_count >= 2,
          "oracle mode reports objects on both sides of the wall, got "
          .. tostring(objects.data.entity_count))
      end
    end)
  end)
end)

test("scene_a_turning_the_head_changes_what_is_reported", function(ctx)
  run_scene(ctx, build_scene_a, function(scene, player, name, origin)
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local forward = support.observe(name, "observe", {profile = "navigation"})
      ctx.assert.is_true(forward.ok, "facing the wall")
      local forward_names = ray_hit_names(forward.data)
      ctx.assert.is_true(forward_names[scene.stone] == true, "the wall is in view")

      -- The client turns the player; the bridge only notices.
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, math.pi, 0)
      local backward = support.observe(name, "observe", {profile = "navigation"})
      ctx.assert.is_true(backward.ok, "facing away")
      ctx.assert.is_false(support.mentions(backward, MARKER_VISIBLE),
        "the marker in front is no longer reported once the head turns away")
      ctx.assert.is_true(math.abs(backward.data.self_state.yaw - math.pi) < 0.01,
        "the observation reflects the new yaw")
    end)
  end)
end)

test("scene_a_same_world_and_request_produce_the_same_canonical_answer", function(ctx)
  run_scene(ctx, build_scene_a, function(scene, player, name, origin)
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local function stable_text()
        local envelope = support.observe(name, "observe", {profile = "navigation"})
        -- Volatile by contract: the sequence, the request id and the budget.
        envelope.sequence = 0
        envelope.request_id = "fixed"
        envelope.data.budget = nil
        return B.encode_canonical(envelope)
      end
      local first = stable_text()
      local second = stable_text()
      ctx.assert.equal(#first, #second, "responses have the same length")
      ctx.assert.equal(first, second, "the same world and request give the same bytes")
    end)
  end)
end)

-- === Scene B: doorway ===

local function door_pair()
  local bottoms = {}
  for node_name, def in pairs(minetest.registered_nodes) do
    if def.groups and (def.groups.door_bottom or 0) > 0 then
      bottoms[#bottoms + 1] = node_name
    end
  end
  table.sort(bottoms)
  local bottom = bottoms[1]
  if not bottom then return nil end
  local top = bottom:gsub("_b_(%d)$", "_t_%1")
  if not minetest.registered_nodes[top] then return nil end
  return bottom, top
end

local function build_scene_b(origin, helpers)
  local stone = material("stone", "mcl_core:stone")
  local path = material("road", "mcl_core:coarse_dirt")
  floor_slab(helpers.min, helpers.max, origin.y - 1, stone)

  -- A path leading up one step to a doorway in a wall, with a room behind it.
  for z = origin.z + 1, origin.z + 4 do
    minetest.set_node({x = origin.x, y = origin.y - 1, z = z}, {name = path})
  end
  minetest.set_node({x = origin.x, y = origin.y, z = origin.z + 5}, {name = path})

  wall(origin, 6, 4, 4, stone)
  local bottom, top = door_pair()
  if bottom then
    minetest.set_node({x = origin.x, y = origin.y + 1, z = origin.z + 6}, {name = bottom, param2 = 0})
    minetest.set_node({x = origin.x, y = origin.y + 2, z = origin.z + 6}, {name = top, param2 = 0})
  end
  -- The room, and an obstacle inside it that the closed door hides.
  wall(origin, 10, 4, 4, stone)
  for x = origin.x - 4, origin.x + 4, 8 do
    for z = origin.z + 6, origin.z + 10 do
      for y = origin.y, origin.y + 3 do
        minetest.set_node({x = x, y = y, z = z}, {name = stone})
      end
    end
  end
  minetest.set_node({x = origin.x + 2, y = origin.y + 1, z = origin.z + 8},
    {name = MARKER_HIDDEN})

  return {
    stone = stone,
    path = path,
    door_bottom = bottom,
    door_top = top,
    door_pos = {x = origin.x, y = origin.y + 1, z = origin.z + 6},
    step_pos = {x = origin.x, y = origin.y, z = origin.z + 5},
    hidden_marker = {x = origin.x + 2, y = origin.y + 1, z = origin.z + 8},
  }
end

test("scene_b_player_sees_the_doorway_and_the_step_but_not_the_room", function(ctx)
  run_scene(ctx, build_scene_b, function(scene, player, name, origin)
    if not scene.door_bottom then return ctx.skip("no door nodes registered") end
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z + 2}, 0, 0)

      local envelope = support.observe(name, "find_visible_feature", {feature = "door"})
      ctx.assert.is_true(envelope.ok, "the feature search ran")
      local matches = envelope.data.matches
      matches = (matches == canonical.EMPTY_ARRAY) and {} or matches
      ctx.assert.is_true(#matches > 0, "the door was recognised as a door")
      if #matches > 0 then
        ctx.assert.equal(matches[1].position.z, scene.door_pos.z, "at the doorway")
      end

      local observation = support.observe(name, "observe", {profile = "navigation"})
      ctx.assert.is_true(observation.ok, "the observation succeeded")
      ctx.assert.is_false(support.mentions(observation, MARKER_HIDDEN),
        "what stands inside the closed room is not reported")

      -- The step in front of the body is a tactile fact, not a visual one.
      local tactile = observation.data.tactile
      ctx.assert.not_nil(tactile, "tactile data is present")
      ctx.assert.not_nil(tactile.ground_under_feet, "the ground under the feet is reported")
      ctx.assert.is_true(tactile.head_clearance >= 2,
        "the player has room to stand, clearance=" .. tostring(tactile.head_clearance))
    end)
  end)
end)

test("scene_b_oracle_diagnoses_the_doorway", function(ctx)
  run_scene(ctx, build_scene_b, function(scene, player, name, origin)
    if not scene.door_bottom then return ctx.skip("no door nodes registered") end
    as_bot(name, "oracle", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z + 2}, 0, 0)

      local envelope = support.observe(name, "inspect_position", {position = scene.door_pos})
      ctx.assert.is_true(envelope.ok, "inspect_position answered")
      local node = envelope.data.node
      ctx.assert.equal(node.name, scene.door_bottom, "the door node was identified")

      local has_door, has_state = false, false
      for _, tag in ipairs(node.semantics) do
        if tag == "door" then has_door = true end
        if tag == "door_closed" or tag == "door_open" then has_state = true end
      end
      ctx.assert.is_true(has_door, "the door is tagged as a door")
      ctx.assert.is_true(has_state, "the door reports a state read from the game convention")

      ctx.assert.not_nil(envelope.data.access, "the threshold's standability is reported")
      ctx.assert.not_nil(envelope.data.access.reasons, "and the reasons if it is not standable")

      local room = support.observe(name, "get_area", {
        min = {x = origin.x - 3, y = origin.y, z = origin.z + 7},
        max = {x = origin.x + 3, y = origin.y + 2, z = origin.z + 9},
        include = {"nodes", "semantics"},
      })
      ctx.assert.is_true(room.ok, "the oracle read the closed room")
      ctx.assert.is_true(support.mentions(room, MARKER_HIDDEN),
        "oracle mode reports what is inside the room")
    end)
  end)
end)

-- === Scene C: terrain ===

local function build_scene_c(origin, helpers)
  local stone = material("stone", "mcl_core:stone")
  local water = material("water", "mcl_core:water_source")
  local bedrock_y = origin.y - 5
  floor_slab(helpers.min, helpers.max, bedrock_y, stone)

  local function column(z_offset, top_y, node_name)
    for x = origin.x - 2, origin.x + 2 do
      for y = bedrock_y, top_y do
        minetest.set_node({x = x, y = y, z = origin.z + z_offset},
          {name = y == top_y and node_name or stone})
      end
    end
  end

  -- Descending and level features come first: an ascending one would occlude
  -- everything behind it, and then the test would be measuring the wall.
  column(0, origin.y - 1, stone)
  column(1, origin.y - 1, stone)          -- flat
  column(2, origin.y - 1, stone)          -- flat
  -- z+3 is a pit: nothing above the bedrock floor
  column(4, origin.y - 1, stone)          -- flat again
  column(5, origin.y - 1, water)          -- water surface
  column(6, origin.y - 1, stone)
  column(7, origin.y, stone)              -- a kerb the walker can climb
  column(8, origin.y + 2, stone)          -- a ledge it cannot

  -- A low ceiling directly over the player's own head. It belongs to the body's
  -- own space, so it is the tactile channel that must notice it, not the strip
  -- of ground ahead: a roof and a ledge of the same height are the same shape,
  -- and only where the body stands tells them apart.
  for x = origin.x - 2, origin.x + 2 do
    minetest.set_node({x = x, y = origin.y + 3, z = origin.z}, {name = stone})
  end

  return {
    stone = stone,
    water = water,
    base_y = origin.y - 1,
    pit_y = bedrock_y,
    ceiling_y = origin.y + 3,
  }
end

test("scene_c_surface_profile_reports_slope_gap_water_and_clearance", function(ctx)
  run_scene(ctx, build_scene_c, function(scene, player, name, origin)
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "observe", {profile = "navigation"})
      ctx.assert.is_true(envelope.ok, "the observation succeeded")

      local profile = envelope.data.surface_profile
      ctx.assert.not_nil(profile, "a surface profile is present")
      local by_step = {}
      for _, sample in ipairs(profile.samples == canonical.EMPTY_ARRAY and {} or profile.samples) do
        by_step[sample.step] = sample
      end

      ctx.assert.not_nil(by_step[1], "the first step is reported")
      if by_step[1] and by_step[1].ground_y then
        ctx.assert.equal(by_step[1].ground_y, scene.base_y, "flat ground at the first step")
        ctx.assert.equal(by_step[1].slope, 0, "no slope on flat ground")
      end

      local pit = by_step[3]
      ctx.assert.not_nil(pit, "the pit is reported")
      if pit and pit.ground_y then
        ctx.assert.equal(pit.ground_y, scene.pit_y, "the pit floor is three blocks down")
        ctx.assert.is_true(pit.gap, "the pit is flagged as a gap")
      end

      local wet = by_step[5]
      if wet and wet.ground_y then
        ctx.assert.is_true(wet.water, "the water surface is flagged")
      end

      local flat = by_step[4]
      if flat and flat.head_clearance then
        ctx.assert.is_true(flat.head_clearance >= 2,
          "open ground has room to stand, clearance=" .. tostring(flat.head_clearance))
        ctx.assert.is_true(flat.walkable, "and is reported walkable")
      end

      local kerb = by_step[7]
      if kerb and kerb.obstacle_height then
        ctx.assert.equal(kerb.obstacle_height, 1, "the kerb is one block high")
      end
      local ledge = by_step[8]
      if ledge and ledge.obstacle_height then
        ctx.assert.equal(ledge.obstacle_height, 3, "the ledge is three blocks high")
      end
    end)
  end)
end)

test("scene_c_tactile_reports_the_body_space_whatever_the_head_does", function(ctx)
  run_scene(ctx, build_scene_c, function(scene, player, name, origin)
    as_bot(name, "player", function()
      -- Facing straight up: nothing ahead is in the field of view, yet the
      -- ground under the feet is still a fact the body knows.
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, math.pi / 2 - 0.1)
      local envelope = support.observe(name, "observe", {profile = "minimal"})
      ctx.assert.is_true(envelope.ok, "the observation succeeded")
      local tactile = envelope.data.tactile
      ctx.assert.equal(tactile.ground_under_feet.name, scene.stone,
        "the ground under the feet is reported while looking at the sky")
      ctx.assert.is_true(tactile.ground_under_feet.walkable, "and it is walkable")
      ctx.assert.equal(envelope.data.self_state.node_under.name, scene.stone,
        "self state agrees about the node under the player")
      ctx.assert.is_true(envelope.data.self_state.on_ground, "the player is on the ground")

      -- The ceiling three nodes up is exactly the kind of fact a body knows by
      -- occupying space, and the tactile channel reports it while the eyes are
      -- pointed elsewhere.
      ctx.assert.equal(tactile.head_clearance, scene.ceiling_y - scene.base_y - 1,
        "the low ceiling above the player is measured")
      ctx.assert.is_true(tactile.head_clearance < 4, "and it is genuinely low")
    end)
  end)
end)

-- === Scene D: road semantics ===

local function build_scene_d(origin, helpers)
  local stone = material("stone", "mcl_core:stone")
  local road = material("road", "mcl_core:coarse_dirt")
  floor_slab(helpers.min, helpers.max, origin.y - 1, stone)

  -- A straight road with a fork, and a wall that hides the far half.
  for z = origin.z + 1, origin.z + 10 do
    minetest.set_node({x = origin.x, y = origin.y - 1, z = z}, {name = road})
  end
  for x = origin.x + 1, origin.x + 4 do
    minetest.set_node({x = x, y = origin.y - 1, z = origin.z + 4}, {name = road})
  end
  wall(origin, 6, 5, 4, stone)

  return {
    stone = stone,
    road = road,
    wall_z = origin.z + 6,
  }
end

test("scene_d_player_recognises_only_the_visible_stretch_of_road", function(ctx)
  run_scene(ctx, build_scene_d, function(scene, player, name, origin)
    if scene.road == scene.stone then return ctx.skip("road material is not distinct") end
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, -0.3)
      local envelope = support.observe(name, "find_visible_feature", {feature = "road_surface"})
      ctx.assert.is_true(envelope.ok, "the feature search ran")
      local matches = envelope.data.matches
      matches = (matches == canonical.EMPTY_ARRAY) and {} or matches
      ctx.assert.is_true(#matches > 0, "the near road was recognised")
      for _, match in ipairs(matches) do
        ctx.assert.equal(match.feature, "road_surface", "only road cells came back")
        ctx.assert.is_true(match.position.z < scene.wall_z,
          "no road cell from behind the wall was reported, saw z=" .. match.position.z)
      end
    end)
  end)
end)

test("scene_d_oracle_reads_the_whole_road_in_scope", function(ctx)
  run_scene(ctx, build_scene_d, function(scene, player, name, origin)
    if scene.road == scene.stone then return ctx.skip("road material is not distinct") end
    as_bot(name, "oracle", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "get_area", {
        min = {x = origin.x - 1, y = origin.y - 1, z = origin.z + 7},
        max = {x = origin.x + 1, y = origin.y - 1, z = origin.z + 10},
        include = {"nodes", "semantics"},
      })
      ctx.assert.is_true(envelope.ok, "the oracle answered")
      local road_cells = 0
      for _, node in ipairs(envelope.data.nodes == canonical.EMPTY_ARRAY and {} or envelope.data.nodes) do
        if node.name == scene.road then
          road_cells = road_cells + 1
          local tagged = false
          for _, tag in ipairs(node.semantics or {}) do
            if tag == "road_surface" then tagged = true end
          end
          ctx.assert.is_true(tagged, "the road node carries PerfectWorld semantics")
        end
      end
      ctx.assert.is_true(road_cells >= 4,
        "the road behind the wall is fully readable, cells=" .. road_cells)
    end)
  end)
end)

-- === Scene E: entity interaction target ===

local function build_scene_e(origin, helpers)
  local stone = material("stone", "mcl_core:stone")
  floor_slab(helpers.min, helpers.max, origin.y - 1, stone)
  wall(origin, 7, 4, 4, stone)

  local front = helpers.spawn(select(1,
    support.spawn_visible_object({x = origin.x, y = origin.y + 0.5, z = origin.z + 4})))
  local occluded = helpers.spawn(select(1,
    support.spawn_visible_object({x = origin.x, y = origin.y + 0.5, z = origin.z + 9})))
  local behind = helpers.spawn(select(1,
    support.spawn_visible_object({x = origin.x, y = origin.y + 0.5, z = origin.z - 6})))

  return {stone = stone, front = front, occluded = occluded, behind = behind}
end

test("scene_e_only_the_visible_object_is_an_interaction_target", function(ctx)
  run_scene(ctx, build_scene_e, function(scene, player, name, origin)
    if not scene.front or not scene.occluded or not scene.behind then
      return ctx.skip("no spawnable object available in this game")
    end
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "find_visible_entity", {})
      ctx.assert.is_true(envelope.ok, "the search ran")
      local matches = envelope.data.matches
      matches = (matches == canonical.EMPTY_ARRAY) and {} or matches
      ctx.assert.equal(#matches, 1, "one object of three is visible")
      if #matches == 1 then
        local match = matches[1]
        ctx.assert.is_true(match.position.z > origin.z, "it is the one in front")
        ctx.assert.is_true(match.position.z < origin.z + 7, "and in front of the wall")
        ctx.assert.is_true(match.distance > 0, "a distance is reported")
        ctx.assert.not_nil(match.semantic_tags, "semantic tags are reported")
        ctx.assert.equal(match.attached_to_player, false, "it is not attached to the player")
      end
      local rejections = envelope.data.rejections
      ctx.assert.is_true(next(rejections) ~= nil, "the other two were rejected with reasons")
    end)
  end)
end)

test("scene_e_inspect_target_names_what_the_crosshair_points_at", function(ctx)
  run_scene(ctx, build_scene_e, function(scene, player, name, origin)
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local envelope = support.observe(name, "inspect_target", {})
      ctx.assert.is_true(envelope.ok, "inspect_target ran")
      ctx.assert.equal(envelope.data.method, "engine_raycast_pointability",
        "the answer says pointability, not opacity, decided it")
      local target = envelope.data.target
      ctx.assert.not_nil(target, "something is under the crosshair")
      if type(target) == "table" and target.hit_type then
        ctx.assert.is_true(target.hit_type == "node" or target.hit_type == "object",
          "the target is a node or an object")
        ctx.assert.not_nil(target.within_reach, "reach is reported separately from distance")
      end
    end)
  end)
end)

test("scene_e_attachment_is_observed_not_caused", function(ctx)
  run_scene(ctx, build_scene_e, function(scene, player, name, origin)
    if not scene.front then return ctx.skip("no spawnable object available in this game") end
    as_bot(name, "player", function()
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)

      local before = support.observe(name, "get_self_state", {})
      ctx.assert.is_true(before.ok, "self state before")
      ctx.assert.is_false(before.data.self_state.attached, "the player starts unattached")
      ctx.assert.equal(before.data.self_state.attached_entity, canonical.NULL,
        "and reports no attachment entity")

      -- The harness stands in for the client here. The bridge itself never
      -- attaches a player to anything.
      local attached = pcall(function()
        player:set_attach(scene.front, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
      end)
      if not attached then return ctx.skip("this object cannot carry a player") end

      local during = support.observe(name, "get_self_state", {})
      ctx.assert.is_true(during.ok, "self state during")
      ctx.assert.is_true(during.data.self_state.attached, "the attachment is observed")
      ctx.assert.is_true(tostring(during.data.self_state.attached_entity):find("ent-", 1, true) == 1,
        "the carrier is named by an opaque id")

      pcall(function() player:set_detach() end)
      support.place_player(player, {x = origin.x, y = origin.y, z = origin.z}, 0, 0)
      local after = support.observe(name, "get_self_state", {})
      ctx.assert.is_false(after.data.self_state.attached, "detaching is observed too")
    end)
  end)
end)
