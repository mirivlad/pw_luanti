-- pw_debug/bot_course.lua
--
-- A controlled obstacle course for PW Bot, built to order and taken away again.
--
-- Testing a walking bot only against generated villages is testing two things at
-- once: whether the bot can walk, and whether the generator built somewhere
-- walkable. When it fails you learn neither. This course is the other half —
-- every obstacle is deliberate, at a known offset, and the same every time, so
-- "the bot cannot climb a one-node step" is a statement the run can actually
-- make.
--
-- What it contains, in the order the bot meets it walking along +Z:
--
--   z+0   flat ground to start on
--   z+4   a straight run
--   z+8   a corner: the way ahead is walled, the way on is to the left
--   z+12  one step up
--   z+14  three steps up, one node each
--   z+18  a door in a wall
--   z+20  a room behind the door
--   z+22  the way out of the room
--   z+26  a threshold too high to climb: this one is *meant* to stop the bot
--   z+30  a beam at head height with walkable floor under it
--   z+34  a pit
--   z+38  water
--   z+42  a dead end
--
-- The last five exist to be failed. A bot that reports `reached` for any of
-- them is a bot whose reports mean nothing, which is far worse than a bot that
-- gets stuck.
--
-- Everything is written through a VoxelManip and the previous contents are kept
-- in mod storage, so `remove` puts the world back exactly as it was. Thousands
-- of set_node calls would be slow and would flood Mineclonia's redstone queue,
-- which would make the project's log scan meaningless.

local storage = minetest.get_mod_storage()
local STORAGE_KEY = "pw_bot_course_v1"

local course = {}
perfectworld.debug = perfectworld.debug or {}
perfectworld.debug.bot_course = course

course.WIDTH = 7          -- x extent, centred on the origin
course.LENGTH = 46        -- z extent
course.HEIGHT = 8         -- how far up the course is cleared
course.FLOOR_OFFSET = -1  -- floor sits one below the walking surface

local function material(name, fallback)
  if perfectworld.compat and perfectworld.compat.get_material then
    local resolved = perfectworld.compat.get_material(name)
    if resolved and minetest.registered_nodes[resolved] then return resolved end
  end
  return fallback
end

--- Find a door registered by whatever game is loaded.
--
-- Hard-coding a door name is how the first version of this got a course with no
-- door in it: Mineclonia calls its oak door `mcl_doors:door_oak_b_1`, not the
-- `wooden_door_b_1` an older guess assumed, and a name that does not resolve
-- silently becomes air. Asking the registry which nodes are door bottoms is
-- both shorter and correct across versions.
local function find_door()
  -- Wooden doors only. Metal ones are a different thing wearing the same
  -- shape: Mineclonia's iron doors set `only_redstone_can_open`, and its copper
  -- doors carry the `door_iron` group, so a hand that clicks them does nothing.
  -- The course wants the door a village has and a person opens, and picking the
  -- alphabetically first door in the registry got a copper one instead.
  local wooden, metal = {}, {}
  for name, def in pairs(minetest.registered_nodes) do
    local groups = def.groups or {}
    if (groups.door_bottom or 0) > 0 then
      if (groups.door_iron or 0) > 0 or def.only_redstone_can_open then
        metal[#metal + 1] = name
      else
        wooden[#wooden + 1] = name
      end
    end
  end
  table.sort(wooden)
  table.sort(metal)

  for _, list in ipairs({wooden, metal}) do
    for _, bottom in ipairs(list) do
      local suffix = bottom:sub(-4)
      if suffix == "_b_1" or suffix == "_b_2" then
        local top = bottom:sub(1, -5) .. "_t_" .. suffix:sub(-1)
        if minetest.registered_nodes[top] then
          return bottom, top
        end
      end
    end
  end
  return nil, nil
end

course.find_door = find_door

--- Node names, resolved once against whatever game is loaded.
local function palette()
  local function first(...)
    for _, name in ipairs({...}) do
      if minetest.registered_nodes[name] then return name end
    end
    return "air"
  end
  local door_bottom, door_top = find_door()
  return {
    floor = first(material("floor", "mcl_core:stone"), "mcl_core:stone", "default:stone"),
    wall = first(material("wall", "mcl_core:brick_block"), "mcl_core:brick_block",
                 "mcl_core:stonebrick", "default:brick"),
    step = first("mcl_core:sandstone", "mcl_core:stone", "default:sandstone"),
    water = first("mcl_core:water_source", "default:water_source"),
    door_bottom = door_bottom or first("doors:door_wood_a"),
    door_top = door_top or first("doors:door_wood_b"),
    air = "air",
  }
end

course.palette = palette

--- Where the course is built: beside the test player, on a fixed grid, so two
--- runs land in the same place and a human can find it.
function course.origin(player_name)
  local player = minetest.get_player_by_name(player_name)
  if not player then return nil end
  local position = player:get_pos()
  return {
    x = math.floor(position.x / 16 + 0.5) * 16,
    -- Well above the surface: the course must not disturb a generated village,
    -- and building it in the air means no terrain has to be flattened.
    y = math.floor(position.y + 0.5) + 24,
    z = math.floor(position.z / 16 + 0.5) * 16,
  }
end

local function bounds(origin)
  local half = math.floor(course.WIDTH / 2)
  return
    {x = origin.x - half - 1, y = origin.y - 2, z = origin.z - 2},
    {x = origin.x + half + 1, y = origin.y + course.HEIGHT, z = origin.z + course.LENGTH}
end

course.bounds = bounds

-- === Building ===============================================================

--- The course as a list of (dx, dy, dz) -> node name. Pure: it computes what
--- the course *is*, and the caller decides how to write it.
function course.plan()
  local p = palette()
  local half = math.floor(course.WIDTH / 2)
  local nodes = {}

  local function put(dx, dy, dz, name)
    nodes[#nodes + 1] = {dx = dx, dy = dy, dz = dz, name = name}
  end

  -- Walking surface for the whole length, with clear air above it.
  for dz = 0, course.LENGTH do
    for dx = -half, half do
      put(dx, course.FLOOR_OFFSET, dz, p.floor)
      for dy = 0, 3 do put(dx, dy, dz, p.air) end
    end
  end

  -- z+8: a corner. Wall straight ahead; the opening is to the left (-x).
  for dx = -half + 2, half do
    for dy = 0, 2 do put(dx, dy, 8, p.wall) end
  end

  -- z+12..13: one step up, exactly the height a body can climb.
  for dx = -half, half do
    put(dx, 0, 12, p.step)
    put(dx, 0, 13, p.step)
  end

  -- z+14..16: a staircase continuing from that step, one node per tread. The
  -- treads must be contiguous — a staircase with a gap in it is a two-node
  -- climb wearing a disguise, and it is the bot that gets blamed.
  --
  --   z+13 surface dy 1  (the single step)
  --   z+14 surface dy 2
  --   z+15 surface dy 3
  --   z+16 surface dy 4
  for index = 1, 3 do
    local dz = 13 + index
    for dx = -half, half do
      for dy = 0, index do put(dx, dy, dz, p.step) end
    end
  end

  -- z+17 onwards: the upper level, at walking surface dy 4. It runs to the end
  -- of the course, so everything past the stairs is on one plane and a failure
  -- is the obstacle rather than a surprise drop.
  for dz = 17, course.LENGTH do
    for dx = -half, half do
      for dy = 0, 3 do put(dx, dy, dz, p.step) end
      for dy = 4, 7 do put(dx, dy, dz, p.air) end
    end
  end

  -- z+18: a wall with a door in it, standing on the landing (floor at dy 4).
  for dx = -half, half do
    for dy = 4, 6 do
      if dx ~= 0 then put(dx, dy, 18, p.wall) end
    end
  end
  put(0, 4, 18, p.door_bottom)
  put(0, 5, 18, p.door_top)
  put(0, 6, 18, p.wall)

  -- z+19..21: the room behind the door, walled on both sides.
  for dz = 19, 21 do
    put(-half, 4, dz, p.wall); put(-half, 5, dz, p.wall)
    put(half, 4, dz, p.wall); put(half, 5, dz, p.wall)
    for dx = -half + 1, half - 1 do
      for dy = 4, 5 do put(dx, dy, dz, p.air) end
      put(dx, 6, dz, p.wall)  -- a ceiling, so it is a room and not a corridor
    end
  end

  -- z+22: the way out.
  for dx = -half, half do
    for dy = 4, 6 do
      if dx ~= 0 then put(dx, dy, 22, p.wall) end
    end
  end
  put(0, 4, 22, p.air)
  put(0, 5, 22, p.air)

  -- --- Everything below is meant to stop the bot. ---
  --
  -- These are not the course failing. A bot that reports `reached` for any of
  -- them is a bot whose successes mean nothing, which is far worse than one
  -- that honestly gets stuck. Each is on the upper level, walking surface dy 4.

  -- z+26: a threshold two nodes high, above what a body can climb.
  for dx = -half, half do
    for dy = 4, 5 do put(dx, dy, 26, p.wall) end
  end

  -- z+30: a beam at head height. The feet fit, the head does not.
  for dx = -half, half do
    put(dx, 5, 30, p.wall)
  end

  -- z+34..36: a pit, by taking the upper level away.
  for dz = 34, 36 do
    for dx = -half, half do
      for dy = 0, 3 do put(dx, dy, dz, p.air) end
    end
  end

  -- z+38..39: water on the walking surface.
  for dz = 38, 39 do
    for dx = -half, half do
      put(dx, 4, dz, p.water)
    end
  end

  -- z+42: a dead end, sealed to the ceiling.
  for dx = -half, half do
    for dy = 4, 6 do put(dx, dy, 42, p.wall) end
  end

  return nodes
end

--- Landmarks a test can aim at, as absolute positions.
function course.landmarks(origin)
  return {
    start = {x = origin.x, y = origin.y + 1, z = origin.z + 1},
    straight = {x = origin.x, y = origin.y + 1, z = origin.z + 6},
    -- The corner takes two legs: the way ahead is walled, so a body has to move
    -- aside before it can move on. A single straight line into it is a body
    -- walking into a wall, which is what the runtime would honestly report.
    corner_approach = {x = origin.x - 2, y = origin.y, z = origin.z + 6},
    corner = {x = origin.x - 2, y = origin.y, z = origin.z + 9},
    -- Walking surfaces, so a `walk_to` aimed at one of these is aimed at
    -- somewhere a body can actually stand.
    step_up = {x = origin.x, y = origin.y + 1, z = origin.z + 13},
    stairs_top = {x = origin.x, y = origin.y + 4, z = origin.z + 17},
    -- The door node itself: something to look at and click, not to stand in.
    door = {x = origin.x, y = origin.y + 4, z = origin.z + 18},
    door_approach = {x = origin.x, y = origin.y + 4, z = origin.z + 17},
    room_centre = {x = origin.x, y = origin.y + 4, z = origin.z + 20},
    room_exit = {x = origin.x, y = origin.y + 4, z = origin.z + 23},
    too_high = {x = origin.x, y = origin.y + 4, z = origin.z + 27},
    low_beam = {x = origin.x, y = origin.y + 4, z = origin.z + 31},
    pit = {x = origin.x, y = origin.y + 4, z = origin.z + 35},
    water = {x = origin.x, y = origin.y + 4, z = origin.z + 39},
    dead_end = {x = origin.x, y = origin.y + 4, z = origin.z + 43},
  }
end

local function write_nodes(origin, nodes, save_previous)
  local minimum, maximum = bounds(origin)
  local manip = minetest.get_voxel_manip()
  local emerged_min, emerged_max = manip:read_from_map(minimum, maximum)
  local area = VoxelArea:new({MinEdge = emerged_min, MaxEdge = emerged_max})
  local data = manip:get_data()
  local param2 = manip:get_param2_data()

  local previous = nil
  if save_previous then
    previous = {}
    for index, value in ipairs(data) do
      previous[index] = value
    end
  end

  local content = {}
  local function id(name)
    if content[name] == nil then content[name] = minetest.get_content_id(name) end
    return content[name]
  end

  for _, entry in ipairs(nodes) do
    local index = area:index(origin.x + entry.dx, origin.y + entry.dy, origin.z + entry.dz)
    if index then
      data[index] = id(entry.name)
      param2[index] = 0
    end
  end

  manip:set_data(data)
  manip:set_param2_data(param2)
  manip:write_to_map(true)
  manip:update_liquids()
  return previous, emerged_min, emerged_max
end

function course.build(player_name)
  local origin = course.origin(player_name)
  if not origin then return nil, "player_not_connected" end

  -- Keep enough to put the world back: the region and its contents before we
  -- touched it.
  local minimum, maximum = bounds(origin)
  local manip = minetest.get_voxel_manip()
  local emerged_min, emerged_max = manip:read_from_map(minimum, maximum)
  local before = manip:get_data()
  local saved = {}
  for index, value in ipairs(before) do saved[index] = value end

  write_nodes(origin, course.plan(), false)

  -- A door is more than two nodes. Mineclonia keeps its open flag in node
  -- metadata on both halves, and a leaf written straight into the voxel data
  -- has none — so it looks like a door, reports as a door, and does not
  -- respond to being clicked. Setting the metadata afterwards is what makes it
  -- a door the game will actually open.
  local door_bottom, door_top = find_door()
  if door_bottom then
    local bottom = {x = origin.x, y = origin.y + 4, z = origin.z + 18}
    local top = {x = bottom.x, y = bottom.y + 1, z = bottom.z}
    minetest.set_node(bottom, {name = door_bottom, param2 = 0})
    minetest.set_node(top, {name = door_top, param2 = 0})
    for _, spot in ipairs({bottom, top}) do
      local meta = minetest.get_meta(spot)
      meta:set_int("is_open", 0)
      meta:set_int("is_mirrored", 0)
    end
    minetest.log("action", "[pw_debug] course door placed: " .. door_bottom)
  else
    minetest.log("warning", "[pw_debug] no door node is registered; the course has a hole")
  end

  storage:set_string(STORAGE_KEY, minetest.write_json({
    origin = origin,
    emerged_min = emerged_min,
    emerged_max = emerged_max,
    saved = saved,
    built_at = os.time(),
  }))

  return {origin = origin, landmarks = course.landmarks(origin),
          minimum = minimum, maximum = maximum}
end

function course.remove()
  local raw = storage:get_string(STORAGE_KEY)
  if raw == "" then return false, "no_course_recorded" end
  local record = minetest.parse_json(raw)
  if not record or not record.saved then return false, "record_unreadable" end

  local manip = minetest.get_voxel_manip()
  manip:read_from_map(record.emerged_min, record.emerged_max)
  local data = manip:get_data()
  for index = 1, #data do
    if record.saved[index] then data[index] = record.saved[index] end
  end
  manip:set_data(data)
  manip:write_to_map(true)
  manip:update_liquids()

  storage:set_string(STORAGE_KEY, "")
  return true, record.origin
end

function course.info()
  local raw = storage:get_string(STORAGE_KEY)
  if raw == "" then return nil end
  local record = minetest.parse_json(raw)
  if not record then return nil end
  return {origin = record.origin, built_at = record.built_at,
          landmarks = course.landmarks(record.origin)}
end

-- === Command =================================================================

minetest.register_chatcommand("pw_bot_course", {
  params = "<build|remove|info|start> [player]",
  description = "Build, remove or inspect the PW Bot obstacle course",
  privs = {server = true},
  func = function(name, param)
    local action, who = param:match("^(%S+)%s+(%S+)$")
    if not action then action = param:match("^(%S*)$") end
    if action == "" then action = "info" end
    who = who or minetest.settings:get("perfectworld.test_player") or "pwbot"

    if action == "build" then
      local built, reason = course.build(who)
      if not built then return false, "could not build: " .. tostring(reason) end
      local file = minetest.get_worldpath() .. "/pw_bot_course.json"
      minetest.safe_file_write(file, minetest.write_json({
        origin = built.origin,
        landmarks = built.landmarks,
        minimum = built.minimum,
        maximum = built.maximum,
      }))
      return true, string.format(
        "course built at (%d, %d, %d); start (%d, %d, %d), door (%d, %d, %d); "
        .. "landmarks written to pw_bot_course.json",
        built.origin.x, built.origin.y, built.origin.z,
        built.landmarks.start.x, built.landmarks.start.y, built.landmarks.start.z,
        built.landmarks.door.x, built.landmarks.door.y, built.landmarks.door.z)
    end

    if action == "remove" then
      local ok, detail = course.remove()
      if not ok then return false, "could not remove: " .. tostring(detail) end
      return true, "course removed and the world put back"
    end

    if action == "start" then
      -- Setup only. Placing the bot at the start line is not the bot moving;
      -- from here on it walks, and nothing teleports it again.
      local record = course.info()
      if not record then return false, "no course is built" end
      local player = minetest.get_player_by_name(who)
      if not player then return false, who .. " is not connected" end
      player:set_pos(record.landmarks.start)
      return true, string.format("%s placed at the start line (%d, %d, %d)", who,
        record.landmarks.start.x, record.landmarks.start.y, record.landmarks.start.z)
    end

    local record = course.info()
    if not record then return true, "no course is built" end
    local rows = {string.format("course at (%d, %d, %d), built %s",
      record.origin.x, record.origin.y, record.origin.z,
      os.date("!%Y-%m-%d %H:%M:%S", record.built_at))}
    for _, key in ipairs({"start", "corner", "step_up", "stairs_top", "door",
                          "room_centre", "room_exit", "too_high", "low_beam",
                          "pit", "water", "dead_end"}) do
      local spot = record.landmarks[key]
      rows[#rows + 1] = string.format("  %-12s (%d, %d, %d)", key, spot.x, spot.y, spot.z)
    end
    return true, table.concat(rows, "\n")
  end,
})

minetest.log("action", "[pw_debug] bot course loaded")

return course
