-- pw_bot_bridge/semantics.lua
--
-- One place that knows what a node or an entity *means*.
--
-- Node-name checks scattered through a perception layer rot the moment a game
-- renames something, and they are impossible to test. Everything the bridge
-- believes about Mineclonia and about PerfectWorld's own materials is
-- registered here, at load time, from the real node definitions.
--
-- Five kinds of fact are kept apart on purpose:
--   node properties     -- what the engine says: walkable, climbable, drawtype
--   PerfectWorld role   -- road surface, structure wall, farmland
--   interaction kind    -- door, gate, container: something a player can use
--   navigation relevance-- obstacle, support, step, climb, passage
--   hazard relevance    -- drowning, damage, fall

local B = pw_bot_bridge
local canonical = B.impl.canonical
local semantics = {}
B.impl.semantics = semantics

-- node name -> array of tags registered explicitly
local node_tags = {}
-- group name -> array of tags every node in that group inherits
local group_tags = {}
-- entity name -> array of tags
local entity_tags = {}
-- node name -> resolved, sorted tag array (built lazily, cleared on register)
local resolved_cache = {}

--- Tags the bridge itself can produce. Documented so a consumer can switch on
--- them instead of on node names.
semantics.KNOWN_TAGS = {
  -- surfaces and terrain
  "ground", "road_surface", "path_surface", "farmland", "shore", "water",
  -- structure
  "structure_material", "structure_wall", "structure_roof", "structure_floor",
  "structure_exterior", "structure_entrance",
  -- openings and furniture
  "door", "door_open", "door_closed", "gate", "gate_open", "gate_closed",
  "trapdoor", "container", "bed", "light_source",
  -- movement
  "stair", "slab", "ladder", "climbable", "passable", "navigation_obstacle",
  "navigation_support", "head_obstacle",
  -- barriers
  "fence", "wall", "glass",
  -- fluids and danger
  "liquid", "liquid_source", "liquid_flowing", "lava", "hazard", "fall_hazard",
  -- interaction
  "interactable", "pointable",
  -- vehicles and future harbour work
  "vehicle", "boat", "dock", "mob", "player", "item",
  -- bookkeeping
  "unknown_node", "not_loaded",
}

-- === Registration API ===

local function store(map, key, tags)
  if type(key) ~= "string" or key == "" then return false end
  local list = map[key] or {}
  for _, tag in ipairs(tags or {}) do
    list[#list + 1] = tostring(tag)
  end
  map[key] = list
  return true
end

--- Attach semantic tags to a concrete node name.
function semantics.register_node_semantics(node_name, tags)
  resolved_cache = {}
  return store(node_tags, node_name, tags)
end

--- Attach semantic tags to every node carrying a group.
function semantics.register_group_semantics(group_name, tags)
  resolved_cache = {}
  return store(group_tags, group_name, tags)
end

--- Attach semantic tags to an entity name.
function semantics.register_entity_semantics(entity_name, tags)
  return store(entity_tags, entity_name, tags)
end

function semantics.registered_node_names()
  local names = {}
  for name in pairs(node_tags) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function semantics.registered_group_names()
  local names = {}
  for name in pairs(group_tags) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function semantics.registered_entity_names()
  local names = {}
  for name in pairs(entity_tags) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- === Node properties ===

--- Drawtypes whose geometry fills the voxel for light purposes.
local SOLID_DRAWTYPES = {
  normal = true, liquid = true, flowingliquid = true, glasslike = true,
  glasslike_framed = true, glasslike_framed_optional = true,
  allfaces = true, allfaces_optional = true,
}

--- Does this node stop the server-side line of sight?
--
-- The engine's own notion of "light passes through me" is `paramtype ==
-- "light"`, and it is the only definition-driven signal available server side.
-- Glass and leaves set it, so the bridge treats them as see-through even though
-- a human eye would disagree about leaves. That divergence is documented in
-- docs/pw-bot/limitations.md rather than papered over with a name check.
function semantics.blocks_sight(def)
  if not def then return true end            -- unregistered node: assume solid
  local drawtype = def.drawtype or "normal"
  if drawtype == "airlike" then return false end
  if def.paramtype == "light" then return false end
  return SOLID_DRAWTYPES[drawtype] == true or drawtype == "nodebox"
    or drawtype == "mesh" or drawtype == "normal"
end

--- Does this node dim the view without stopping it?
function semantics.attenuates_sight(def)
  if not def then return false end
  if def.paramtype ~= "light" then return false end
  local drawtype = def.drawtype or "normal"
  return SOLID_DRAWTYPES[drawtype] == true
end

local function liquid_type(def)
  if not def then return "none" end
  local kind = def.liquidtype or "none"
  if kind == "source" or kind == "flowing" then return kind end
  return "none"
end

--- Collision and selection geometry, normalised.
--
-- `walkable` says the engine will not let a body pass; it says nothing about
-- the shape. A slab is walkable and occupies half a voxel; a fence is walkable
-- and taller than a voxel. Selection geometry is a third, unrelated thing, so
-- all three are reported separately and never conflated.
local function box_list(node_box, fallback_full)
  if type(node_box) ~= "table" then
    -- No box in the definition means the engine's implicit full cube, which
    -- Luanti itself calls "regular".
    if fallback_full then
      return {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}, "regular"
    end
    return canonical.EMPTY_ARRAY, "none"
  end
  local kind = node_box.type or "regular"
  local boxes = {}
  local function add(box)
    if type(box) == "table" and #box >= 6 then
      local out = {}
      for i = 1, 6 do out[i] = canonical.round(tonumber(box[i]) or 0) end
      boxes[#boxes + 1] = out
    end
  end
  if kind == "regular" then
    add({-0.5, -0.5, -0.5, 0.5, 0.5, 0.5})
  elseif kind == "fixed" or kind == "leveled" then
    local fixed = node_box.fixed
    if type(fixed) == "table" and type(fixed[1]) == "table" then
      for _, box in ipairs(fixed) do add(box) end
    else
      add(fixed)
    end
  elseif kind == "wallmounted" then
    add(node_box.wall_top)
    add(node_box.wall_bottom)
    add(node_box.wall_side)
  elseif kind == "connected" then
    -- Connected boxes depend on neighbours; the fixed part is the only piece
    -- that is true regardless of what stands next to the node.
    local fixed = node_box.fixed
    if type(fixed) == "table" and type(fixed[1]) == "table" then
      for _, box in ipairs(fixed) do add(box) end
    else
      add(fixed)
    end
  end
  if #boxes == 0 then
    if fallback_full then
      add({-0.5, -0.5, -0.5, 0.5, 0.5, 0.5})
      return boxes, kind
    end
    return canonical.EMPTY_ARRAY, kind
  end
  return boxes, kind
end

semantics.box_list = box_list

-- === Built-in adapters ===

-- Node names PerfectWorld itself lays as road or path surface. Collected from
-- the compat layer rather than hard-coded, so a palette change here follows the
-- palette change there.
local function collect_perfectworld_surfaces()
  local roads, paths = {}, {}
  local compat = perfectworld and perfectworld.compat
  if not compat then return roads, paths end
  local ok, road = pcall(compat.get_material, "road", {required = false})
  if ok and road and road ~= "air" then roads[road] = true end
  if compat.list_families and compat.get_family_palette then
    for _, family in ipairs(compat.list_families()) do
      local palette = compat.get_family_palette(family)
      if type(palette) == "table" and palette.path then
        paths[palette.path] = true
      end
    end
  end
  return roads, paths
end

--- Walk every registered node once and derive tags from real definitions.
-- Runs after all mods are loaded so Mineclonia's registrations are complete.
function semantics.build_builtin_adapters()
  resolved_cache = {}

  -- Mineclonia conventions, verified against the game's own sources:
  --   doors      -- groups door_bottom / door_top, open state in node meta
  --   fence gates-- group fence_gate; the open node is not walkable
  --   fences     -- group fence
  --   stairs     -- group stair; slabs group slab
  --   ladders    -- climbable = true in the node definition
  semantics.register_group_semantics("door_bottom", {"door", "interactable", "structure_entrance"})
  semantics.register_group_semantics("door_top", {"door", "interactable", "structure_entrance"})
  semantics.register_group_semantics("fence_gate", {"gate", "interactable"})
  semantics.register_group_semantics("fence", {"fence", "navigation_obstacle"})
  semantics.register_group_semantics("stair", {"stair", "navigation_support"})
  semantics.register_group_semantics("slab", {"slab", "navigation_support"})
  semantics.register_group_semantics("trapdoor", {"trapdoor", "interactable"})
  semantics.register_group_semantics("water", {"water", "liquid"})
  semantics.register_group_semantics("lava", {"lava", "liquid", "hazard"})
  semantics.register_group_semantics("soil", {"farmland"})
  semantics.register_group_semantics("glass", {"glass"})
  semantics.register_group_semantics("wall", {"wall", "navigation_obstacle"})
  semantics.register_group_semantics("bed", {"bed", "interactable"})
  semantics.register_group_semantics("container", {"container", "interactable"})

  local roads, paths = collect_perfectworld_surfaces()
  for name in pairs(roads) do
    semantics.register_node_semantics(name, {"road_surface", "ground", "navigation_support"})
  end
  for name in pairs(paths) do
    semantics.register_node_semantics(name, {"path_surface", "ground", "navigation_support"})
  end

  -- Entities. Boats exist in Mineclonia today; docks and harbours do not, so
  -- the dock tags stay registered but unused until ports are built.
  semantics.register_entity_semantics("mcl_boats:boat", {"vehicle", "boat", "interactable"})
  semantics.register_entity_semantics("mcl_boats:chest_boat", {"vehicle", "boat", "container", "interactable"})
  semantics.register_entity_semantics("mcl_boats:seat", {"vehicle", "boat"})
  semantics.register_entity_semantics("__builtin:item", {"item"})
  semantics.register_entity_semantics("__builtin:falling_node", {"hazard"})
end

-- === Resolution ===

local function derive_from_definition(name, def)
  local tags = {}
  local function add(tag) tags[#tags + 1] = tag end

  if name == "air" then
    add("passable")
    return tags
  end
  if name == "ignore" then
    add("not_loaded")
    return tags
  end
  if not def then
    add("unknown_node")
    add("navigation_obstacle")
    return tags
  end

  local groups = def.groups or {}
  local liquid = liquid_type(def)

  if def.walkable == false then
    add("passable")
  else
    add("navigation_obstacle")
    add("navigation_support")
  end
  if def.climbable then add("climbable"); add("ladder") end
  if def.pointable ~= false then add("pointable") end
  if liquid ~= "none" then
    add("liquid")
    add(liquid == "source" and "liquid_source" or "liquid_flowing")
    if (groups.lava or 0) > 0 or name:find("lava", 1, true) then
      add("lava"); add("hazard")
    else
      add("water")
    end
  end
  if (def.damage_per_second or 0) > 0 then add("hazard") end
  if (def.light_source or 0) > 0 then add("light_source") end
  if def.on_rightclick then add("interactable") end
  if def.drawtype == "airlike" then add("passable") end
  if perfectworld and perfectworld.compat and perfectworld.compat.is_livable_ground
    and perfectworld.compat.is_livable_ground(name) then
    add("ground")
  end
  return tags
end

--- Door and gate state, read from the real conventions rather than the name.
--
-- Mineclonia stores a door's open flag in node metadata (`is_open`) and exposes
-- mcl_doors.is_open(); the `_1` / `_2` name suffix is the mirroring variant,
-- not the state, so a substring check would be wrong roughly half the time.
-- A fence gate is a different node when open, and that node is not walkable.
local function state_tags(name, def, pos)
  local tags = {}
  local groups = def and def.groups or {}
  if (groups.door_bottom or 0) > 0 or (groups.door_top or 0) > 0 then
    local open = nil
    if pos and mcl_doors and mcl_doors.is_open then
      local probe = pos
      if (groups.door_top or 0) > 0 then
        probe = {x = pos.x, y = pos.y - 1, z = pos.z}
      end
      local ok, value = pcall(mcl_doors.is_open, probe)
      if ok then open = value end
    end
    if open == nil and def then
      -- Without a position the geometry is the only honest signal left: an
      -- open door leaf no longer blocks the doorway it stands in.
      open = def.walkable == false
    end
    tags[#tags + 1] = open and "door_open" or "door_closed"
  end
  if (groups.fence_gate or 0) > 0 then
    tags[#tags + 1] = (def and def.walkable == false) and "gate_open" or "gate_closed"
  end
  return tags
end

--- Position-independent tags for a node name.
function semantics.tags_for_node_name(name)
  local cached = resolved_cache[name]
  if cached then return cached end
  local def = minetest.registered_nodes[name]
  local collected = derive_from_definition(name, def)
  for _, tag in ipairs(node_tags[name] or {}) do
    collected[#collected + 1] = tag
  end
  if def then
    for group, value in pairs(def.groups or {}) do
      if value and value > 0 then
        for _, tag in ipairs(group_tags[group] or {}) do
          collected[#collected + 1] = tag
        end
      end
    end
  end
  local sorted = canonical.sorted_unique(collected)
  resolved_cache[name] = sorted
  return sorted
end

--- Full description of a node: engine properties plus semantics.
-- `pos` is optional; passing it lets state-carrying nodes (doors) report their
-- real state instead of a geometric guess.
function semantics.describe_node(name, param2, pos)
  local def = minetest.registered_nodes[name]
  local liquid = liquid_type(def)
  local selection, selection_type = box_list(def and def.selection_box,
    def and def.pointable ~= false and (def.drawtype ~= "airlike"))
  local collision, collision_type = box_list(
    (def and (def.collision_box or def.node_box)) or nil,
    def and def.walkable ~= false and name ~= "air")

  local tags = {}
  for _, tag in ipairs(semantics.tags_for_node_name(name)) do
    tags[#tags + 1] = tag
  end
  for _, tag in ipairs(state_tags(name, def, pos)) do
    tags[#tags + 1] = tag
  end

  return {
    name = name,
    param2 = math.floor(tonumber(param2) or 0),
    registered = def ~= nil,
    properties = {
      walkable = def and def.walkable ~= false or false,
      pointable = def and def.pointable ~= false or false,
      diggable = def and def.diggable ~= false or false,
      climbable = (def and def.climbable) and true or false,
      buildable_to = (def and def.buildable_to) and true or false,
      liquid_type = liquid,
      damage_per_second = math.floor((def and def.damage_per_second) or 0),
      light_source = math.floor((def and def.light_source) or 0),
      drawtype = (def and def.drawtype) or (name == "air" and "airlike") or "unknown",
      paramtype = (def and def.paramtype) or "none",
      paramtype2 = (def and def.paramtype2) or "none",
      blocks_sight = semantics.blocks_sight(def),
      attenuates_sight = semantics.attenuates_sight(def),
    },
    selection_box_type = selection_type,
    selection_boxes = selection,
    collision_box_type = collision_type,
    collision_boxes = collision,
    groups = canonical.groups(def and def.groups),
    semantics = canonical.sorted_unique(tags),
  }
end

--- Tags for an entity, from its registered name plus what the engine says.
function semantics.tags_for_entity(entity_name, is_player, properties)
  local tags = {}
  if is_player then
    tags[#tags + 1] = "player"
  end
  for _, tag in ipairs(entity_tags[entity_name] or {}) do
    tags[#tags + 1] = tag
  end
  if properties then
    if properties.physical then tags[#tags + 1] = "navigation_obstacle" end
    if properties.pointable ~= false then tags[#tags + 1] = "pointable" end
  end
  if entity_name and entity_name:find("^mobs") then tags[#tags + 1] = "mob" end
  return canonical.sorted_unique(tags)
end

--- Does a set of tags contain this feature? Used by find_visible_feature.
function semantics.has_tag(tags, wanted)
  for _, tag in ipairs(tags or {}) do
    if tag == wanted then return true end
  end
  return false
end

--- Feature names find_visible_feature accepts.
semantics.FEATURES = {
  "boat", "climbable", "container", "door", "farmland", "fence", "gate",
  "hazard", "ladder", "liquid", "path_surface", "road_surface", "shore",
  "slab", "stair", "structure_entrance", "vehicle", "water",
}

function semantics.is_known_feature(name)
  for _, feature in ipairs(semantics.FEATURES) do
    if feature == name then return true end
  end
  return false
end

function semantics.snapshot()
  return {
    node_rules = #semantics.registered_node_names(),
    group_rules = #semantics.registered_group_names(),
    entity_rules = #semantics.registered_entity_names(),
    features = semantics.FEATURES,
  }
end

--- Test hook: drop the resolved-tag cache.
function semantics._test_clear_cache()
  resolved_cache = {}
end

minetest.register_on_mods_loaded(function()
  local ok, err = pcall(semantics.build_builtin_adapters)
  if not ok then
    minetest.log("error", "[pw_bot_bridge] semantic adapters failed: " .. tostring(err))
  end
end)

return semantics
