-- pw_bot_bridge/entities.lua
--
-- Objects, described without handing out a single Lua reference.
--
-- A bot must be able to say "the boat I saw a moment ago" without ever holding
-- an ObjectRef, so every object gets an opaque id that is stable for as long as
-- the observing session lives and meaningless afterwards. The id space is
-- per-session: after a restart, or after re-registration, yesterday's ids
-- address nothing.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local semantics = B.impl.semantics
local perception = B.impl.perception
local registry = B.impl.registry
local entities = {}
B.impl.entities = entities

--- Opaque, session-scoped id for an object.
-- The weak-keyed table lets the garbage collector forget objects that left the
-- world; the counter guarantees ids are never recycled inside a session.
function entities.id_for(session, object)
  if not session or not object then return "unknown" end
  local existing = session.entity_ids[object]
  if existing then return existing end
  session.entity_counter = session.entity_counter + 1
  local id = string.format("ent-%s-%d", session.session_id, session.entity_counter)
  session.entity_ids[object] = id
  return id
end

local function object_kind(object, luaentity, is_player)
  if is_player then return "player" end
  if not luaentity then return "unknown" end
  local name = luaentity.name or ""
  if name == "__builtin:item" then return "item" end
  if name:find("boat", 1, true) then return "boat" end
  if luaentity.type then return tostring(luaentity.type) end
  return "entity"
end

--- Height at which an object is most likely to be visible: not its feet, which
--- terrain hides, and not its top, which a low ceiling hides.
local function sight_points(pos, properties)
  local height = 1.0
  if properties and type(properties.collisionbox) == "table" and properties.collisionbox[5] then
    height = math.max(0.2, properties.collisionbox[5])
  end
  return {
    {x = pos.x, y = pos.y + height * 0.5, z = pos.z},
    {x = pos.x, y = pos.y + height, z = pos.z},
    {x = pos.x, y = pos.y + 0.1, z = pos.z},
  }
end

--- Describe an object for a response.
-- `observer` is the player whose perspective this is; relative coordinates and
-- distance are measured from their eye.
function entities.describe(session, object, eye, options)
  options = options or {}
  local pos = object:get_pos()
  if not pos then return nil end
  local is_player = object.is_player and object:is_player() or false
  local luaentity = (not is_player) and object.get_luaentity and object:get_luaentity() or nil
  local properties = object.get_properties and object:get_properties() or nil
  local name
  if is_player then
    name = "player:" .. object:get_player_name()
  else
    name = (luaentity and luaentity.name) or "unknown"
  end

  local to = {x = pos.x - eye.x, y = pos.y - eye.y, z = pos.z - eye.z}
  local distance = math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
  local direction = select(1, perception.normalize(to))

  local attached_parent = nil
  if object.get_attach then
    local ok, parent = pcall(function() return object:get_attach() end)
    if ok and parent then
      attached_parent = entities.id_for(session, parent)
    end
  end

  local descriptor = {
    observation_id = entities.id_for(session, object),
    kind = object_kind(object, luaentity, is_player),
    name = name,
    position = canonical.vector(pos),
    relative_position = canonical.vector(to),
    distance = canonical.round(distance),
    direction = canonical.vector(direction),
    interactable = properties and properties.pointable ~= false or false,
    physical = properties and properties.physical == true or false,
    attached_to = attached_parent or canonical.NULL,
    attached_to_player = attached_parent ~= nil
      and options.observer_id ~= nil
      and attached_parent == options.observer_id,
    semantic_tags = semantics.tags_for_entity(name, is_player, properties),
  }
  if options.include_hp and object.get_hp then
    local ok, hp = pcall(function() return object:get_hp() end)
    if ok then descriptor.hp = math.floor(hp or 0) end
  end
  return descriptor
end

--- Stable ordering for a list of descriptors.
-- Distance first so the nearest thing is always element one; the id breaks
-- ties, which keeps the order canonical when two objects are equidistant.
function entities.sort(list)
  table.sort(list, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.observation_id < b.observation_id
  end)
  return list
end

--- Objects the observing player can actually see.
--
-- Four filters, in the order that costs least first: range, then the view
-- sector, then the policy filter, then line of sight — which is the only one
-- that touches the map.
function entities.visible_for(player, session, limits, sector, budget, options)
  options = options or {}
  local eye = perception.eye_position(player)
  local _, _, dir = perception.look(player)
  local observer_id = entities.id_for(session, player)
  local found, rejected = {}, {}

  local nearby = minetest.get_objects_inside_radius(eye, limits.view_distance)
  -- get_objects_inside_radius has no defined order, so sort by a stable key
  -- before doing anything that could truncate the list.
  local candidates = {}
  for _, object in ipairs(nearby) do
    if object ~= player then
      local pos = object:get_pos()
      if pos then
        candidates[#candidates + 1] = {
          object = object,
          key = string.format("%.3f:%.3f:%.3f", pos.x, pos.y, pos.z),
        }
      end
    end
  end
  table.sort(candidates, function(a, b) return a.key < b.key end)

  for _, candidate in ipairs(candidates) do
    if #found >= limits.max_entities then
      rejected.limit = (rejected.limit or 0) + 1
    else
      local object = candidate.object
      local pos = object:get_pos()
      local properties = object.get_properties and object:get_properties() or nil
      local visible, reason = false, nil
      for _, point in ipairs(sight_points(pos, properties)) do
        local in_sector, sector_reason = perception.in_view_sector(eye, dir, point, limits, sector)
        if in_sector then
          local clear = perception.line_of_sight(eye, point, budget)
          if clear then
            visible = true
            break
          end
          reason = "occluded"
        else
          reason = reason or sector_reason
        end
      end
      if visible then
        local descriptor = entities.describe(session, object, eye,
          {observer_id = observer_id, include_hp = options.include_hp})
        if descriptor then found[#found + 1] = descriptor end
      elseif reason then
        rejected[reason] = (rejected[reason] or 0) + 1
      end
    end
  end

  entities.sort(found)
  if #found == 0 then found = canonical.EMPTY_ARRAY end
  return found, rejected
end

--- Objects in an area, with no visibility filtering at all. Oracle only.
function entities.in_area(session, min, max, eye, budget, options)
  options = options or {}
  local center = {
    x = (min.x + max.x) / 2,
    y = (min.y + max.y) / 2,
    z = (min.z + max.z) / 2,
  }
  local radius = perception.distance(center, max) + 1
  local out = {}
  for _, object in ipairs(minetest.get_objects_inside_radius(center, radius)) do
    local pos = object:get_pos()
    if pos
      and pos.x >= min.x and pos.x <= max.x
      and pos.y >= min.y and pos.y <= max.y
      and pos.z >= min.z and pos.z <= max.z
    then
      local descriptor = entities.describe(session, object, eye or center,
        {include_hp = options.include_hp})
      if descriptor then out[#out + 1] = descriptor end
    end
  end
  entities.sort(out)
  if #out == 0 then return canonical.EMPTY_ARRAY end
  return out
end

--- Set of observation ids currently visible, used by the event sampler to tell
--- "appeared" from "still there".
function entities.visible_id_set(list)
  local set = {}
  for _, descriptor in ipairs(list == canonical.EMPTY_ARRAY and {} or list) do
    set[descriptor.observation_id] = descriptor.name
  end
  return set
end

--- Resolve an observation id back to an object, without ever exposing the map.
function entities.resolve(session, observation_id)
  if not session or type(observation_id) ~= "string" then return nil end
  for object, id in pairs(session.entity_ids) do
    if id == observation_id then
      if object.get_pos and object:get_pos() then return object end
      return nil
    end
  end
  return nil
end

--- Test hook.
function entities._test_session(player_name)
  return registry.get_session(player_name, true)
end

return entities
