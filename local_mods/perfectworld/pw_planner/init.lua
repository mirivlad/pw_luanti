perfectworld = perfectworld or {}
perfectworld.planner = perfectworld.planner or {}

local REGION_SIZE = perfectworld.REGION_SIZE
local MARGIN = 80
local MIN_DISTANCE = 200
perfectworld.planner.REGION_MARGIN = MARGIN
local cache = {}

-- Persistence lives in store.lua, which groups records by the region their id
-- names. Saving one structure used to rewrite every settlement, structure and
-- road in the world; now it rewrites one region.
local store = dofile(minetest.get_modpath("pw_planner") .. "/store.lua")
perfectworld.planner.store = store
store.migrate()

local deep_copy = perfectworld.core.deep_copy
local choice = perfectworld.core.choice

-- === Region Planning ===

function perfectworld.planner.plan_region(rx, rz)
	local cache_key = rx .. "_" .. rz
	local cached = cache[cache_key]
	if cached then
		return deep_copy(cached)
	end

	-- Region planning uses the same stable variation contract as village
	-- planning: independent, labelled hash decisions instead of a PRNG stream.
	local seed_key = table.concat({
		"pwregion",
		perfectworld.world_seed_string,
		"v" .. tostring(perfectworld.PLANNER_VERSION),
		"rs" .. tostring(REGION_SIZE),
		perfectworld.core.coord_tag(rx),
		perfectworld.core.coord_tag(rz),
	}, "|")

	local minp = {x = rx * REGION_SIZE, y = -64, z = rz * REGION_SIZE}
	local maxp = {x = (rx + 1) * REGION_SIZE - 1, y = 256, z = (rz + 1) * REGION_SIZE - 1}

	local settlement_candidates = {}
	local reserved_areas = {}
	local road_anchors = {}

	-- How many settlements a region holds.
	--
	-- One region is a square kilometre. At a mean of 1.1 settlements to a region
	-- the walk between neighbours was long enough that the countryside read as
	-- empty rather than as countryside. A mean of 1.8 puts them close enough to
	-- be a network and still far enough apart to be separate places — and
	-- MIN_DISTANCE keeps two in one region from becoming one sprawl.
	local num_candidates = choice.weighted(seed_key, "candidate_count", {
		{value = 0, weight = 8},
		{value = 1, weight = 32},
		{value = 2, weight = 38},
		{value = 3, weight = 22},
	})

	for i = 0, num_candidates - 1 do
		local x, z
		local valid = false
		for attempt = 1, 50 do
			local label = "candidate:" .. i .. ":attempt:" .. attempt
			x = minp.x + MARGIN + choice.int(seed_key, label .. ":x", 0, REGION_SIZE - 2 * MARGIN - 1)
			z = minp.z + MARGIN + choice.int(seed_key, label .. ":z", 0, REGION_SIZE - 2 * MARGIN - 1)

			valid = true
			for _, existing in ipairs(settlement_candidates) do
				local ddx = existing.x - x
				local ddz = existing.z - z
				if ddx * ddx + ddz * ddz < MIN_DISTANCE * MIN_DISTANCE then
					valid = false
					break
				end
			end

			if valid then
				break
			end
		end

		if not valid then
			break
		end

		-- Towns are rare on purpose. A world where one settlement in five is a
		-- town is a world with no countryside in it, and the point of a town is
		-- that arriving at one means something.
		local stype = choice.weighted(seed_key, "candidate:" .. i .. ":type", {
			{value = "farm", weight = 38},
			{value = "hamlet", weight = 38},
			{value = "village", weight = 18},
			{value = "town", weight = 6},
		})

		local priority
		if stype == "farm" then
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 1, 2)
		elseif stype == "hamlet" then
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 2, 4)
		elseif stype == "town" then
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 6, 8)
		else
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 4, 5)
		end

		local candidate_id = perfectworld.core.settlement_id(rx, rz, i)
		local structure_id = perfectworld.core.structure_id(candidate_id, 0)
		local rotation = choice.pick(seed_key, "candidate:" .. i .. ":rotation", {0, 90, 180, 270})

		local structure_name
		if stype == "village" or stype == "town" then
			structure_name = "__village__" -- marker: will be processed by village planner
		elseif stype == "hamlet" then
			structure_name = "pw_farmstead_v1"
		else
			structure_name = "pw_farmstead_v1"
		end

		table.insert(settlement_candidates, {
			id = candidate_id,
			index = i,
			x = x,
			z = z,
			type = stype,
			priority = priority,
			connection_required = true,
			structure_name = structure_name,
			structure_id = structure_id,
			rotation = rotation,
			status = "candidate",
			rx = rx,
			rz = rz,
		})

		table.insert(reserved_areas, {
			id = perfectworld.core.reserve_id(rx, rz, i),
			kind = "settlement_candidate",
			ref = candidate_id,
			minp = {x = x - 12, y = -64, z = z - 12},
			maxp = {x = x + 12, y = 256, z = z + 12},
		})

		table.insert(road_anchors, {
			id = perfectworld.core.road_anchor_id(rx, rz, i),
			ref = candidate_id,
			x = x,
			z = z,
			kind = "settlement_connection",
		})
	end

	local plan = {
		id = perfectworld.get_region_id(rx, rz),
		rx = rx,
		rz = rz,
		minp = minp,
		maxp = maxp,
		planner_version = perfectworld.PLANNER_VERSION,
		settlement_candidates = settlement_candidates,
		landmarks = {},
		road_anchors = road_anchors,
		reserved_areas = reserved_areas,
	}

	cache[cache_key] = deep_copy(plan)
	return deep_copy(plan)
end

function perfectworld.planner.get_region_at_pos(pos)
	local rx, rz = perfectworld.get_region_coords(pos)
	return perfectworld.planner.plan_region(rx, rz)
end

-- === Settlement Tracking ===

function perfectworld.planner.is_placed(settlement_id)
	return store.get("placed", settlement_id) == true
end

function perfectworld.planner.mark_placed(settlement_id)
	store.put("placed", settlement_id, true)
end

function perfectworld.planner.list_placed()
	return store.ids("placed")
end

function perfectworld.planner._test_unmark_placed(settlement_id)
	store.delete("placed", settlement_id)
end

-- === Structure Tracking ===

function perfectworld.planner.record_structure(record)
	store.put("structures", record.structure_id, deep_copy(record))
end

function perfectworld.planner.save_structure(structure_id, record)
	store.put("structures", structure_id, deep_copy(record))
end

function perfectworld.planner.get_structure(structure_id)
	return deep_copy(store.get("structures", structure_id))
end

function perfectworld.planner.list_structures()
	local data = store.all("structures")
	local out = {}
	for _, id in ipairs(store.ids("structures")) do
		table.insert(out, deep_copy(data[id]))
	end
	return out
end

function perfectworld.planner._test_clear_structure(structure_id)
	store.delete("structures", structure_id)
end

-- === Settlement Plan Persistence ===

function perfectworld.planner.save_settlement_plan(settlement_id, plan)
	store.put("settlements", settlement_id, deep_copy(plan))
end

function perfectworld.planner.get_settlement_plan(settlement_id)
	return deep_copy(store.get("settlements", settlement_id))
end

function perfectworld.planner.list_settlements()
	return store.ids("settlements")
end

function perfectworld.planner._test_clear_settlement(settlement_id)
	store.delete("settlements", settlement_id)
end

-- === Road Persistence ===

function perfectworld.planner.save_road(road)
	local record = deep_copy(road)
	if record.cells == nil
		and perfectworld.roads
		and perfectworld.roads.rasterize_record then
		record.cells = perfectworld.roads.rasterize_record(record)
	end
	store.put("roads", record.id, record)
end

function perfectworld.planner.get_road(road_id)
	return deep_copy(store.get("roads", road_id))
end

function perfectworld.planner.list_roads()
	local data = store.all("roads")
	local out = {}
	for _, id in ipairs(store.ids("roads")) do
		table.insert(out, deep_copy(data[id]))
	end
	return out
end

perfectworld.roads.set_provider({
	save = perfectworld.planner.save_road,
	get = perfectworld.planner.get_road,
	list = perfectworld.planner.list_roads,
})

-- === Cache Management ===

function perfectworld.planner._test_clear_cache()
	cache = {}
	store.drop_cache()
	if perfectworld.roads and perfectworld.roads._test_clear_link_cache then
		perfectworld.roads._test_clear_link_cache()
	end
end

-- === Candidate Type Helpers ===

-- Composite candidates (like __village__) represent a settlement that requires
-- multi-structure layout planning, not a single structure placement.
perfectworld.planner.COMPOSITE_MARKER = "__village__"

function perfectworld.planner.is_composite_candidate(candidate)
  return candidate and candidate.structure_name == perfectworld.planner.COMPOSITE_MARKER
end

-- === Village Generation System ===
-- Deterministic multi-structure settlement generation with biome-aware
-- profiles, three archetypes, and a grammar-based planning pipeline.
--
-- Variation contract: every planning decision is an independent hash of
-- (seed_key, label) via perfectworld.core.choice. There is no sequential
-- stream, so inserting a new decision never shifts the existing ones.

local choice = perfectworld.core.choice
local hash32 = perfectworld.core.hash32
local SETTLEMENT_GRAMMAR_VERSION = 3

--- The longest a village street may be, so the settlement stays inside the
--- area `emerge_village_area` generates for it.
perfectworld.planner.MAX_STREET_LENGTH = 96

--- The same for a town, which emerges twice the ground around it.
perfectworld.planner.MAX_TOWN_STREET_LENGTH = 190
perfectworld.planner.SETTLEMENT_GRAMMAR_VERSION = SETTLEMENT_GRAMMAR_VERSION

local ARCHETYPES = {"linear", "compact", "hillside"}
perfectworld.planner.ARCHETYPES = ARCHETYPES

-- Stable presentation order for known village roles. Validation itself is
-- generic and also handles roles added by later grammar versions.
local ROLE_ORDER = {
  "dwelling", "fishery", "farm", "sawmill", "mine_workshop",
  "barn", "apiary", "storage", "central",
}
local MIN_DWELLINGS = 2
perfectworld.planner.ROLE_ORDER = ROLE_ORDER
perfectworld.planner.MIN_DWELLINGS = MIN_DWELLINGS

local function ordered_requirement_roles(requirements)
  local roles = {}
  if (requirements and requirements.dwelling or 0) > 0 then
    roles[#roles + 1] = "dwelling"
  end
  for role, count in pairs(requirements or {}) do
    if role ~= "dwelling" and (tonumber(count) or 0) > 0 then
      roles[#roles + 1] = role
    end
  end
  table.sort(roles, function(a, b)
    if a == "dwelling" then return true end
    if b == "dwelling" then return false end
    return a < b
  end)
  return roles
end

function perfectworld.planner.missing_required_roles(plan_or_counts, requirements)
  local counts = plan_or_counts or {}
  if type(counts.role_counts) == "table" then
    counts = counts.role_counts
  end
  local missing = {}
  for _, role in ipairs(ordered_requirement_roles(requirements)) do
    local required = math.max(math.floor(tonumber(requirements[role]) or 0), 0)
    if (tonumber(counts[role]) or 0) < required then
      missing[#missing + 1] = role .. "<" .. required
    end
  end
  return missing
end

-- === Terrain sampling ===
--
-- Planning reads terrain through a sampler object rather than calling
-- minetest.get_node directly. The default sampler reads the live map; tests
-- inject synthetic terrain so layout rules can be exercised without depending
-- on which mapblocks happen to be generated.
--
-- Scanning a whole column per probe is expensive, so every sampler memoises.

local function make_world_terrain()
  local cache = {}
  local terrain = {kind = "world"}

  function terrain.sample_column(x, z)
    local key = x .. ":" .. z
    local cached = cache[key]
    if cached ~= nil then
      if cached == false then return nil end
      return perfectworld.core.deep_copy(cached)
    end
    local tree_count = 0
    local vegetation_count = 0
    for y = 256, -64, -1 do
      local node = minetest.get_node({x = x, y = y, z = z})
      if node.name ~= "air" and node.name ~= "ignore" then
        local class = perfectworld.compat.classify_node(node.name)
        if class.vegetation then
          vegetation_count = vegetation_count + 1
          -- A 6-node survey lattice often crosses a crown without hitting its
          -- one-block trunk. Both trunk and canopy are physical evidence that
          -- the site has a local wood resource.
          if class.tree or class.leaves then tree_count = tree_count + 1 end
        else
          local result = {
            y = y,
            node_name = node.name,
            buildable = class.buildable_ground,
            soil = class.soil,
            liquid = class.liquid
              or perfectworld.compat.is_unbuildable_surface(node.name),
            tree = tree_count > 0,
            tree_count = tree_count,
            vegetation_count = vegetation_count,
            stone = class.stone,
          }
          cache[key] = result
          return perfectworld.core.deep_copy(result)
        end
      end
    end
    cache[key] = false
    return nil
  end

  function terrain.surface_y(x, z)
    local column = terrain.sample_column(x, z)
    return column and column.y or nil
  end

  --- True when the column cannot carry a building.
  --
  -- Checking only for "water" in the node name is not enough: a frozen ocean
  -- is a perfectly flat, perfectly solid, perfectly walkable surface of ice,
  -- and the planner will happily lay a crossroads across it. Anything liquid,
  -- icy, or sitting directly on top of liquid is unbuildable ground.
  function terrain.is_liquid(x, z)
    local column = terrain.sample_column(x, z)
    if not column then return false end
    if column.liquid then return true end
    -- thin shelf: solid crust directly over liquid
    for depth = 1, 3 do
      local below = minetest.get_node({x = x, y = column.y - depth, z = z}).name
      if perfectworld.compat.is_liquid_node(below) then return true end
      if below == "air" or below == "ignore" then break end
    end
    return false
  end

  --- Soil, sand or snow-covered soil: ground a village would be built on.
  function terrain.is_livable(x, z)
    local column = terrain.sample_column(x, z)
    return column and column.buildable or false
  end

  function terrain.reset()
    cache = {}
  end

  return terrain
end

--- Deterministic synthetic terrain for tests and for probing layout rules.
-- `spec` fields: base, slope_x, slope_z, relief, relief_scale, water_line,
-- seed_key.
--
-- Relief is coherent value noise on a lattice, not per-column white noise:
-- real ground is continuous, and white noise would reject every site for
-- "slope" no matter how well the generator adapts.
function perfectworld.planner.make_synthetic_terrain(spec)
  spec = spec or {}
  local base = spec.base or 32
  local slope_x = spec.slope_x or 0
  local slope_z = spec.slope_z or 0
  local relief = spec.relief or 0
  local scale = spec.relief_scale or 24
  local water_line = spec.water_line
  local seed_key = spec.seed_key or "synthetic"
  local cache = {}
  local lattice = {}
  local terrain = {kind = "synthetic", spec = spec}

  local function lattice_value(gx, gz)
    local key = gx .. ":" .. gz
    local value = lattice[key]
    if value == nil then
      value = perfectworld.core.choice.range(seed_key, "relief:" .. key, -1, 1)
      lattice[key] = value
    end
    return value
  end

  local function smooth_noise(x, z)
    if relief <= 0 then return 0 end
    local fx, fz = x / scale, z / scale
    local x0, z0 = math.floor(fx), math.floor(fz)
    local tx, tz = fx - x0, fz - z0
    -- smoothstep keeps the first derivative continuous across cell borders
    tx = tx * tx * (3 - 2 * tx)
    tz = tz * tz * (3 - 2 * tz)
    local v00 = lattice_value(x0, z0)
    local v10 = lattice_value(x0 + 1, z0)
    local v01 = lattice_value(x0, z0 + 1)
    local v11 = lattice_value(x0 + 1, z0 + 1)
    local top = v00 + (v10 - v00) * tx
    local bottom = v01 + (v11 - v01) * tx
    return (top + (bottom - top) * tz) * relief
  end

  local function calculated_height(x, z)
    return math.floor(base + x * slope_x + z * slope_z + smooth_noise(x, z))
  end

  function terrain.sample_column(x, z)
    local key = x .. ":" .. z
    local cached = cache[key]
    if cached == nil then
      if type(spec.column_at) == "function" then
        cached = perfectworld.core.deep_copy(spec.column_at(x, z) or {})
      else
        cached = {}
      end
      cached.y = cached.y or calculated_height(x, z)
      if cached.liquid == nil then
        cached.liquid = water_line ~= nil and cached.y <= water_line
      end
      if cached.buildable == nil then cached.buildable = not cached.liquid end
      if cached.soil == nil then cached.soil = cached.buildable end
      if cached.tree == nil then cached.tree = false end
      if cached.tree_count == nil then cached.tree_count = cached.tree and 1 or 0 end
      if cached.vegetation_count == nil then
        cached.vegetation_count = cached.tree_count
      end
      if cached.stone == nil then cached.stone = false end
      cache[key] = cached
    end
    return perfectworld.core.deep_copy(cached)
  end

  function terrain.surface_y(x, z)
    return terrain.sample_column(x, z).y
  end

  function terrain.is_liquid(x, z)
    return terrain.sample_column(x, z).liquid
  end

  function terrain.is_livable(x, z)
    return terrain.sample_column(x, z).buildable
  end

  function terrain.reset()
    cache = {}
  end

  return terrain
end

local world_terrain = make_world_terrain()
perfectworld.planner._world_terrain = world_terrain
perfectworld.planner.ecology = dofile(
  minetest.get_modpath("pw_planner") .. "/ecology.lua")
perfectworld.planner.worksites = dofile(
  minetest.get_modpath("pw_planner") .. "/worksites.lua")

-- === Seed key ===
-- Depends only on world seed, region, candidate identity and planner version,
-- exactly as documented in docs/development.md. Terrain influences the plan
-- through decision *weights*, never through the seed.

-- `world_seed_override` exists so the diversity harness can probe the
-- "different world seed" axis without regenerating the map. Normal generation
-- never sets it.
local function village_seed_key(candidate)
  return table.concat({
    "pwv3",
    candidate.world_seed_override or perfectworld.world_seed_string,
    "v" .. tostring(perfectworld.PLANNER_VERSION),
    "g" .. tostring(SETTLEMENT_GRAMMAR_VERSION),
    "rs" .. tostring(perfectworld.REGION_SIZE),
    perfectworld.core.coord_tag(candidate.rx or 0),
    perfectworld.core.coord_tag(candidate.rz or 0),
    tostring(candidate.id),
  }, "|")
end

perfectworld.planner.village_seed_key = village_seed_key

-- === Archetype Selection ===

local function archetype_weights(profile)
  local roughness = profile.roughness or 0
  local water = profile.water_proximity or 999
  local family = profile.biome_family or "temperate"

  local w_linear = 35
  local w_compact = 40
  local w_hillside = 25

  if roughness > 3 then
    w_hillside = w_hillside + 30
    w_compact = w_compact - 10
  end
  if roughness > 6 then
    w_hillside = w_hillside + 25
    w_linear = w_linear - 10
    w_compact = w_compact - 15
  end
  if water < 20 then
    w_linear = w_linear + 25
    w_compact = w_compact - 10
  end
  if family == "dry" or family == "rocky" then
    w_compact = w_compact + 15
  end

  return {
    {value = "linear", weight = math.max(w_linear, 1)},
    {value = "compact", weight = math.max(w_compact, 1)},
    {value = "hillside", weight = math.max(w_hillside, 1)},
  }
end

local function select_archetype(seed_key, profile)
  return choice.weighted(seed_key, "archetype", archetype_weights(profile))
end

perfectworld.planner._archetype_weights = archetype_weights

local shore_tangent_indices = {
  ["1:0"] = 1,
  ["1:1"] = 2,
  ["0:1"] = 3,
  ["-1:1"] = 4,
  ["-1:0"] = 5,
  ["-1:-1"] = 6,
  ["0:-1"] = 7,
  ["1:-1"] = 8,
}

local function shore_tangent_index(direction)
  if type(direction) ~= "table" then return nil end
  local tangent_x = -(tonumber(direction.z) or 0)
  local tangent_z = tonumber(direction.x) or 0
  local sign_x = tangent_x == 0 and 0 or (tangent_x > 0 and 1 or -1)
  local sign_z = tangent_z == 0 and 0 or (tangent_z > 0 and 1 or -1)
  return shore_tangent_indices[sign_x .. ":" .. sign_z]
end

--- How much street a settlement needs, and how it is arranged.
--
-- Street length used to be an independent random number: a village aiming at
-- twelve buildings and one aiming at three were both given thirty to eighty
-- nodes of frontage, and the large one simply ran out of road. Measured on
-- perfectly flat synthetic ground, where terrain can be ruled out entirely,
-- only 34 of 50 villages reached the size they were planned for, and every
-- rejection was `lot_overlap` or `road_conflict` — geometry, not ground.
--
-- The frontage a settlement needs is two sides of street, a lot every average
-- gap, and half again on top, because a good third of the anchors are lost to
-- their neighbours and to the carriageway itself.
--
-- That figure is a floor, not a replacement. Sizing the street *only* from the
-- target was tried and was worse in every direction: small settlements ended up
-- with less street than the old random length gave them and the valid rate fell
-- from 177 in 241 to 135.
--
-- Separate from `create_village_profile` because the rule is worth checking on
-- its own, at sizes the profile generator does not currently produce.
function perfectworld.planner.street_plan_for(profile)
  local seed_key = profile.seed_key
  local spacing = profile.lot_spacing
  local average_gap = (spacing.min_gap + spacing.max_gap) / 2
  local frontage = math.ceil(profile.target_lots / 2 * average_gap * 1.5)

  local town = profile.settlement_type == "town" or profile.settlement_type == "city"
  local branches
  if profile.archetype == "compact" then
    -- A larger settlement grows side lanes rather than one endless street. A
    -- town is allowed more of them: past a certain size a single street with
    -- three turnings is a village that got long, not a town.
    branches = math.max(1, math.min(town and 6 or 3,
      1 + math.floor(profile.target_lots / 5)))
  elseif town then
    branches = math.max(1, math.min(4, math.floor(profile.target_lots / 6)))
  elseif profile.target_lots >= 8 then
    branches = 1
  else
    branches = choice.bool(seed_key, "road:branches:linear", 0.4) and 1 or 0
  end
  local crossing = profile.archetype == "compact"
    and choice.bool(seed_key, "road:crossing", 0.35) or false

  -- The cap keeps the whole settlement inside the area `emerge_village_area`
  -- generates: a street running past it would be planned against terrain that
  -- does not exist yet and rejected for having no surface.
  -- A town emerges twice the ground a village does, so its streets may be twice
  -- as long. The cap is not a style choice: a street past the emerged area is
  -- planned against terrain that does not exist and rejected for having none.
  local cap = perfectworld.planner.MAX_STREET_LENGTH
  if profile.settlement_type == "town" or profile.settlement_type == "city" then
    cap = perfectworld.planner.MAX_TOWN_STREET_LENGTH
  end
  local main_length = math.max(30, math.min(cap,
    math.max(choice.int(seed_key, "road:main_length", 30, 80), frontage)))

  return {
    main_length = main_length,
    branch_length = math.max(14, math.min(40, math.ceil(main_length * 0.45))),
    branches = branches,
    curve = choice.range(seed_key, "road:curve", 0, 0.30),
    crossing = crossing,
    direction_index = choice.index(seed_key, "road:main:direction", 8),
  }
end

-- === Village Profile ===

function perfectworld.planner.create_village_profile(candidate, environment)
  local seed_key = village_seed_key(candidate)
  local profile = {
    village_id = candidate.id,
    generator_version = perfectworld.PLANNER_VERSION,
    settlement_grammar_version = SETTLEMENT_GRAMMAR_VERSION,
    environment = environment,
    seed_key = seed_key,
    seed_hash = hash32(seed_key),
  }

  profile.archetype = select_archetype(seed_key, environment)

  -- What the region asked for. A town is not a large village: it is planned to
  -- a different size, walled, and built out of stone as well as timber, so the
  -- type has to survive into the profile rather than being inferred from the
  -- lot count afterwards.
  profile.settlement_type = candidate.type or "village"

  if profile.settlement_type == "town" then
    profile.size_class = "town"
    profile.target_lots = choice.int(seed_key, "target_lots:town", 14, 24)
    profile.density = choice.range(seed_key, "density:town", 0.50, 0.75)
  else
    profile.size_class = choice.weighted(seed_key, "size_class", {
      {value = "small", weight = 30},
      {value = "medium", weight = 50},
      {value = "large", weight = 20},
    })
    if profile.size_class == "small" then
      profile.target_lots = choice.int(seed_key, "target_lots:small", 3, 5)
      profile.density = choice.range(seed_key, "density:small", 0.30, 0.45)
    elseif profile.size_class == "medium" then
      profile.target_lots = choice.int(seed_key, "target_lots:medium", 5, 8)
      profile.density = choice.range(seed_key, "density:medium", 0.35, 0.55)
    else
      profile.target_lots = choice.int(seed_key, "target_lots:large", 8, 12)
      profile.density = choice.range(seed_key, "density:large", 0.40, 0.65)
    end
  end

  profile.lot_spacing = {
    min_gap = choice.int(seed_key, "spacing:min_gap", 6, 10),
    max_gap = choice.int(seed_key, "spacing:max_gap", 10, 16),
    depth = choice.int(seed_key, "spacing:depth", 6, 10),
    set_back = choice.int(seed_key, "spacing:set_back", 3, 5),
  }
  if profile.lot_spacing.max_gap <= profile.lot_spacing.min_gap then
    profile.lot_spacing.max_gap = profile.lot_spacing.min_gap + 4
  end

  profile.road_character = perfectworld.planner.street_plan_for(profile)

  local specialization = environment.specialization
  local definition = specialization
    and perfectworld.settlements.get_specialization(specialization) or nil
  if not definition and type(environment.ecology) == "table" then
    for _, result in ipairs(
      perfectworld.settlements.evaluate_specializations(environment.ecology)) do
      if result.viable then
        specialization = result.id
        definition = result.definition
        break
      end
    end
  end
  -- `create_village_profile` remains a public pure helper used by analysis
  -- tools that predate ecological site selection. Real village planning always
  -- supplies a selected viable specialization.
  if not definition then
    specialization = "farming"
    definition = perfectworld.settlements.get_specialization(specialization)
  end

  profile.specialization = specialization
  profile.specialization_score = environment.specialization_score
  profile.specialization_definition = deep_copy(definition)
  profile.required_role_counts = deep_copy(definition.required_role_counts or {})
  profile.required_worksite = definition.required_worksite
  profile.resource_features = deep_copy(definition.resource_features or {})
  profile.role_variants = deep_copy(definition.role_variants or {})
  profile.required_roles = ordered_requirement_roles(profile.required_role_counts)
  profile.optional_roles = deep_copy(definition.optional_roles or {})
  if specialization == "fishing" then
    local direction_index = shore_tangent_index(
      environment.ecology and environment.ecology.shore_direction)
    if direction_index then
      profile.road_character.direction_index = direction_index
    end
  end

  -- Mandatory roles come first so terrain can never leave a decorative lot
  -- while silently dropping the work that defines the settlement.
  local roles = {}
  for _, role in ipairs(profile.required_roles) do
    local count = math.max(
      math.floor(tonumber(profile.required_role_counts[role]) or 0), 0)
    for _ = 1, count do roles[#roles + 1] = role end
  end
  profile.target_lots = math.max(profile.target_lots, #roles)

  -- Roles a settlement only ever wants one of. A village square with three
  -- wells in it is not a bigger village square; the optional-role draw is
  -- uniform and a large settlement drew the well again and again.
  local once_only = {central = true}
  local taken = {}
  for _, role in ipairs(roles) do taken[role] = true end

  while #roles < profile.target_lots do
    local slot = #roles + 1
    local role = choice.pick(seed_key, "roles:optional:" .. slot,
      profile.optional_roles)
    if not role then break end
    if once_only[role] and taken[role] then
      -- Already have one. Fall back to a dwelling, which a settlement can
      -- always use another of, rather than leaving the slot empty.
      role = "dwelling"
    end
    taken[role] = true
    roles[#roles + 1] = role
  end
  profile.structure_roles = roles

  local family = environment.biome_family or "temperate"
  local palette = perfectworld.compat.get_family_palette(family)
  if not palette then
    family = "temperate"
    palette = perfectworld.compat.get_family_palette(family)
  end
  profile.material_palette = palette
  profile.palette_id = family

  -- The architectural style of this settlement, and the buildings it may use.
  --
  -- One style per village, hashed from the village's own id and constrained by
  -- biome family. A village that mixed styles would read as a sample book
  -- rather than a place, so this decides once and every lot obeys it.
  --
  -- Only the roles that genuinely correspond are taken from the catalogue.
  -- `central` is the well at the middle of a village and `fishery` is a
  -- building carrying a worksite contract; neither is something the scheme
  -- vocabulary expresses, so both keep the structure the specialization named.
  if perfectworld.schemes and profile.village_id then
    local style = perfectworld.schemes.style_for(profile.village_id, family)
    profile.style = style
    -- A town draws on the tall catalogue as well as its regional one. Height
    -- belongs to the place, not to the region's way of building, so a northern
    -- town builds nordic and tall rather than having to choose.
    local opts = {urban = profile.settlement_type == "town"
      or profile.settlement_type == "city"}
    if style then
      for role, _ in pairs(profile.role_variants) do
        local variants = perfectworld.schemes.variants_for(style, role, opts)
        if variants then profile.role_variants[role] = variants end
      end
      -- Roles the specialization never named a variant for still need one.
      for _, role in ipairs(profile.structure_roles or {}) do
        if not profile.role_variants[role] then
          local variants = perfectworld.schemes.variants_for(style, role, opts)
          if variants then profile.role_variants[role] = variants end
        end
      end
    end
  end

  profile.variation_parameters = {
    orientation_noise = choice.range(seed_key, "variation:orientation_noise", 0, 0.3),
    spacing_jitter = choice.range(seed_key, "variation:spacing_jitter", 0, 0.4),
  }

  return profile
end

-- === Village Grammar: Road Network ===
-- Main streets are snapped to one of eight compass directions: free-angle
-- polylines turn into visually noisy staircases on a block grid.

local function direction_from_index(index)
  local angle = (index - 1) * math.pi / 4
  return math.cos(angle), math.sin(angle)
end

local function build_road_network(seed_key, center, profile, terrain)
  local roads = {}
  local cx, cz = center.x, center.z
  local curve = profile.road_character.curve or 0
  local main_len = profile.road_character.main_length or 40
  local branches = profile.road_character.branches or 0
  local half = math.floor(main_len / 2)
  local mdx, mdz = direction_from_index(profile.road_character.direction_index or 1)

  local function road_id(kind, index)
    return profile.village_id .. "_road_" .. kind .. "_" .. index
  end

  local function main_points(label, dx, dz, from, to, curviness)
    local points = {}
    for i = from, to, 2 do
      local px = cx + dx * i
      local pz = cz + dz * i
      if curviness > 0 and i ~= 0 then
        local bend = choice.range(seed_key, label .. ":bend:" .. i, -1, 1) * curviness * math.abs(i)
        px = px - dz * bend
        pz = pz + dx * bend
      end
      table.insert(points, {x = math.floor(px + 0.5), z = math.floor(pz + 0.5)})
    end
    return points
  end

  if profile.archetype == "linear" or profile.archetype == "compact" then
    local linear = profile.archetype == "linear"
    table.insert(roads, {
      id = road_id("main", 1),
      points = main_points("road:main", mdx, mdz, -half, half,
        linear and curve or curve * 0.5),
      width = 3,
      kind = "main_street",
    })
    if profile.road_character.crossing then
      local cross_half = math.floor(main_len * 0.4)
      local pdx, pdz = -mdz, mdx
      table.insert(roads, {
        id = road_id("cross", 1),
        points = main_points("road:cross", pdx, pdz, -cross_half, cross_half, 0),
        width = 2,
        kind = "cross_street",
      })
    end
    -- A linear settlement large enough to need one gets a side lane too. It is
    -- still linear: one street with a turning off it, not a grid. `branches`
    -- was computed for every archetype and only ever read by the compact one,
    -- so a long thin village had nowhere to put its last houses.
    for b = 1, branches do
      local label = "road:branch:" .. b
      local turn = choice.pick(seed_key, label .. ":turn", {-1, 1})
      local bdx, bdz = -mdz * turn, mdx * turn
      local b_len = profile.road_character.branch_length
        or choice.int(seed_key, label .. ":length", 14, 34)
      -- Spread the turnings along the street instead of drawing each one at an
      -- independent random point: three branches that all came out near the
      -- same place would overlap each other and add no frontage at all.
      local span = math.max(half * 2 - 8, 1)
      local seat = -half + 4 + math.floor(span * (b - 0.5) / branches + 0.5)
      local anchor = seat + choice.int(seed_key, label .. ":anchor_jitter", -4, 4)
      anchor = math.max(-half + 4, math.min(half - 4, anchor))
      local bx = cx + mdx * anchor
      local bz = cz + mdz * anchor
      local b_points = {}
      for i = 0, b_len, 2 do
        table.insert(b_points, {x = math.floor(bx + bdx * i + 0.5), z = math.floor(bz + bdz * i + 0.5)})
      end
      table.insert(roads, {
        id = road_id("branch", b),
        points = b_points,
        width = 2,
        kind = "branch",
      })
    end

  else -- hillside
    -- Follow the contour: shift the street sideways whenever the next sample
    -- would climb more than three blocks.
    local points = {}
    local prev_y = nil
    for i = -half, half, 2 do
      local px = cx + mdx * i
      local pz = cz + mdz * i
      if prev_y then
        local best_px, best_pz, best_delta = px, pz, math.huge
        for lateral = -6, 6, 2 do
          local lx = math.floor(px - mdz * lateral + 0.5)
          local lz = math.floor(pz + mdx * lateral + 0.5)
          local ly = terrain.surface_y(lx, lz)
          if ly then
            local delta = math.abs(ly - prev_y)
            if delta < best_delta then
              best_delta = delta
              best_px, best_pz = lx, lz
            end
            if delta <= 1 then break end
          end
        end
        px, pz = best_px, best_pz
      end
      local ix, iz = math.floor(px + 0.5), math.floor(pz + 0.5)
      prev_y = terrain.surface_y(ix, iz) or prev_y
      table.insert(points, {x = ix, z = iz})
    end
    table.insert(roads, {
      id = road_id("main", 1),
      points = points,
      width = 3,
      kind = "contour_street",
    })
    if branches > 0 then
      -- A short spur climbing away from the contour street.
      local anchor_index = choice.index(seed_key, "road:spur:anchor", math.max(#points, 1))
      local anchor = points[anchor_index] or {x = cx, z = cz}
      local turn = choice.pick(seed_key, "road:spur:turn", {-1, 1})
      local sdx, sdz = -mdz * turn, mdx * turn
      local spur_len = choice.int(seed_key, "road:spur:length", 10, 22)
      local spur_points = {}
      for i = 0, spur_len, 2 do
        table.insert(spur_points, {
          x = math.floor(anchor.x + sdx * i + 0.5),
          z = math.floor(anchor.z + sdz * i + 0.5),
        })
      end
      table.insert(roads, {
        id = road_id("spur", 1),
        points = spur_points,
        width = 2,
        kind = "spur",
      })
    end
  end

  -- Trim each street to the stretch that is actually walkable ground.
  --
  -- Road polylines are laid out geometrically, before any terrain is
  -- consulted. Left untrimmed, a street runs straight off a clifftop, down a
  -- rock face and into the sea, which is the single most obvious way a
  -- generated settlement stops looking built.
  local MAX_STEP = 3
  local function trim(points)
    if #points < 2 then return points end

    local function usable(pt, previous_y)
      local y = terrain.surface_y(pt.x, pt.z)
      if not y then return nil end
      if terrain.is_liquid(pt.x, pt.z) then return nil end
      if previous_y and math.abs(y - previous_y) > MAX_STEP then return nil end
      return y
    end

    -- Start from the nearest usable point to the settlement centre. Even
    -- length streets have no exact midpoint; if the first of the two equally
    -- near points is water, the dry half must remain available.
    local anchor, anchor_y, best = nil, nil, math.huge
    for i, pt in ipairs(points) do
      local y = usable(pt)
      if y then
        local dx, dz = pt.x - cx, pt.z - cz
        local d = dx * dx + dz * dz
        if d < best then
          best, anchor, anchor_y = d, i, y
        end
      end
    end
    if not anchor then return {} end

    local first, last = anchor, anchor
    local previous_y = anchor_y
    for i = anchor - 1, 1, -1 do
      local y = usable(points[i], previous_y)
      if not y then break end
      previous_y, first = y, i
    end
    previous_y = anchor_y
    for i = anchor + 1, #points do
      local y = usable(points[i], previous_y)
      if not y then break end
      previous_y, last = y, i
    end

    local trimmed = {}
    for i = first, last do table.insert(trimmed, points[i]) end
    return trimmed
  end

  -- Drop degenerate roads (fewer than two distinct points).
  local cleaned = {}
  for _, road in ipairs(roads) do
    road.points = trim(road.points)
    local distinct = {}
    local count = 0
    for _, pt in ipairs(road.points) do
      local key = pt.x .. ":" .. pt.z
      if not distinct[key] then
        distinct[key] = true
        count = count + 1
      end
    end
    if count >= 2 then table.insert(cleaned, road) end
  end
  return cleaned
end

--- Set of world cells covered by the road surface, keyed "x:z".
local function road_cell_set(roads)
  local cells = {}
  for _, road in ipairs(roads) do
    for key, cell in pairs(
      perfectworld.roads.cell_set(road.points or {}, road.width or 2)) do
      cells[key] = cell
    end
  end
  return cells
end

perfectworld.planner._road_cell_set = road_cell_set

-- === Village Grammar: Lot Allocation ===

--- Rotation whose road connector points most directly at `target`.
local function orient_to_road(def, origin, target, seed_key, label)
  local rotations = def.rotations or {0}
  if #rotations == 1 then return rotations[1] end

  local connector
  for _, c in ipairs(def.connectors or {}) do
    if c.type == "road" and c.offset_pos then
      connector = c.offset_pos
      break
    end
  end
  if not connector then
    return choice.pick(seed_key, label, rotations)
  end

  local dx = target.x - origin.x
  local dz = target.z - origin.z
  local length = math.sqrt(dx * dx + dz * dz)
  if length < 0.5 then
    return choice.pick(seed_key, label, rotations)
  end
  dx, dz = dx / length, dz / length

  local best, best_score = nil, -math.huge
  for _, rotation in ipairs(rotations) do
    local rotated = perfectworld.structures.rotate_point(connector, rotation)
    local rlen = math.sqrt(rotated.x * rotated.x + rotated.z * rotated.z)
    if rlen > 0 then
      local score = (rotated.x / rlen) * dx + (rotated.z / rlen) * dz
      if score > best_score + 1e-9 then
        best_score = score
        best = rotation
      end
    end
  end
  return best or rotations[1]
end

perfectworld.planner._orient_to_road = orient_to_road

--- Candidate lot anchors along each road, on both sides.
local function lot_anchors(seed_key, roads, profile)
  local anchors = {}
  local spacing = profile.lot_spacing
  for road_index, road in ipairs(roads) do
    local first, last = road.points[1], road.points[#road.points]
    local vx, vz = last.x - first.x, last.z - first.z
    local road_len = math.sqrt(vx * vx + vz * vz)
    if road_len >= 8 then
      local rdx, rdz = vx / road_len, vz / road_len
      local perp_x, perp_z = -rdz, rdx
      local label = "lots:road:" .. road_index
      local offset = spacing.set_back + math.floor(spacing.depth / 2)
      local along = spacing.min_gap
        + choice.range(seed_key, label .. ":start", 0, spacing.min_gap)
      local step_index = 0
      while along < road_len - spacing.min_gap do
        step_index = step_index + 1
        local sx = first.x + vx * (along / road_len)
        local sz = first.z + vz * (along / road_len)
        local first_side = choice.pick(seed_key, label .. ":side:" .. step_index, {1, -1})
        for _, side in ipairs({first_side, -first_side}) do
          local jitter = choice.int(seed_key, label .. ":jitter:" .. step_index .. ":" .. side, -1, 1)
          table.insert(anchors, {
            center = {
              x = math.floor(sx + perp_x * side * (offset + jitter) + 0.5),
              z = math.floor(sz + perp_z * side * (offset + jitter) + 0.5),
            },
            road_point = {x = math.floor(sx + 0.5), z = math.floor(sz + 0.5)},
            side = side,
            road_id = road.id,
            road_index = road_index,
          })
        end
        along = along + spacing.min_gap
          + choice.range(seed_key, label .. ":gap:" .. step_index, 0, spacing.max_gap - spacing.min_gap)
      end
    end
  end
  return anchors
end

--- Is the ground under this footprint usable?
--
-- The sampled area and the slope limit must match what
-- perfectworld.structures.analyze_terrain will demand at placement time,
-- otherwise the planner happily emits lots that the placer then rejects and
-- the settlement lands in "partial" for no good reason.
local function terrain_verdict(fp_min, fp_max, max_slope, terrain)
  local margin = 1
  local min_y, max_y = nil, nil
  local livable, total = 0, 0
  for x = fp_min.x - margin, fp_max.x + margin do
    for z = fp_min.z - margin, fp_max.z + margin do
      if terrain.is_liquid(x, z) then return false, "water" end
      local y = terrain.surface_y(x, z)
      if not y then return false, "no_surface" end
      min_y = min_y and math.min(min_y, y) or y
      max_y = max_y and math.max(max_y, y) or y
      total = total + 1
      if terrain.is_livable(x, z) then livable = livable + 1 end
    end
  end
  local slope = (max_y or 0) - (min_y or 0)
  if slope > max_slope then return false, "slope" end
  -- Barren ground: flat naked rock passes every geometric test and still
  -- makes a village that nobody could live in.
  if total > 0 and livable / total < 0.7 then return false, "barren" end
  return true, nil, min_y, slope
end

-- === Village Grammar: Full Plan Generation ===

local function rect_overlaps(a_min, a_max, b_min, b_max)
  return a_min.x <= b_max.x and a_max.x >= b_min.x
    and a_min.z <= b_max.z and a_max.z >= b_min.z
end

--- Canonical, order-independent description of the road graph.
--
-- Contract:
--   * coordinates are relative to the settlement centre, so absolute world
--     position never creates false uniqueness;
--   * a segment is undirected — writing it from either end yields the same
--     token (the lexicographically smaller endpoint is emitted first);
--   * segments are sorted, so Lua table order and the order in which
--     independent roads were generated do not matter;
--   * per-node degrees are appended, so two graphs over the same point set but
--     with different connections differ;
--   * every intermediate point is kept, so different bends differ.
--
-- Road ids, kinds and names are deliberately excluded: this is the geometry
-- and topology of the network, nothing else.
local function road_graph_signature(roads, center)
  local segments = {}
  local degree = {}

  local function node_key(pt)
    return (pt.x - center.x) .. "," .. (pt.z - center.z)
  end

  for _, road in ipairs(roads) do
    for i = 1, #road.points - 1 do
      local a, b = road.points[i], road.points[i + 1]
      local ka, kb = node_key(a), node_key(b)
      if ka ~= kb then
        local lo, hi = ka, kb
        if hi < lo then lo, hi = hi, lo end
        table.insert(segments, lo .. ">" .. hi .. "@" .. tostring(road.width or 2))
        degree[ka] = (degree[ka] or 0) + 1
        degree[kb] = (degree[kb] or 0) + 1
      end
    end
  end

  table.sort(segments)
  -- Deduplicate: a segment travelled twice is the same edge.
  local unique = {}
  for _, seg in ipairs(segments) do
    if unique[#unique] ~= seg then table.insert(unique, seg) end
  end

  local nodes = {}
  for key, deg in pairs(degree) do
    table.insert(nodes, key .. ":" .. deg)
  end
  table.sort(nodes)

  return "rg2|" .. table.concat(unique, ";") .. "||" .. table.concat(nodes, ";")
end

perfectworld.planner._road_graph_signature = road_graph_signature

local function required_counts_signature(requirements)
  local tokens = {}
  for _, role in ipairs(ordered_requirement_roles(requirements)) do
    tokens[#tokens + 1] =
      role .. "x" .. tostring(math.floor(tonumber(requirements[role]) or 0))
  end
  return table.concat(tokens, ",")
end

--- Exact plan signature: full normalised geometry, no quantisation.
local function exact_plan_signature(plan)
  local center = plan.center
  local parts = {
    "exact2",
    tostring(plan.settlement_grammar_version or SETTLEMENT_GRAMMAR_VERSION),
    tostring(plan.specialization or "?"),
    required_counts_signature(plan.required_role_counts),
    plan.archetype,
    tostring(plan.environment and plan.environment.biome_family),
    plan.size_class,
    plan.palette_id or "?",
    tostring(#plan.lots),
  }

  local lot_tokens = {}
  for _, lot in ipairs(plan.lots) do
    table.insert(lot_tokens, table.concat({
      lot.center.x - center.x,
      lot.center.z - center.z,
      lot.role,
      lot.structure_name,
      lot.rotation,
      lot.road_point.x - center.x,
      lot.road_point.z - center.z,
    }, ","))
  end
  table.sort(lot_tokens)
  table.insert(parts, table.concat(lot_tokens, ";"))

  local road_tokens = {}
  for _, road in ipairs(plan.roads) do
    local pts = {}
    for _, pt in ipairs(road.points) do
      table.insert(pts, (pt.x - center.x) .. "," .. (pt.z - center.z))
    end
    table.insert(road_tokens, road.kind .. "@" .. tostring(road.width) .. ":" .. table.concat(pts, " "))
  end
  table.sort(road_tokens)
  table.insert(parts, table.concat(road_tokens, ";"))

  table.insert(parts, plan.road_graph_signature or "")
  return table.concat(parts, "|")
end

--- Structural signature: quantised, for grouping visually similar layouts.
local function structural_plan_signature(plan)
  local center = plan.center
  local q = 4
  local function quant(v) return math.floor(v / q) end

  local role_counts = {}
  local structure_counts = {}
  local cells = {}
  for _, lot in ipairs(plan.lots) do
    role_counts[lot.role] = (role_counts[lot.role] or 0) + 1
    structure_counts[lot.structure_name] = (structure_counts[lot.structure_name] or 0) + 1
    table.insert(cells, quant(lot.center.x - center.x) .. "," .. quant(lot.center.z - center.z))
  end
  table.sort(cells)

  local roles = {}
  for role, count in pairs(role_counts) do
    table.insert(roles, role .. "x" .. count)
  end
  table.sort(roles)
  local structures_list = {}
  for name, count in pairs(structure_counts) do
    table.insert(structures_list, name .. "x" .. count)
  end
  table.sort(structures_list)

  local segment_count = 0
  for _, road in ipairs(plan.roads) do
    segment_count = segment_count + math.max(#road.points - 1, 0)
  end

  return table.concat({
    "struct2",
    tostring(plan.settlement_grammar_version or SETTLEMENT_GRAMMAR_VERSION),
    tostring(plan.specialization or "?"),
    required_counts_signature(plan.required_role_counts),
    plan.archetype,
    plan.size_class,
    plan.palette_id or "?",
    #plan.lots,
    #plan.roads,
    segment_count,
    table.concat(roles, ","),
    table.concat(structures_list, ","),
    table.concat(cells, ";"),
  }, "|")
end

perfectworld.planner._exact_plan_signature = exact_plan_signature
perfectworld.planner._structural_plan_signature = structural_plan_signature

--- Build (but do not materialize) a village plan.
function perfectworld.planner.build_village_plan(candidate, profile, environment, terrain)
  terrain = terrain or world_terrain
  local seed_key = profile.seed_key
  local center = {x = candidate.x, z = candidate.z}
  local rejections = {}

  local function reject(reason)
    rejections[reason] = (rejections[reason] or 0) + 1
  end

  local roads = build_road_network(seed_key, center, profile, terrain)
  local road_cells = road_cell_set(roads)

  -- Hillside settlements terrace into the slope, so they tolerate more relief
  -- than the flat archetypes. The override is applied at placement time too,
  -- so planning and placement agree on what counts as buildable.
  local hillside = profile.archetype == "hillside"
  local terrain_overrides = hillside
    and {max_slope = 6, max_cut_depth = 6, max_fill_height = 5, foundation_depth = 4}
    or nil

  local anchors = lot_anchors(seed_key, roads, profile)
  local lots = {}
  local role_index = 0

  --- Does this footprint (grown by one block) touch the road surface?
  local function touches_road(fp_min, fp_max)
    for x = fp_min.x - 1, fp_max.x + 1 do
      for z = fp_min.z - 1, fp_max.z + 1 do
        if road_cells[x .. ":" .. z] then return true end
      end
    end
    return false
  end

  for anchor_index, anchor in ipairs(anchors) do
    if #lots >= profile.target_lots then break end

    local role = profile.structure_roles[role_index + 1]
    if not role then break end
    local variants = profile.role_variants and profile.role_variants[role]
    local structure_name
    if type(variants) ~= "table" or #variants == 0 then
      reject("missing_role_variants")
    else
      structure_name = choice.pick(seed_key,
        "lot:" .. anchor_index .. ":" .. role .. ":variant", variants)
    end
    local def = structure_name and perfectworld.structures.get(structure_name)
    if structure_name and not def then
      reject("unknown_structure")
    elseif def then
      -- Setback is a property of the building, not a constant: a nine-block
      -- barn needs to stand further back from the kerb than a three-block
      -- well. Push the lot away from the road until its footprint clears the
      -- carriageway and every neighbour.
      local dir_x = anchor.center.x - anchor.road_point.x
      local dir_z = anchor.center.z - anchor.road_point.z
      local dir_len = math.sqrt(dir_x * dir_x + dir_z * dir_z)
      if dir_len < 0.5 then
        dir_x, dir_z, dir_len = 0, 1, 1
      end
      dir_x, dir_z = dir_x / dir_len, dir_z / dir_len

      local lot_max_slope = (terrain_overrides and terrain_overrides.max_slope)
        or (def.terrain and def.terrain.max_slope) or 2

      local placed = nil
      local last_reason = nil
      for extra = 0, 10 do
        local distance = dir_len + extra
        local cx = math.floor(anchor.road_point.x + dir_x * distance + 0.5)
        local cz = math.floor(anchor.road_point.z + dir_z * distance + 0.5)
        local origin = {x = cx, y = 0, z = cz}
        local rotation = orient_to_road(def, origin, anchor.road_point,
          seed_key, "lot:" .. anchor_index .. ":rotation")
        local fp_min, fp_max = perfectworld.structures.get_footprint(def, origin, rotation)

        local blocked = false
        local reason = nil
        -- Grow by one block: terrain preparation reaches modification_margin
        -- past the footprint, so two lots that merely touch would reshape each
        -- other's ground.
        local grown_min = {x = fp_min.x - 1, z = fp_min.z - 1}
        local grown_max = {x = fp_max.x + 1, z = fp_max.z + 1}
        for _, other in ipairs(lots) do
          if rect_overlaps(grown_min, grown_max, other.footprint_min, other.footprint_max) then
            blocked, reason = true, "lot_overlap"
            break
          end
        end
        if not blocked and touches_road(fp_min, fp_max) then
          blocked, reason = true, "road_conflict"
        end
        if not blocked then
          local building_min, building_max =
            perfectworld.structures.get_building_footprint(def, origin, rotation)
          local terrain_ok, terrain_reason =
            terrain_verdict(building_min, building_max, lot_max_slope, terrain)
          if not terrain_ok then
            blocked, reason = true, terrain_reason
          else
            -- The plot has to be reachable from its own street on foot.
            -- A stepped way can climb one block per cell and no more, so the
            -- approach has to be short enough for the height it has to gain.
            local road_y = terrain.surface_y(anchor.road_point.x, anchor.road_point.z)
            local lot_y = terrain.surface_y(cx, cz)
            if not road_y or not lot_y then
              blocked, reason = true, "no_surface"
            elseif math.abs(lot_y - road_y) > 6 then
              blocked, reason = true, "too_far_above_street"
            else
              -- Walk the approach line and check it can be terraced.
              local door = {x = cx, z = cz}
              for _, c in ipairs(def.connectors or {}) do
                if c.type == "road" and c.offset_pos then
                  local r = perfectworld.structures.rotate_point(c.offset_pos, rotation)
                  door = {x = cx + r.x, z = cz + r.z}
                  break
                end
              end
              local ddx = anchor.road_point.x - door.x
              local ddz = anchor.road_point.z - door.z
              local span = math.max(math.abs(ddx), math.abs(ddz), 1)
              local climb = math.abs(lot_y - road_y)
              if climb > span then
                blocked, reason = true, "approach_too_steep"
              else
                for step = 0, span do
                  local t = step / span
                  local px = math.floor(door.x + ddx * t + 0.5)
                  local pz = math.floor(door.z + ddz * t + 0.5)
                  if terrain.is_liquid(px, pz) then
                    blocked, reason = true, "approach_over_water"
                    break
                  end
                  if not terrain.surface_y(px, pz) then
                    blocked, reason = true, "no_surface"
                    break
                  end
                end
              end
            end
          end
        end

        if blocked then
          last_reason = reason
        else
          placed = {
            center = {x = cx, z = cz},
            rotation = rotation,
            footprint_min = fp_min,
            footprint_max = fp_max,
          }
          break
        end
      end

      if not placed then
        reject(last_reason or "no_placement")
      else
        role_index = role_index + 1
        table.insert(lots, {
          index = role_index,
          anchor_index = anchor_index,
          center = placed.center,
          road_point = anchor.road_point,
          road_id = anchor.road_id,
          side = anchor.side,
          role = role,
          structure_name = structure_name,
          rotation = placed.rotation,
          footprint_min = placed.footprint_min,
          footprint_max = placed.footprint_max,
        })
      end
    end
  end

  local bounds = {
    min_x = center.x, max_x = center.x,
    min_z = center.z, max_z = center.z,
  }
  local function extend(x, z)
    bounds.min_x = math.min(bounds.min_x, x)
    bounds.max_x = math.max(bounds.max_x, x)
    bounds.min_z = math.min(bounds.min_z, z)
    bounds.max_z = math.max(bounds.max_z, z)
  end
  for _, road in ipairs(roads) do
    for _, cell in ipairs(
      perfectworld.roads.rasterize(road.points or {}, road.width or 2)) do
      extend(cell.x, cell.z)
    end
  end
  for _, lot in ipairs(lots) do
    extend(lot.footprint_min.x, lot.footprint_min.z)
    extend(lot.footprint_max.x, lot.footprint_max.z)
  end
  for _, key in ipairs({"min_x", "min_z"}) do bounds[key] = bounds[key] - 2 end
  for _, key in ipairs({"max_x", "max_z"}) do bounds[key] = bounds[key] + 2 end

  local role_counts = {}
  for _, lot in ipairs(lots) do
    role_counts[lot.role] = (role_counts[lot.role] or 0) + 1
  end

  local missing_required = perfectworld.planner.missing_required_roles(
    role_counts, profile.required_role_counts)
  local plan = {
    village_id = profile.village_id,
    generator_version = profile.generator_version,
    settlement_grammar_version = profile.settlement_grammar_version,
    seed_key = seed_key,
    specialization = profile.specialization,
    specialization_score = profile.specialization_score,
    required_role_counts = deep_copy(profile.required_role_counts),
    required_worksite = profile.required_worksite,
    resource_features = deep_copy(profile.resource_features),
    archetype = profile.archetype,
    size_class = profile.size_class,
    environment = environment,
    material_palette = profile.material_palette,
    palette_id = profile.palette_id,
    terrain_overrides = terrain_overrides,
    center = center,
    bounds = bounds,
    roads = roads,
    lots = lots,
    structure_roles = profile.structure_roles,
    required_roles = profile.required_roles,
    optional_roles = profile.optional_roles,
    role_counts = role_counts,
    missing_required_roles = missing_required,
    rejections = rejections,
    viable = #lots > 0 and #missing_required == 0,
  }

  plan.road_graph_signature = road_graph_signature(roads, center)
  plan.road_graph_fingerprint = hash32(plan.road_graph_signature)
  plan.exact_plan_signature = exact_plan_signature(plan)
  plan.exact_plan_fingerprint = hash32(plan.exact_plan_signature)
  plan.structural_signature = structural_plan_signature(plan)
  plan.structural_fingerprint = hash32(plan.structural_signature)
  -- Backwards-compatible alias used by older records and debug commands.
  plan.fingerprint = plan.exact_plan_fingerprint

  return plan
end

--- Plan a village end to end: environment -> profile -> plan.
-- `env_override` (analysis only) forces environment fields such as
-- biome_family so palette branches the local map does not contain can still be
-- exercised. `terrain` (tests only) replaces the live-map sampler.
function perfectworld.planner.plan_village(candidate, env_override, terrain)
  terrain = terrain or world_terrain
  if terrain == world_terrain then
    world_terrain.reset()
    local center = {x = candidate.x, y = 0, z = candidate.z}
    if minetest.load_area then
      pcall(minetest.load_area,
        {x = center.x - 70, y = -32, z = center.z - 70},
        {x = center.x + 70, y = 200, z = center.z + 70})
    end
  end

  local function environment_at(site, column)
    local environment
    if terrain.kind == "synthetic" then
      environment = {
        biome_id = "synthetic",
        biome_name = "synthetic",
        biome_family = "temperate",
        heat = 50,
        humidity = 50,
        elevation = column and column.y or 0,
        roughness = 0,
        average_slope = 0,
        water_proximity = 999,
        vegetation_density = 0,
        available_material_profile = "temperate",
      }
    else
      environment = perfectworld.compat.get_environment({
        x = site.x,
        y = column and column.y or 0,
        z = site.z,
      })
    end
    if type(env_override) == "table" then
      for key, value in pairs(env_override) do environment[key] = value end
    end
    return environment
  end

  local selection, selection_error, ranked_selections =
    perfectworld.planner.ecology.select_site(candidate, terrain, environment_at)
  if not selection then
    local environment = environment_at(
      {x = candidate.x, z = candidate.z},
      terrain.sample_column(candidate.x, candidate.z))
    local profile = perfectworld.planner.create_village_profile(candidate, environment)
    profile.regional_anchor = {x = candidate.x, z = candidate.z}
    profile.selected_site = nil
    profile.ecology_error = selection_error
    local plan = {
      village_id = candidate.id,
      generator_version = profile.generator_version,
      settlement_grammar_version = SETTLEMENT_GRAMMAR_VERSION,
      seed_key = profile.seed_key,
      specialization = profile.specialization,
      specialization_score = profile.specialization_score,
      required_role_counts = deep_copy(profile.required_role_counts),
      required_worksite = profile.required_worksite,
      resource_features = deep_copy(profile.resource_features),
      archetype = profile.archetype,
      size_class = profile.size_class,
      environment = environment,
      material_palette = profile.material_palette,
      palette_id = profile.palette_id,
      center = {x = candidate.x, z = candidate.z},
      bounds = {
        min_x = candidate.x, max_x = candidate.x,
        min_z = candidate.z, max_z = candidate.z,
      },
      roads = {},
      lots = {},
      structure_roles = profile.structure_roles,
      required_roles = profile.required_roles,
      optional_roles = profile.optional_roles,
      role_counts = {},
      missing_required_roles = perfectworld.planner.missing_required_roles(
        {}, profile.required_role_counts),
      rejections = {[selection_error or "no_suitable_ecological_site"] = 1},
      viable = false,
      regional_anchor = {x = candidate.x, z = candidate.z},
      ecology_error = selection_error,
    }
    plan.road_graph_signature = road_graph_signature(plan.roads, plan.center)
    plan.road_graph_fingerprint = hash32(plan.road_graph_signature)
    plan.exact_plan_signature = exact_plan_signature(plan)
    plan.exact_plan_fingerprint = hash32(plan.exact_plan_signature)
    plan.structural_signature = structural_plan_signature(plan)
    plan.structural_fingerprint = hash32(plan.structural_signature)
    plan.fingerprint = plan.exact_plan_fingerprint
    return plan, profile, environment
  end

  local function plan_selection(current)
    local selected_candidate = perfectworld.core.deep_copy(candidate)
    selected_candidate.x = current.site.x
    selected_candidate.z = current.site.z
    local environment = perfectworld.core.deep_copy(current.environment)
    local ecology_record = perfectworld.core.deep_copy(current.evidence)
    ecology_record.specialization_scores =
      perfectworld.core.deep_copy(current.specialization_scores)
    environment.elevation = current.evidence.elevation
    environment.roughness = current.evidence.roughness
    environment.average_slope = current.evidence.average_slope
    environment.water_proximity = current.evidence.shore_distance or 999
    environment.vegetation_density =
      math.floor((current.evidence.tree_ratio or 0) * 100 + 0.5)
    environment.available_material_profile = environment.biome_family or "temperate"
    environment.specialization = current.specialization
    environment.specialization_score = current.specialization_score
    environment.ecology = ecology_record

    local profile = perfectworld.planner.create_village_profile(
      selected_candidate, environment)
    profile.regional_anchor = {x = candidate.x, z = candidate.z}
    profile.selected_site = {
      x = current.site.x,
      y = terrain.surface_y(current.site.x, current.site.z) or 0,
      z = current.site.z,
    }
    profile.specialization = current.specialization
    profile.specialization_score = current.specialization_score
    profile.specialization_definition =
      perfectworld.core.deep_copy(current.definition)
    profile.ecology = ecology_record

    local function annotate(plan)
      plan.settlement_grammar_version = SETTLEMENT_GRAMMAR_VERSION
      plan.regional_anchor = perfectworld.core.deep_copy(profile.regional_anchor)
      plan.selected_site = perfectworld.core.deep_copy(profile.selected_site)
      plan.specialization = profile.specialization
      plan.specialization_score = profile.specialization_score
      plan.ecology = perfectworld.core.deep_copy(profile.ecology)
      return plan
    end

    local plan = annotate(perfectworld.planner.build_village_plan(
      selected_candidate, profile, environment, terrain))

    -- The archetype is chosen before lots meet the exact terrain. Preserve the
    -- documented hillside retry for each bounded ecological site.
    if not plan.viable
      and profile.archetype ~= "hillside"
      and (plan.rejections.no_surface or 0) == 0 then
      local fallback = perfectworld.core.deep_copy(profile)
      fallback.archetype = "hillside"
      fallback.archetype_fallback_from = profile.archetype
      local retry = perfectworld.planner.build_village_plan(
        selected_candidate, fallback, environment, terrain)
      if retry.viable then
        retry.archetype_fallback_from = profile.archetype
        profile = fallback
        plan = annotate(retry)
      end
    end

    return plan, profile, environment
  end

  local first_plan, first_profile, first_environment
  for _, current in ipairs(ranked_selections or {selection}) do
    local plan, profile, environment = plan_selection(current)
    if not first_plan then
      first_plan, first_profile, first_environment = plan, profile, environment
    end
    if plan.viable then return plan, profile, environment end
  end

  return first_plan, first_profile, first_environment
end

--- Emerge (generate if needed) the map area a settlement plan will inspect.
--
-- `minetest.load_area` only loads already-generated blocks, so a settlement
-- planned near the edge of the generated world would see no terrain at all.
--
-- The area is emerged in tiles rather than in one request. A town needs a far
-- wider area than a village, and one request for it would ask for more
-- mapblocks than the emerge queue accepts — the surplus is dropped silently,
-- the final callback never fires, and the caller waits forever. That failure
-- mode is invisible and was worth designing out rather than tuning around: the
-- tiles are small enough that no configuration of the queue can refuse one.
local EMERGE_TILE = 48

function perfectworld.planner.emerge_settlement_area(candidate, radius, callback)
  if not minetest.emerge_area then
    callback()
    return
  end
  radius = math.max(math.floor(tonumber(radius) or 64), 16)

  -- get_spawn_level is noise-based, so the surface height is known before
  -- anything is generated.
  local surface = (minetest.get_spawn_level
    and minetest.get_spawn_level(candidate.x, candidate.z)) or 32
  local low_y, high_y = surface - 24, surface + 32

  -- The tiles, nearest to the centre first: if the watchdog fires the ground
  -- that matters most is the ground already there.
  local tiles = {}
  local step = EMERGE_TILE * 2
  for x = -radius, radius, step do
    for z = -radius, radius, step do
      tiles[#tiles + 1] = {x = x, z = z}
    end
  end
  table.sort(tiles, function(a, b)
    return a.x * a.x + a.z * a.z < b.x * b.x + b.z * b.z
  end)

  local done = false
  local function finish()
    if done then return end
    done = true
    callback()
  end

  local index = 0
  local function next_tile()
    if done then return end
    index = index + 1
    local tile = tiles[index]
    if not tile then
      finish()
      return
    end
    local minp = {
      x = candidate.x + tile.x, y = low_y,
      z = candidate.z + tile.z,
    }
    local maxp = {
      x = math.min(candidate.x + tile.x + step - 1, candidate.x + radius), y = high_y,
      z = math.min(candidate.z + tile.z + step - 1, candidate.z + radius),
    }
    minetest.emerge_area(minp, maxp, function(_, _, calls_remaining)
      if calls_remaining == 0 then next_tile() end
    end)
  end
  next_tile()

  -- Watchdog: a stalled emerge must not stall the whole run. It scales with the
  -- work asked for, because a town is a great deal more ground than a village
  -- and a fixed timeout would cut every town short.
  minetest.after(20 + #tiles * 8, function()
    if not done then
      minetest.log("warning", "[pw_planner] emerge timed out for "
        .. tostring(candidate.id or "site") .. " after " .. index .. " of "
        .. #tiles .. " tiles, continuing with what is loaded")
      finish()
    end
  end)
end

--- How much ground a settlement of this kind needs generated around it.
--
-- The survey reaches `SITE_RADIUS + SURVEY_RADIUS` from the candidate, and the
-- streets reach half their length plus the depth of a lot. Getting this wrong
-- is not a crash: the plan is simply made against terrain that does not exist,
-- every probe returns no surface, and the settlement is recorded as unbuildable
-- ground it never saw.
function perfectworld.planner.emerge_radius_for(candidate)
  local kind = candidate and candidate.type or "village"
  if kind == "town" or kind == "city" then return 128 end
  return 64
end

--- Backwards-compatible entry point: a village, at the village radius.
function perfectworld.planner.emerge_village_area(candidate, callback)
  perfectworld.planner.emerge_settlement_area(candidate,
    perfectworld.planner.emerge_radius_for(candidate), callback)
end

-- === Diversity Analysis ===
--
-- Builds a deterministic sample of planning inputs, generates a full plan for
-- each one, and returns a flat row per input. Nothing is written to the world.
--
-- Two modes:
--   "synthetic" - terrain comes from make_synthetic_terrain, so the sample can
--                 cover slopes, water and relief that the local map may not
--                 contain, and runs without waiting for map generation;
--   "world"     - terrain comes from the live map, which requires the area to
--                 be emerged first (see emerge_village_area).

--- Terrain archetypes used by the synthetic sample.
perfectworld.planner.TERRAIN_SPECS = {
  {name = "flat_lowland", base = 12, slope_x = 0, slope_z = 0, relief = 0},
  {name = "flat_upland", base = 96, slope_x = 0, slope_z = 0, relief = 0},
  {name = "gentle_slope", base = 40, slope_x = 0.10, slope_z = 0.03, relief = 0},
  {name = "steep_slope", base = 60, slope_x = 0.38, slope_z = -0.12, relief = 1, relief_scale = 32},
  {name = "rolling", base = 48, slope_x = 0.02, slope_z = 0.02, relief = 4, relief_scale = 40},
  {name = "rough", base = 70, slope_x = 0.05, slope_z = -0.05, relief = 9, relief_scale = 22},
  {name = "shoreline", base = 6, slope_x = 0.06, slope_z = 0, relief = 2, relief_scale = 30,
   water_line = 3},
  {name = "submerged", base = 1, slope_x = 0, slope_z = 0, relief = 0, water_line = 8},
  {name = "cliff", base = 50, slope_x = 0.9, slope_z = 0, relief = 3, relief_scale = 16},
}

--- Deterministic analysis sample.
function perfectworld.planner.build_analysis_sample(opts)
  opts = opts or {}
  local mode = opts.mode or "synthetic"
  local target = opts.count or 120
  local step = opts.spacing or 1024
  local families = perfectworld.compat.list_families()
  local world_seeds = opts.world_seeds or {
    perfectworld.world_seed_string, "1", "424242", "9007199254740993",
  }
  local inputs = {}
  local index = 0

  local grid = {}
  for rx = -4, 4 do
    for rz = -4, 4 do table.insert(grid, {rx = rx, rz = rz}) end
  end
  table.sort(grid, function(a, b)
    local da, db = a.rx * a.rx + a.rz * a.rz, b.rx * b.rx + b.rz * b.rz
    if da ~= db then return da < db end
    if a.rx ~= b.rx then return a.rx < b.rx end
    return a.rz < b.rz
  end)

  if mode == "synthetic" then
    -- family x terrain x world seed, walked so that the first N inputs already
    -- cover every family and every terrain archetype.
    local specs = perfectworld.planner.TERRAIN_SPECS
    local combos = math.max(#families, #specs, #world_seeds)
    local i = 0
    while #inputs < target do
      i = i + 1
      if i > combos * combos * #world_seeds then break end
      local family = families[1 + (i - 1) % #families]
      local spec = specs[1 + math.floor((i - 1) / #families) % #specs]
      local seed = world_seeds[1 + math.floor((i - 1) / (#families * #specs)) % #world_seeds]
      local cell = grid[1 + (i - 1) % #grid]
      index = index + 1
      table.insert(inputs, {
        input_id = string.format("syn_%03d", index),
        rx = cell.rx, rz = cell.rz,
        x = cell.rx * step + 137 * i % step,
        z = cell.rz * step - 211 * i % step,
        world_seed = seed,
        terrain_source = "synthetic:" .. spec.name,
        terrain_spec = spec,
        env_override = {
          biome_family = family,
          biome_name = "synthetic:" .. family,
          roughness = spec.relief + math.floor(math.abs(spec.slope_x) * 20),
          average_slope = spec.relief + math.floor(math.abs(spec.slope_x) * 20),
          water_proximity = spec.water_line and 6 or 400,
          elevation = spec.base,
        },
        note = family .. "/" .. spec.name,
      })
    end

    -- Fallback biome: an unknown biome name must resolve to the temperate palette.
    index = index + 1
    table.insert(inputs, {
      input_id = string.format("syn_%03d", index),
      rx = 0, rz = 0, x = 700, z = -700,
      world_seed = perfectworld.world_seed_string,
      terrain_source = "synthetic:flat_lowland",
      terrain_spec = perfectworld.planner.TERRAIN_SPECS[1],
      env_override = {
        biome_name = "mcl_biomes:nonexistent_xyz",
        biome_family = perfectworld.compat.get_biome_family("mcl_biomes:nonexistent_xyz"),
      },
      note = "fallback_biome",
    })
    return inputs
  end

  -- World mode: real map terrain, spread over regions; the tail forces every
  -- biome family so all palette branches are covered even where the local map
  -- has no such biome.
  local offsets = {
    {dx = 0, dz = 0}, {dx = 320, dz = -260}, {dx = -280, dz = 300},
    {dx = 180, dz = 420}, {dx = -400, dz = -180},
  }
  local forced_count = math.min(#families * 2, math.floor(target * 0.25))

  for _, cell in ipairs(grid) do
    for _, offset in ipairs(offsets) do
      for _, seed in ipairs(world_seeds) do
        if #inputs >= target - forced_count then break end
        index = index + 1
        table.insert(inputs, {
          input_id = string.format("world_%03d", index),
          rx = cell.rx, rz = cell.rz,
          x = cell.rx * step + math.floor(step / 2) + offset.dx,
          z = cell.rz * step + math.floor(step / 2) + offset.dz,
          world_seed = seed,
          terrain_source = "world",
        })
      end
      if #inputs >= target - forced_count then break end
    end
    if #inputs >= target - forced_count then break end
  end

  local forced = 0
  for _, family in ipairs(families) do
    for variant = 1, 2 do
      if #inputs >= target then break end
      forced = forced + 1
      index = index + 1
      local cell = grid[1 + (forced % #grid)]
      table.insert(inputs, {
        input_id = string.format("world_%03d", index),
        rx = cell.rx, rz = cell.rz,
        x = cell.rx * step + math.floor(step / 2) + 150 * variant,
        z = cell.rz * step + math.floor(step / 2) - 170 * variant,
        world_seed = perfectworld.world_seed_string,
        terrain_source = "world+forced_env",
        env_override = {biome_family = family, biome_name = "forced:" .. family},
        note = "forced_family:" .. family,
      })
    end
  end

  return inputs
end

--- Plan one analysis input and return a flat result row.
function perfectworld.planner.analyze_input(input)
  local candidate = {
    id = "analysis_" .. input.input_id .. "_" .. perfectworld.core.coord_tag(input.rx)
      .. "_" .. perfectworld.core.coord_tag(input.rz),
    x = input.x,
    z = input.z,
    rx = input.rx,
    rz = input.rz,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    world_seed_override = input.world_seed,
    region_id = perfectworld.get_region_id(input.rx, input.rz),
  }

  local terrain
  if input.terrain_spec then
    local spec = {}
    for key, value in pairs(input.terrain_spec) do spec[key] = value end
    spec.seed_key = "terrain|" .. input.input_id
    terrain = perfectworld.planner.make_synthetic_terrain(spec)
  end

  local ok, plan, profile, environment = pcall(
    perfectworld.planner.plan_village, candidate, input.env_override, terrain)
  if not ok then
    return {
      input_id = input.input_id,
      status = "error",
      error = tostring(plan):sub(1, 200),
      terrain_source = input.terrain_source,
      note = input.note,
    }
  end

  local role_key, structure_key = {}, {}
  for _, lot in ipairs(plan.lots) do
    table.insert(role_key, lot.role)
    table.insert(structure_key, lot.structure_name)
  end
  table.sort(role_key)
  table.sort(structure_key)

  local status
  if #plan.lots == 0 then
    status = "empty"
  elseif not plan.viable then
    status = "rejected"
  else
    status = "valid"
  end

  local rejections = {}
  for reason, count in pairs(plan.rejections) do
    table.insert(rejections, reason .. "=" .. count)
  end
  table.sort(rejections)

  return {
    input_id = input.input_id,
    candidate_id = candidate.id,
    status = status,
    terrain_source = input.terrain_source,
    note = input.note,
    world_seed = input.world_seed,
    rx = input.rx, rz = input.rz, x = input.x, z = input.z,
    biome_name = environment.biome_name,
    biome_family = environment.biome_family,
    elevation = environment.elevation,
    roughness = environment.roughness,
    water_proximity = environment.water_proximity,
    vegetation_density = environment.vegetation_density,
    archetype = plan.archetype,
    size_class = plan.size_class,
    palette = plan.palette_id,
    target_lots = profile.target_lots,
    lot_count = #plan.lots,
    road_count = #plan.roads,
    exact_plan_fingerprint = plan.exact_plan_fingerprint,
    structural_fingerprint = plan.structural_fingerprint,
    road_graph_fingerprint = plan.road_graph_fingerprint,
    lot_layout_key = plan.structural_signature,
    role_composition = table.concat(role_key, ","),
    structure_composition = table.concat(structure_key, ","),
    rejections = table.concat(rejections, " "),
    seed_key = profile.seed_key,
  }
end
-- === Village Materialization ===

--- Ground level of a column, ignoring the loose cover that sits on top of it.
--
-- Snow layers, grass and flowers are all "the surface" as far as a downward
-- scan is concerned. Paving at that level leaves the path standing a block
-- proud of the ground it is supposed to be part of.
local function paving_level(x, z, hint_y)
  local y
  if hint_y then
    -- Scan from a known reference instead of from the sky: a roof eave or a
    -- tree above the column would otherwise be mistaken for the ground.
    for probe = hint_y + 2, hint_y - 6, -1 do
      local name = minetest.get_node({x = x, y = probe, z = z}).name
      local class = perfectworld.compat.classify_node(name)
      if name ~= "air" and name ~= "ignore" and not class.vegetation then
        y = probe
        break
      end
    end
  end
  y = y or world_terrain.surface_y(x, z)
  if not y then return nil end
  for depth = 0, 3 do
    local name = minetest.get_node({x = x, y = y - depth, z = z}).name
    local def = minetest.registered_nodes[name]
    local groups = (def and def.groups) or {}
    local class = perfectworld.compat.classify_node(name)
    local loose = groups.snow_cover or groups.flora or groups.plant
      or groups.flower or class.vegetation or (def and def.buildable_to)
      or name:find("^mcl_core:snow") or name:find("^mcl_flowers:")
    if not loose then
      return y - depth
    end
  end
  return y
end

--- Pave one column flush with the ground and clear what stands on it.
local function pave_cell(x, z, material_name)
  local y = paving_level(x, z)
  if not y then return false end
  local existing = minetest.get_node({x = x, y = y, z = z}).name
  if perfectworld.compat.is_liquid_node(existing) then return false end
  if existing ~= material_name then
    minetest.set_node({x = x, y = y, z = z}, {name = material_name})
  end
  -- Head-room: a path you cannot walk down is not a path.
  for above = 1, 2 do
    local pos = {x = x, y = y + above, z = z}
    local name = minetest.get_node(pos).name
    if name ~= "air" and name ~= "ignore" then
      local def = minetest.registered_nodes[name]
      local groups = (def and def.groups) or {}
      if (def and def.buildable_to) or groups.snow_cover or groups.flora
        or groups.plant or groups.flower or name:find("^mcl_core:snow") then
        minetest.set_node(pos, {name = "air"})
      end
    end
  end
  return true
end


--- The greatest rise between one node of road and the next.
--
-- One, because that is what a walker can step up. Everything about the height
-- profile below exists to hold this, which is the difference between a road
-- and a line of blocks laid on a hillside.
local LINK_GRADE = 1

--- How far past the chunk a stretch is paved, so neighbouring passes overlap
--- instead of meeting at a seam neither of them smoothed.
local LINK_SEAM_OVERLAP = 8

--- The widest water a road will cross. Beyond this it is not a bridge, it is a
--- causeway across a sea, and the road simply stops at the shore.
local BRIDGE_MAX_SPAN = 48

--- The deepest a road will bore under the ground it is crossing.
--
-- A tunnel through a hill is a tunnel. A bore two hundred nodes under a
-- mountain, which is what an unbounded profile produces on a coast, is a mine.
local MAX_TUNNEL_DEPTH = 24

--- How deep a cutting may go before the road should be doing something else.
--
-- Four. A road in a hollow four deep is a hollow way, which is what old roads
-- become. Deeper than that and it is a trench with a road at the bottom — the
-- ground opened with a sword — which is what this project built until the
-- head-room clearing was bounded.
local MAX_CUT = 4

--- How high an embankment may go before the road should be a bridge instead.
local MAX_FILL = 3

--- How far a road may be nudged sideways from the line that was planned for it.
--
-- Eighty. Ten was less than the width of a hill and forty was less than the
-- width of a ridge: measured on a fresh carpathian world with forty nodes of
-- room, one road ran 320 of its 997 nodes underground. A road that bends a
-- hundred nodes over half a mile to reach a pass is what a road looks like; a
-- road that holds its line and tunnels is what a machine does, because a
-- machine finds tunnelling cheap and people do not.
local LATERAL_MAX = 80

--- How fast it may be nudged: one node of sideways for every four forward,
--- which is about fourteen degrees. A road that swerves faster than that reads
--- as a mistake rather than as a road going round something.
local LATERAL_EVERY = 4

--- The centreline of a way, one cell per node travelled.
--
-- Takes anything with a `points` polyline: a village street and a road between
-- two settlements are the same object as far as the ground is concerned.
local function link_centreline(way)
  local cells = {}
  local last_key = nil
  local points = way.points or way.path or {}
  for i = 1, #points - 1 do
    local from, to = points[i], points[i + 1]
    local dx, dz = to.x - from.x, to.z - from.z
    local steps = math.max(math.abs(dx), math.abs(dz), 1)
    for s = 0, steps do
      local t = s / steps
      local x = math.floor(from.x + dx * t + 0.5)
      local z = math.floor(from.z + dz * t + 0.5)
      local key = x .. ":" .. z
      if key ~= last_key then
        cells[#cells + 1] = {x = x, z = z}
        last_key = key
      end
    end
  end
  return cells
end


--- Flatten a run of ground heights into a profile a walker can follow.
--
-- The rule is one-sided: a road may be cut into a hill, never raised above it.
-- Raising would leave the carriageway floating over the slope it is supposed to
-- be part of, and every attempt to fill underneath turns a hillside into a
-- viaduct. Cutting leaves a hollow way, which is what old roads actually are.
--
-- Two passes are enough and are exact. `min(raw[j] + |i - j|)` over every j is
-- the lowest profile that both stays under the ground and never rises faster
-- than the grade, and a forward min-pass followed by a backward one computes
-- precisely that.
local function walkable_profile(raw, first, last, grade)
  grade = grade or LINK_GRADE

  -- The lowest grade-limited profile that stays under the ground:
  -- `min(raw[j] + |i - j|)` over every j, computed exactly by a forward
  -- min-pass and a backward one.
  local y = {}
  for i = first, last do y[i] = raw[i] end
  for i = first + 1, last do
    if y[i] and y[i - 1] and y[i] > y[i - 1] + grade then y[i] = y[i - 1] + grade end
  end
  for i = last - 1, first, -1 do
    if y[i] and y[i + 1] and y[i] > y[i + 1] + grade then y[i] = y[i + 1] + grade end
  end

  -- ...and then lifted out of the abyss.
  --
  -- The rule above takes the road down to the lowest ground within reach, which
  -- on a coast with a mountain behind it means sea level — and then bores
  -- through the mountain at that level. Measured on a real link: a cut 191 deep.
  -- A road does not tunnel two hundred nodes under a hill; it climbs it.
  --
  -- So a floor: never more than `MAX_TUNNEL_DEPTH` below the ground. Propagated
  -- with the mirror of the same transform — `max(floor[j] - |i - j|)` — because
  -- a pointwise floor is not grade-limited and would put a step in the road
  -- where it bites. The pointwise maximum of two grade-limited profiles is
  -- itself grade-limited, so the result still steps by one and no more.
  local lower = {}
  for i = first, last do
    lower[i] = raw[i] and (raw[i] - MAX_TUNNEL_DEPTH) or nil
  end
  for i = first + 1, last do
    if lower[i] and lower[i - 1] and lower[i] < lower[i - 1] - grade then
      lower[i] = lower[i - 1] - grade
    end
  end
  for i = last - 1, first, -1 do
    if lower[i] and lower[i + 1] and lower[i] < lower[i + 1] - grade then
      lower[i] = lower[i + 1] - grade
    end
  end
  for i = first, last do
    if y[i] and lower[i] and lower[i] > y[i] then y[i] = lower[i] end
  end

  return y
end

perfectworld.planner._walkable_profile = walkable_profile

--- Which cells sit on water, and whether that water is narrow enough to bridge.
local function bridgeable(water, first, last)
  local ok = {}
  local run_start = nil
  for i = first, last + 1 do
    if water[i] and i <= last then
      run_start = run_start or i
    elseif run_start then
      local span = i - run_start
      for j = run_start, i - 1 do ok[j] = span <= BRIDGE_MAX_SPAN end
      run_start = nil
    end
  end
  return ok
end

perfectworld.planner._bridgeable = bridgeable

--- Where a road meets water it cannot cross, it ends in a landing.
--
-- A road that simply stops at the waterline reads as a road that ran out of
-- budget. A road that ends in a quay reads as a road that arrived: this is
-- where you get in a boat, and the boat is there.
--
-- Not a port town. A settlement is a thing the region planner decides on
-- measured ground, and inventing one wherever a road happens to reach the sea
-- would put towns in places nothing chose. This is the landing stage; the town
-- that should stand behind it is not built.
local function build_landing(cell, level, ahead, palette)
  local plank = perfectworld.structures.palette_material(palette, "floor_block", "wood_planks")
  local post = perfectworld.structures.palette_material(palette, "wall_post", "tree")
  local stone = perfectworld.structures.palette_material(palette, "foundation", "foundation")
  local lamp = perfectworld.compat.get_material("lantern", {required = false})
  if not plank or plank == "air" then return 0 end

  -- Which way the water is: the direction the road was going when it stopped.
  local dx = (ahead and ahead.x or cell.x) - cell.x
  local dz = (ahead and ahead.z or cell.z) - cell.z
  local length = math.sqrt(dx * dx + dz * dz)
  if length < 0.001 then dx, dz, length = 0, 1, 1 end
  dx, dz = dx / length, dz / length
  local px, pz = -dz, dx

  local placed = 0
  local function put(x, y, z, node)
    if not node or node == "air" then return end
    local existing = minetest.get_node({x = x, y = y, z = z}).name
    if existing == "ignore" then return end
    minetest.set_node({x = x, y = y, z = z}, {name = node})
    placed = placed + 1
  end

  -- A stone apron on the land side, so the quay is founded rather than perched.
  for back = 0, 1 do
    for side = -1, 1 do
      local x = math.floor(cell.x - dx * back + px * side + 0.5)
      local z = math.floor(cell.z - dz * back + pz * side + 0.5)
      put(x, level, z, stone)
    end
  end

  -- The deck, out over the water, with mooring posts at its head.
  local head_x, head_z = cell.x, cell.z
  for out = 1, 5 do
    local x = math.floor(cell.x + dx * out + 0.5)
    local z = math.floor(cell.z + dz * out + 0.5)
    for side = -1, 1 do
      local sx = math.floor(x + px * side + 0.5)
      local sz = math.floor(z + pz * side + 0.5)
      local under = minetest.get_node({x = sx, y = level - 1, z = sz}).name
      -- Piles under the deck, so it stands on something.
      if perfectworld.compat.is_liquid_node(under) then
        for py = level - 1, level - 6, -1 do
          local name = minetest.get_node({x = sx, y = py, z = sz}).name
          if perfectworld.compat.is_liquid_node(name) then
            if side == 0 and out % 2 == 1 then put(sx, py, sz, post) end
          else
            break
          end
        end
      end
      put(sx, level, sz, plank)
    end
    head_x, head_z = x, z
  end

  for side = -1, 1, 2 do
    local sx = math.floor(head_x + px * side + 0.5)
    local sz = math.floor(head_z + pz * side + 0.5)
    put(sx, level + 1, sz, post)
    put(sx, level + 2, sz, side == 1 and lamp or post)
  end

  -- And a boat at the end of it, which is the whole point of a landing.
  local boat_x = head_x + dx * 1.5
  local boat_z = head_z + dz * 1.5
  if minetest.registered_entities["mcl_boats:boat"] then
    local water = minetest.get_node(
      {x = math.floor(boat_x + 0.5), y = level, z = math.floor(boat_z + 0.5)}).name
    if perfectworld.compat.is_liquid_node(water) then
      minetest.add_entity({x = boat_x, y = level + 0.5, z = boat_z}, "mcl_boats:boat")
    end
  end

  return placed
end

perfectworld.planner._build_landing = build_landing

--- Decide where a way actually goes, and what it does where the ground is
--- against it.
--
-- The planned polyline is a wish. This is where it meets the hill.
--
-- Three answers, in order of preference, which is the order a road builder
-- would take them in:
--
--   go round     The line is nudged sideways, at most one node for every four
--                forward — about fourteen degrees — and at most ten nodes from
--                where it was planned. A hill with a flank is gone round,
--                because that is cheaper than anything else and it is what
--                every road that was walked before it was surveyed does.
--
--   go through   Where there is no flank within reach, the road holds its level
--                and bores. The head-room clearing in `pave_way` is bounded to
--                three, so what comes out is a tunnel: the hill above the road
--                is untouched. This is the case that used to produce a canyon.
--
--   go over      Where the ground falls away instead, the road holds its level
--                and is decked, on piers. Water was already handled this way;
--                a dry gorge is the same problem and gets the same answer.
--
-- The sideways choice is made on blocks of four cells rather than per cell, and
-- adjacent blocks may differ by one, which is what enforces the fourteen
-- degrees without a second smoothing pass.
function perfectworld.planner.route_way(cells, first, last, raw_in, water, deviate)
  local count = last - first + 1
  local mode, out_cells = {}, {}

  -- A village street may not move. Its lots were planned against the line it
  -- was drawn on, its doors face it, and its driveways run to it; nudging it
  -- aside to avoid a rise would leave a street of houses facing nothing. Only
  -- the roads between settlements are free to choose their own way.
  --
  -- Straight down the planned line there is nothing to decide, and a stretch of
  -- one or two cells has no direction and no flank either.
  if deviate == false or count < 3 then
    local y = walkable_profile(raw_in, first, last)
    for i = first, last do
      out_cells[i] = cells[i]
      mode[i] = water[i] and "bridge" or "ground"
    end
    return {cells = out_cells, raw = raw_in, y = y, mode = mode}
  end

  --- The direction across the way at each cell, from its neighbours.
  local function perpendicular(i)
    local ahead = cells[math.min(i + 1, last)]
    local behind = cells[math.max(i - 1, first)]
    local dx, dz = ahead.x - behind.x, ahead.z - behind.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.001 then return 0, 1 end
    return -dz / length, dx / length
  end

  local function shifted(i, offset)
    local px, pz = perpendicular(i)
    return {
      x = math.floor(cells[i].x + px * offset + 0.5),
      z = math.floor(cells[i].z + pz * offset + 0.5),
    }
  end

  -- What height this road is trying to hold.
  --
  -- A road runs between two places, and the level it wants is the level of the
  -- ground between them — not the lowest ground it can find. Scoring by "lowest
  -- wins" sends a road down every valley it passes and, on a hill, straight
  -- through; scoring by "closest to the line between the ends" makes it keep to
  -- the contour and go round, which is what a road walked before it was
  -- surveyed actually does.
  local start_ground = paving_level(cells[first].x, cells[first].z)
  local end_ground = paving_level(cells[last].x, cells[last].z)
  local function reference_at(i)
    if not start_ground or not end_ground then return nil end
    local t = (i - first) / math.max(last - first, 1)
    return start_ground + (end_ground - start_ground) * t
  end

  -- Score each sideways offset over a block of cells by how far the ground
  -- under it departs from the height the road is holding, and how broken it is.
  local blocks = math.ceil(count / LATERAL_EVERY)
  local chosen = {}
  for block = 0, blocks - 1 do
    local block_first = first + block * LATERAL_EVERY
    local block_last = math.min(block_first + LATERAL_EVERY - 1, last)
    local best_offset, best_score = 0, nil
    for offset = -LATERAL_MAX, LATERAL_MAX, 2 do
      local total, samples, roughest, wet = 0, 0, 0, 0
      local highest = nil
      local previous = nil
      for i = block_first, block_last do
        local at = shifted(i, offset)
        local column = world_terrain.sample_column(at.x, at.z)
        if column and column.liquid then
          wet = wet + 1
        end
        local ground = paving_level(at.x, at.z)
        if ground then
          total = total + ground
          samples = samples + 1
          if not highest or ground > highest then highest = ground end
          if previous then
            local step = math.abs(ground - previous)
            if step > roughest then roughest = step end
          end
          previous = ground
        end
      end
      if samples > 0 then
        local mean = total / samples
        local reference = reference_at(math.floor((block_first + block_last) / 2))
        -- Departure from the height the road is holding, then roughness, then a
        -- small pull back towards the planned line so it does not wander for a
        -- one-node saving.
        --
        -- Climbing is charged for, and charged more the higher it goes: two
        -- nodes up is nothing, twenty is a haul. Squaring it is what makes the
        -- road prefer a long way round a hill to a short way over it, which is
        -- the whole difference between a road and a bulldozed line.
        --
        -- Water is scored out of reach rather than merely disliked. Preferring
        -- low ground is right on a hill and catastrophic on a coast, where the
        -- lowest ground for miles is the sea bed.
        -- The *highest* ground in the block, not the mean.
        --
        -- A road crossing a range crosses it at the col, and a col is where the
        -- highest ground along the way is lowest. Scoring the mean lets a block
        -- with a low valley and a high wall beat a block that is level all the
        -- way across, which is how a road ends up aimed at a wall. Scoring the
        -- maximum is what finds the pass.
        local barrier = reference and math.max(highest - reference, 0) or 0
        local departure = reference and math.abs(mean - reference) or 0
        local score = barrier + barrier * barrier * 0.12
          + departure * 0.5
          + roughest * 2 + math.abs(offset) * 0.25 + wet * 60
        if not best_score or score < best_score then
          best_score, best_offset = score, offset
        end
      end
    end
    chosen[block] = best_offset
  end

  -- No block may differ from its neighbour by more than one node of offset.
  -- Forward then backward, the same clamp the height profile uses.
  for block = 1, blocks - 1 do
    local limit = chosen[block - 1]
    if chosen[block] > limit + 1 then chosen[block] = limit + 1 end
    if chosen[block] < limit - 1 then chosen[block] = limit - 1 end
  end
  for block = blocks - 2, 0, -1 do
    local limit = chosen[block + 1]
    if chosen[block] > limit + 1 then chosen[block] = limit + 1 end
    if chosen[block] < limit - 1 then chosen[block] = limit - 1 end
  end

  -- The route, and the ground under it.
  local raw = {}
  for i = first, last do
    local block = math.floor((i - first) / LATERAL_EVERY)
    local offset = chosen[block] or 0
    -- The ends stay where they were planned: a road that arrives at a village
    -- ten nodes to one side of its own gate has not arrived.
    local from_end = math.min(i - first, last - i)
    if from_end < LATERAL_EVERY * 2 then
      offset = math.floor(offset * from_end / (LATERAL_EVERY * 2) + 0.5)
    end
    local at = offset == 0 and cells[i] or shifted(i, offset)
    out_cells[i] = at
    if water[i] then
      raw[i] = raw_in[i]
    else
      raw[i] = paving_level(at.x, at.z) or raw_in[i]
    end
  end

  local y = walkable_profile(raw, first, last)

  for i = first, last do
    if water[i] then
      mode[i] = "bridge"
    elseif raw[i] and y[i] and raw[i] - y[i] > MAX_CUT then
      mode[i] = "tunnel"
    elseif raw[i] and y[i] and y[i] - raw[i] > MAX_FILL then
      mode[i] = "bridge"
    else
      mode[i] = "ground"
    end
  end

  return {cells = out_cells, raw = raw, y = y, mode = mode, offsets = chosen}
end

--- Lay one continuous stretch of a way.
--
-- The whole stretch shares one height profile. Paving segment by segment
-- restarts the profile at every corner: on a slope the road drifts away from
-- the ground within a segment and then jumps back to it at the next, which
-- reads as a staircase with a cliff in it every forty nodes.
--
-- `opts.blocked(x, z)` marks ground the way may cross on the plan but must not
-- touch in the world — a road drawn to a village centre would otherwise clear
-- head-room straight through whatever was standing there.
local function pave_way(cells, first, last, opts)
  -- An explicit material wins over a role name: a village street is surfaced
  -- from its own biome palette, so that a settlement in the desert is not
  -- joined up in the same coarse dirt as one in a forest.
  local surface = opts.material
    or perfectworld.compat.get_material(opts.surface or "road", {required = false})
  local deck = perfectworld.compat.get_material("wood_planks", {required = false})
  local fill = perfectworld.compat.get_material("ground", {required = false})
  local width = opts.width or 1
  local blocked = opts.blocked

  -- What the ground does under the stretch. Water is recorded at its surface:
  -- a bridge is laid level with the bank, not on the lake bed.
  local raw, water = {}, {}
  for i = first, last do
    local column = world_terrain.sample_column(cells[i].x, cells[i].z)
    if column then
      -- A deck already laid over this water reads as solid ground, and the next
      -- pass — the neighbouring chunk's, overlapping this one — would replace
      -- the planks with road surface and turn the bridge into a dirt causeway.
      -- What is underneath still says water, so that is what is asked.
      local underneath = minetest.get_node(
        {x = cells[i].x, y = column.y - 1, z = cells[i].z}).name
      water[i] = column.liquid == true
        or perfectworld.compat.is_liquid_node(underneath)
      raw[i] = water[i] and column.y
        or (paving_level(cells[i].x, cells[i].z) or column.y)
    end
  end

  local route = perfectworld.planner.route_way(cells, first, last, raw, water,
    opts.deviate)
  local y = route.y
  local crossable = bridgeable(water, first, last)

  local pier = perfectworld.compat.get_material("cobble", {required = false})
  local placed, bridged, unbridged, tunnelled, deepest_cut, landings = 0, 0, 0, 0, 0, 0
  for i = first, last do
    local level = y[i]
    local skip = water[i] and not crossable[i]
    local cell = route.cells[i] or cells[i]
    if level and not skip then
      -- Across the direction of travel, taken from the neighbours rather than
      -- from one segment, so the strip does not kink at a corner.
      local ahead = route.cells[math.min(i + 1, last)] or cell
      local behind = route.cells[math.max(i - 1, first)] or cell
      local offsets = perfectworld.roads.cross_section(
        ahead.x - behind.x, ahead.z - behind.z, width)
      local mode = route.mode[i]
      local material = (mode == "bridge") and deck or surface
      local cut = (route.raw[i] and route.raw[i] > level) and (route.raw[i] - level) or 0
      if cut > deepest_cut then deepest_cut = cut end
      if mode == "bridge" then bridged = bridged + 1 end
      if mode == "tunnel" then tunnelled = tunnelled + 1 end

      for _, offset in ipairs(offsets) do
        local px, pz = cell.x + offset.x, cell.z + offset.z
        if not (blocked and blocked(px, pz)) then
          -- Head-room, and no more.
          --
          -- This used to clear the whole depth of the cutting, which is how a
          -- road through a hill became a canyon with a road at the bottom. A
          -- walker needs three nodes; everything above that is the hill, and
          -- the hill stays. Bounding it here is what turns a deep cutting into
          -- a bore — a tunnel — without any other machinery.
          local felled = false
          for above = 1, 3 do
            local pos = {x = px, y = level + above, z = pz}
            local name = minetest.get_node(pos).name
            if name ~= "air" and name ~= "ignore" then
              local class = perfectworld.compat.classify_node(name)
              if class.tree or class.leaves then felled = true end
              minetest.set_node(pos, {name = "air"})
            end
          end

          -- Fell the whole tree, not the three nodes in the way.
          --
          -- Clearing head-room through a wood cut the trunk at road height and
          -- left everything above it hanging in the sky. Photographed from the
          -- air it is the most obviously wrong thing about a road through
          -- forest: a row of trunk segments floating over the carriageway.
          -- Clearing a road through a wood is ordinary; leaving the tops up is
          -- not.
          if felled then
            for above = 4, 24 do
              local pos = {x = px, y = level + above, z = pz}
              local name = minetest.get_node(pos).name
              if name == "air" or name == "ignore" then break end
              local class = perfectworld.compat.classify_node(name)
              if not (class.tree or class.leaves) then break end
              minetest.set_node(pos, {name = "air"})
            end
          end
          minetest.set_node({x = px, y = level, z = pz}, {name = material})
          -- An embankment where the road runs above the ground. One node of
          -- fill was enough while the profile could only ever cut; now that it
          -- is floored out of the abyss it also rises, and a carriageway with
          -- daylight under it is not a road.
          for down = 1, MAX_FILL + 1 do
            local at = {x = px, y = level - down, z = pz}
            local below = minetest.get_node(at).name
            if below == "air" or below == "ignore"
              or perfectworld.compat.is_liquid_node(below) then
              minetest.set_node(at, {name = fill})
            else
              break
            end
          end
          placed = placed + 1
        end
      end

      -- A bridge stands on something. Piers every fourth cell, carried down to
      -- whatever is under the deck: without them a crossing over a gorge is a
      -- ribbon hanging in the air, which is the other way a road can look
      -- wrong on broken ground.
      if mode == "bridge" and (i - first) % 4 == 0 and pier and pier ~= "air" then
        local floor_y = route.raw[i]
        if floor_y and level - floor_y > 1 then
          for py = level - 1, math.max(floor_y, level - 24), -1 do
            local name = minetest.get_node({x = cell.x, y = py, z = cell.z}).name
            if name == "air" or name == "ignore"
              or perfectworld.compat.is_liquid_node(name) then
              minetest.set_node({x = cell.x, y = py, z = cell.z}, {name = pier})
              placed = placed + 1
            else
              break
            end
          end
        end
      end
    elseif skip then
      unbridged = unbridged + 1
      -- The first cell of open water, with road behind it: this is the shore,
      -- and the road has arrived rather than failed.
      if i > first and route.mode[i - 1] ~= nil and y[i - 1]
        and not (water[i - 1] and not crossable[i - 1]) then
        landings = landings + 1
        placed = placed + build_landing(
          route.cells[i - 1] or cells[i - 1], y[i - 1],
          route.cells[i] or cells[i], opts.palette)
      end
    end
  end

  return placed, bridged, unbridged, deepest_cut, tunnelled, landings
end

perfectworld.planner._pave_way = pave_way
perfectworld.planner._link_centreline = link_centreline

--- Build a walkable way from `from` to `to`, stepping at most one block per
-- cell and cutting head-room, so a villager on foot can actually use it.
local function carve_walkway(from, to, material_name, blocked, opts)
  opts = opts or {}
  local dx, dz = to.x - from.x, to.z - from.z
  local steps = math.max(math.abs(dx), math.abs(dz), 1)
  local target_y = from.y or paving_level(from.x, from.z)
  local hint = target_y
  local cells = {}
  for s = 0, steps do
    local t = s / steps
    cells[s] = {
      x = math.floor(from.x + dx * t + 0.5),
      z = math.floor(from.z + dz * t + 0.5),
    }
  end

  -- Where the way has to arrive. Descending only as the ground happens to fall
  -- meant a driveway from a door five nodes above the street ran level until it
  -- reached the street and then dumped the whole difference on the last cell —
  -- which is a cell of the finished carriageway. Aiming at the destination from
  -- the start spreads the descent over the cells there are.
  local destination_y = opts.keep_destination and paving_level(to.x, to.z) or nil

  local previous_y = target_y
  for s = 0, steps do
    local cell = cells[s]
    local natural = paving_level(cell.x, cell.z, hint)
    local y = natural or previous_y
    if destination_y and y then
      local remaining = steps - s
      if y > destination_y + remaining then y = destination_y + remaining end
      if y < destination_y - remaining then y = destination_y - remaining end
    end
    if previous_y then
      if y > previous_y + 1 then y = previous_y + 1 end
      if y < previous_y - 1 then y = previous_y - 1 end
    end
    -- The street owns its own surface. Writing the last cell re-levelled the
    -- carriageway to whatever height the driveway's chain happened to reach.
    if y and opts.keep_destination and s == steps then
      previous_y = y
      hint = y
    elseif y and blocked and blocked(cell.x, cell.z) then
      -- Never cut through a building to reach another one.
      previous_y = y
      hint = y
    elseif y then
      minetest.set_node({x = cell.x, y = y, z = cell.z}, {name = material_name})
      local below = minetest.get_node({x = cell.x, y = y - 1, z = cell.z}).name
      if below == "air" or below == "ignore" then
        minetest.set_node({x = cell.x, y = y - 1, z = cell.z},
          {name = perfectworld.compat.get_material("ground", {required = false})})
      end
      for above = 1, 3 do
        local pos = {x = cell.x, y = y + above, z = cell.z}
        local name = minetest.get_node(pos).name
        if name ~= "air" and name ~= "ignore"
          and not perfectworld.compat.is_liquid_node(name) then
          minetest.set_node(pos, {name = "air"})
        end
      end
      previous_y = y
      hint = y
    end
  end
  return previous_y
end

--- A cell a walker can actually occupy: the air above the first solid node,
--- with head-room. Pathfinding from inside a block always fails.
local function standing_spot(x, z, hint_y)
  local top = (hint_y or 64) + 10
  local bottom = (hint_y or 64) - 12
  for y = top, bottom, -1 do
    local name = minetest.get_node({x = x, y = y, z = z}).name
    if name ~= "air" and name ~= "ignore" then
      local head = minetest.get_node({x = x, y = y + 1, z = z}).name
      local head2 = minetest.get_node({x = x, y = y + 2, z = z}).name
      if (head == "air" or head == "ignore") and (head2 == "air" or head2 == "ignore") then
        return {x = x, y = y + 1, z = z}
      end
    end
  end
  return nil
end

perfectworld.planner._standing_spot = standing_spot
perfectworld.planner._paving_level = paving_level
perfectworld.planner._carve_walkway = carve_walkway

--- Make a door usable from the street.
--
-- The sill is levelled with the building floor, then a stepped way is cut
-- down to the road. Vanilla villages do the same thing: "a building spawned
-- above street level has stairs leading straight out from its entrance down
-- to the street level".
local function build_door_approach(door, floor_y, road_point, material_name, profile, blocked)
  if not floor_y then
    carve_walkway(door, road_point, material_name, nil, {keep_destination = true})
    return
  end

  local foundation = perfectworld.structures.palette_material(
    profile.material_palette, "foundation", "foundation")
  minetest.set_node({x = door.x, y = floor_y - 1, z = door.z}, {name = foundation})
  minetest.set_node({x = door.x, y = floor_y, z = door.z}, {name = material_name})
  -- Head-room only up to two blocks: the porch eave above the doorstep is
  -- part of the house and must survive.
  for above = 1, 2 do
    local pos = {x = door.x, y = floor_y + above, z = door.z}
    local name = minetest.get_node(pos).name
    if name ~= "air" and name ~= "ignore" then
      minetest.set_node(pos, {name = "air"})
    end
  end

  carve_walkway({x = door.x, y = floor_y, z = door.z}, road_point, material_name, blocked,
    {keep_destination = true})
end

local function worksite_candidate_anchors(lot, seed_key)
  if not lot then return {} end
  local gap = 7
  local offsets = {
    {x = lot.footprint_max.x - lot.center.x + gap, z = 0},
    {x = lot.footprint_min.x - lot.center.x - gap, z = 0},
    {x = 0, z = lot.footprint_max.z - lot.center.z + gap},
    {x = 0, z = lot.footprint_min.z - lot.center.z - gap},
  }
  local rotation = choice.index(
    seed_key, "worksite:candidate_rotation", #offsets) - 1
  local anchors = {}
  for index = 1, #offsets do
    local offset = offsets[((index + rotation - 1) % #offsets) + 1]
    local x, z = lot.center.x + offset.x, lot.center.z + offset.z
    local y = paving_level(x, z, lot.position and lot.position.y)
    if y then anchors[#anchors + 1] = {x = x, y = y, z = z} end
  end
  return anchors
end

local function production_lot(plan, profile)
  local production_role
  for role, required in pairs(profile.required_role_counts or {}) do
    if role ~= "dwelling" and (tonumber(required) or 0) > 0 then
      production_role = role
      break
    end
  end
  if not production_role then return nil end
  for _, lot in ipairs(plan.lots or {}) do
    if lot.role == production_role and lot.status == "materialized" then
      return lot
    end
  end
  return nil
end

local function place_required_worksite(plan, profile, candidate, roads)
  local kind = profile.required_worksite
  if not kind then return false, {reason = "missing_required_worksite_kind"} end
  local lot = production_lot(plan, profile)
  local road_cells = {}
  for _, road in ipairs(roads or {}) do
    for _, cell in ipairs(perfectworld.roads.rasterize_record(road)) do
      road_cells[cell.x .. ":" .. cell.z] = cell
    end
  end
  local footprints = {}
  for _, planned_lot in ipairs(plan.lots or {}) do
    if planned_lot.status == "materialized" then
      footprints[#footprints + 1] = {
        min = deep_copy(planned_lot.footprint_min),
        max = deep_copy(planned_lot.footprint_max),
      }
    end
  end

  local ecology = profile.ecology or {}
  local context = {
    worksite_id = candidate.id .. "_worksite_" .. kind .. "_1",
    required = true,
    anchor = lot and {
      x = lot.center.x,
      y = lot.position and lot.position.y or 0,
      z = lot.center.z,
    } or nil,
    candidate_anchors = worksite_candidate_anchors(lot, profile.seed_key),
    shore_anchor = deep_copy(ecology.shore_anchor),
    shore_land_anchor = deep_copy(ecology.shore_land_anchor),
    stone_anchor = deep_copy(ecology.stone_anchor),
    approach_anchor = profile.selected_site and deep_copy(profile.selected_site)
      or (lot and deep_copy(lot.center)),
    road_cells = road_cells,
    structure_footprints = footprints,
    surface_y = function(x, z)
      return paving_level(x, z, lot and lot.position and lot.position.y)
    end,
    palette = profile.material_palette,
    seed_key = profile.seed_key,
  }
  return perfectworld.planner.worksites.place(kind, context)
end

local function materialize_village_plan(plan, profile, candidate)
  if perfectworld.planner.is_placed(candidate.id) then
    return true, {reason = "already_placed", settlement_id = candidate.id}
  end

  local palette = profile.material_palette
  local road_material = perfectworld.structures.palette_material(palette, "path", "road")
  local placed_structures = {}
  local placed_roads = {}
  local placed_worksites = {}
  local errors = {}
  local warnings = {}

  -- Structures first: terrain preparation reshapes the surface, and doing it
  -- after the roads were laid would bury or erase them.
  for _, lot in ipairs(plan.lots) do
    local def = perfectworld.structures.get(lot.structure_name)
    if not def then
      table.insert(errors, "structure_not_found:" .. tostring(lot.structure_name))
    else
      local structure_id = candidate.id .. "_struct_" .. (#placed_structures + 1)
      -- What the household in this building does for a living. Taken from the
      -- settlement's specialization, which is itself decided from physical
      -- evidence, so the trades follow from the land. The building only needs
      -- to know in order to put the right workstation in the room; the villager
      -- who eventually claims it decides the rest for itself.
      local trade
      if lot.role == "dwelling" and perfectworld.settlements.trades_for then
        local offered = perfectworld.settlements.trades_for(profile.specialization, {
          town = profile.settlement_type == "town" or profile.settlement_type == "city",
        })
        trade = choice.pick(profile.seed_key, "lot:" .. lot.index .. ":trade", offered)
      end

      local ctx = {
        structure_id = structure_id,
        pos = {x = lot.center.x, y = 0, z = lot.center.z},
        rotation = lot.rotation,
        region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
        settlement_id = candidate.id,
        palette = palette,
        terrain_overrides = plan.terrain_overrides,
        trade = trade,
      }
      local ok, result = perfectworld.structures.place(lot.structure_name, ctx)
      if ok then
        lot.status = "materialized"
        lot.position = result.position
        lot.structure_id = structure_id
        perfectworld.planner.record_structure({
          structure_id = structure_id,
          structure_name = lot.structure_name,
          definition_version = def.version or 1,
          role = lot.role,
          status = "materialized",
          position = result.position,
          rotation = lot.rotation,
          footprint_min = lot.footprint_min,
          footprint_max = lot.footprint_max,
          road_point = lot.road_point,
          region_id = ctx.region_id,
          settlement_id = candidate.id,
        })
        table.insert(placed_structures, {
          structure_id = structure_id,
          structure_name = lot.structure_name,
          role = lot.role,
          rotation = lot.rotation,
          position = result.position,
        })
      else
        lot.status = "skipped"
        table.insert(errors, "placement_failed:" .. tostring(lot.structure_name)
          .. ":" .. tostring(result and result.reason))
      end
    end
  end

  -- Roads and the short driveways that connect every placed lot to them.
  --
  -- A street is laid in one pass over its whole length, sharing one height
  -- profile, for the same reason the roads between settlements are: paving
  -- segment by segment restarted the profile at every corner, so on undulating
  -- ground the carriageway drifted off the surface within a segment and stepped
  -- back onto it at the next. That is the patchy street this project has been
  -- looking at since the first screenshots.
  world_terrain.reset()
  for _, road in ipairs(plan.roads) do
    local nodes = 0
    local cells = link_centreline(road)
    if #cells >= 2 then
      nodes = pave_way(cells, 1, #cells, {
        width = road.width or 2,
        material = road_material,
        deviate = false,
      })
    end
    local road_record = {
      id = road.id,
      type = "local_road",
      from_settlement = candidate.id,
      path = road.points,
      length = #road.points,
      segment_count = math.max(#road.points - 1, 0),
      width = road.width,
      kind = road.kind,
      nodes_placed = nodes,
      cells = perfectworld.roads.rasterize(
        road.points or {}, road.width or 2),
    }
    perfectworld.planner.save_road(road_record)
    table.insert(placed_roads, road_record)
  end

  for _, lot in ipairs(plan.lots) do
    if lot.status == "materialized" then
      local def = perfectworld.structures.get(lot.structure_name)
      local door = {x = lot.center.x, z = lot.center.z}
      for _, c in ipairs((def and def.connectors) or {}) do
        if c.type == "road" and c.offset_pos then
          local rotated = perfectworld.structures.rotate_point(c.offset_pos, lot.rotation)
          door = {x = lot.center.x + rotated.x, z = lot.center.z + rotated.z}
          break
        end
      end
      -- The threshold must sit at floor level, and the way down to the street
      -- must be walkable. Anything else strands the building: a villager on
      -- foot cannot climb into a door hanging above the ground.
      local floor_y = (lot.position and lot.position.y) or paving_level(door.x, door.z)
      lot.door = {x = door.x, y = floor_y, z = door.z}
      local structure_record = perfectworld.planner.get_structure(lot.structure_id)
      if structure_record then
        structure_record.entrances = {{
          position = deep_copy(lot.door),
          road_point = deep_copy(lot.road_point),
        }}
        perfectworld.planner.record_structure(structure_record)
      end
      build_door_approach(door, floor_y, lot.road_point, road_material, profile,
        function(x, z)
          for _, other in ipairs(plan.lots) do
            if other ~= lot and other.footprint_min then
              if x >= other.footprint_min.x - 1 and x <= other.footprint_max.x + 1
                and z >= other.footprint_min.z - 1 and z <= other.footprint_max.z + 1 then
                return true
              end
            end
          end
          return false
        end)
      -- The driveway is part of the road network: without a record for it
      -- nothing proves the lot is reachable, and validation cannot tell a
      -- connected lot from a stranded one.
      local driveway = {
        id = lot.structure_id .. "_drive",
        type = "local_road",
        from_settlement = candidate.id,
        to_structure = lot.structure_id,
        path = {{x = door.x, z = door.z}, {x = lot.road_point.x, z = lot.road_point.z}},
        length = 2,
        segment_count = 1,
        width = 1,
        kind = "driveway",
      }
      driveway.cells = perfectworld.roads.rasterize_record(driveway)
      perfectworld.planner.save_road(driveway)
      table.insert(placed_roads, driveway)
    end
  end

  local worksite_ok, worksite_result = place_required_worksite(
    plan, profile, candidate, placed_roads)
  if worksite_ok then
    placed_worksites[#placed_worksites + 1] = worksite_result
  else
    errors[#errors + 1] = "worksite_failed:"
      .. tostring(profile.required_worksite) .. ":"
      .. tostring(worksite_result and worksite_result.reason)
  end

  -- The centre of a settlement is the middle of what was built, not the
  -- nominal candidate point: on broken ground the candidate can sit at the
  -- foot of a cliff while every house stands on the plateau above it.
  local settlement_center
  do
    local sum_x, sum_z, count = 0, 0, 0
    for _, s in ipairs(placed_structures) do
      if s.position then
        sum_x = sum_x + s.position.x
        sum_z = sum_z + s.position.z
        count = count + 1
      end
    end
    if count > 0 then
      local cx = math.floor(sum_x / count + 0.5)
      local cz = math.floor(sum_z / count + 0.5)
      settlement_center = {x = cx, y = paving_level(cx, cz) or 0, z = cz}
    else
      settlement_center = {
        x = candidate.x,
        y = world_terrain.surface_y(candidate.x, candidate.z) or 0,
        z = candidate.z,
      }
    end
  end

  -- A point on the village's own street: the honest starting point for
  -- "can a villager walk from the street to this door".
  local street_anchor = settlement_center
  do
    local best, best_distance = nil, math.huge
    for _, road in ipairs(placed_roads) do
      if road.kind ~= "driveway" then
        for _, point in ipairs(road.path or {}) do
          local dx = point.x - settlement_center.x
          local dz = point.z - settlement_center.z
          local distance = dx * dx + dz * dz
          if distance < best_distance then
            best_distance = distance
            best = point
          end
        end
      end
    end
    if best then
      street_anchor = {x = best.x, y = paving_level(best.x, best.z) or settlement_center.y, z = best.z}
    end
  end

  -- The bell.
  --
  -- A bell is what makes a cluster of houses read as a village to the game
  -- rather than as loose mobs standing near each other: villagers gather at it,
  -- raise the alarm from it, and the iron golems that defend the place are
  -- counted around it. It goes beside the street, one node clear of the
  -- carriageway, so it is somewhere people pass rather than somewhere they
  -- have to be sent.
  local bell_placed = nil
  do
    local bell = perfectworld.compat.get_material("bell", {required = false})
    if bell and bell ~= "air" and minetest.registered_nodes[bell] then
      local plinth = perfectworld.structures.palette_material(
        profile.material_palette, "foundation", "foundation")
      -- Candidate spots around the street anchor, nearest first. The anchor
      -- itself is carriageway and must stay clear.
      -- A spiral out from the street, not eight fixed spots. In a village the
      -- first ring is empty ground; in a town it is built up, and a town that
      -- reported `no_bell_site` is a town whose villagers have nowhere to
      -- gather and no alarm to raise — which also costs it the golems the game
      -- would otherwise post around a bell.
      local offsets = {}
      for radius = 2, 7 do
        for _, direction in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1},
          {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}) do
          offsets[#offsets + 1] = {x = direction[1] * radius, z = direction[2] * radius}
        end
      end
      for _, offset in ipairs(offsets) do
        local x = street_anchor.x + offset.x
        local z = street_anchor.z + offset.z
        local y = paving_level(x, z)
        if y and math.abs(y - street_anchor.y) <= 2 then
          local head = minetest.get_node({x = x, y = y + 1, z = z}).name
          local head2 = minetest.get_node({x = x, y = y + 2, z = z}).name
          if (head == "air" or head == "ignore")
            and (head2 == "air" or head2 == "ignore") then
            minetest.set_node({x = x, y = y + 1, z = z}, {name = plinth})
            minetest.set_node({x = x, y = y + 2, z = z}, {name = bell})
            bell_placed = {x = x, y = y + 2, z = z}
            break
          end
        end
      end
    end
    if not bell_placed then
      warnings[#warnings + 1] = "no_bell_site"
    end
  end

  -- The town wall.
  --
  -- A wall is what tells you, from outside and at a distance, that the place
  -- you are approaching is a town and not a big village. It follows the ground
  -- rather than being levelled into it, so it steps down a slope the way a
  -- built wall does.
  --
  -- The gates are not decoration either: a wall without them seals the town,
  -- and everything that was reachable before — the streets, the doors, the
  -- roads to the next settlement — stops being reachable. So every way that
  -- crosses the line gets an opening, and the ways include the roads to other
  -- settlements, which arrive from outside and would otherwise end at a wall.
  local wall_result = nil
  if profile.settlement_type == "town" or profile.settlement_type == "city" then
    local ways = {}
    for _, road in ipairs(placed_roads) do
      if road.kind ~= "driveway" then ways[#ways + 1] = road end
    end
    if perfectworld.roads.links_for_settlement then
      local rx, rz = candidate.rx, candidate.rz
      if not rx then rx, rz = perfectworld.get_region_coords({x = candidate.x, y = 0, z = candidate.z}) end
      for _, link in ipairs(perfectworld.roads.links_for_settlement(candidate.id, rx, rz)) do
        ways[#ways + 1] = link
      end
    end
    wall_result = perfectworld.planner.build_town_wall(plan.bounds, profile, ways)
    if wall_result then
      warnings[#warnings + 1] = string.format("wall:%d nodes, %d gate(s)",
        wall_result.nodes, wall_result.gates)
      -- A guard on the gates from the first day, rather than waiting for the
      -- population to reach the threshold Mineclonia raises golems at. That
      -- mechanism is left alone and still applies.
      if perfectworld.population and perfectworld.population.post_guards
        and wall_result.gate_spots then
        perfectworld.population.post_guards(wall_result.gate_spots,
          math.max(2, math.min(4, wall_result.gates)))
      end

      -- Farmland outside the wall. A town eats more than it can grow inside
      -- itself, and a walled town with nothing but wall around it is a fort.
      local fields = perfectworld.planner.ring_town_with_fields(
        plan, profile, candidate, wall_result)
      warnings[#warnings + 1] = string.format("fields:%d of %d placed",
        fields.placed, fields.wanted)
    end
  end

  -- The name of the place, where somebody arriving would read it.
  do
    local ways = {}
    if perfectworld.roads.links_for_settlement then
      local rx, rz = candidate.rx, candidate.rz
      if not rx then
        rx, rz = perfectworld.get_region_coords({x = candidate.x, y = 0, z = candidate.z})
      end
      for _, link in ipairs(perfectworld.roads.links_for_settlement(candidate.id, rx, rz)) do
        ways[#ways + 1] = link
      end
    end
    local place_name = perfectworld.settlements.name_for(candidate.id,
      profile.environment and profile.environment.biome_family,
      profile.specialization, profile.settlement_type)
    local signs = perfectworld.planner.signpost_settlement(
      candidate, profile, plan.bounds, ways, place_name)
    warnings[#warnings + 1] = string.format("name:%s signs:%d",
      place_name, signs.placed)
  end

  -- Guarantee that every door can be walked to.
  --
  -- The planned driveway is a straight line and terrain does not always
  -- cooperate. Anything still unreachable gets a stepped way cut to it, one
  -- block of rise per cell, which is a staircase by construction. A door
  -- nobody can reach is a house nobody can live in.
  local unreachable = {}
  if minetest.find_path then
    local origin = standing_spot(street_anchor.x, street_anchor.z, street_anchor.y)
      or {x = street_anchor.x, y = street_anchor.y + 1, z = street_anchor.z}
    for _, lot in ipairs(plan.lots) do
      if lot.status == "materialized" and lot.door then
        local target = standing_spot(lot.door.x, lot.door.z, lot.door.y)
          or {x = lot.door.x, y = (lot.door.y or 0) + 1, z = lot.door.z}
        local kerb = standing_spot(lot.road_point.x, lot.road_point.z, lot.door.y)
        local path = minetest.find_path(origin, target, 128, 1, 2, "A*_noprefetch")
          or (kerb and minetest.find_path(kerb, target, 64, 1, 2, "A*_noprefetch"))
        -- Anything a walkway must not cut through: every other building.
        local function blocked_by_building(x, z)
          for _, other in ipairs(plan.lots) do
            if other ~= lot and other.footprint_min then
              if x >= other.footprint_min.x - 1 and x <= other.footprint_max.x + 1
                and z >= other.footprint_min.z - 1 and z <= other.footprint_max.z + 1 then
                return true
              end
            end
          end
          return false
        end

        for _, destination in ipairs({lot.road_point, street_anchor}) do
          if path then break end
          carve_walkway({x = lot.door.x, y = lot.door.y, z = lot.door.z},
            destination, road_material, blocked_by_building, {keep_destination = true})
          origin = standing_spot(street_anchor.x, street_anchor.z, street_anchor.y) or origin
          target = standing_spot(lot.door.x, lot.door.z, lot.door.y) or target
          kerb = standing_spot(lot.road_point.x, lot.road_point.z, lot.door.y) or kerb
          path = minetest.find_path(origin, target, 160, 1, 2, "A*_noprefetch")
            or (kerb and minetest.find_path(kerb, target, 64, 1, 2, "A*_noprefetch"))
        end
        if not path then
          table.insert(unreachable, lot.structure_id)
          minetest.log("warning", "[pw_planner] no walkable route to "
            .. tostring(lot.structure_id) .. " in " .. tostring(candidate.id))
        end
      end
    end
  end

  -- Completion contract.
  local placed_roles = {}
  for _, s in ipairs(placed_structures) do
    placed_roles[s.role] = (placed_roles[s.role] or 0) + 1
  end
  local missing_required = perfectworld.planner.missing_required_roles(
    placed_roles, profile.required_role_counts)
  for _, structure_id in ipairs(unreachable) do
    table.insert(errors, "unreachable_door:" .. structure_id)
  end

  local settlement_status
  if #placed_structures == 0 then
    settlement_status = "failed"
  elseif #errors > 0 or #missing_required > 0 then
    settlement_status = "partial"
  else
    settlement_status = "complete"
  end

  -- Bounds must contain everything that was actually built.
  local bounds = {
    min_x = plan.bounds.min_x, max_x = plan.bounds.max_x,
    min_z = plan.bounds.min_z, max_z = plan.bounds.max_z,
  }
  for _, lot in ipairs(plan.lots) do
    if lot.status == "materialized" then
      bounds.min_x = math.min(bounds.min_x, lot.footprint_min.x, lot.door and lot.door.x or lot.center.x)
      bounds.max_x = math.max(bounds.max_x, lot.footprint_max.x, lot.door and lot.door.x or lot.center.x)
      bounds.min_z = math.min(bounds.min_z, lot.footprint_min.z, lot.door and lot.door.z or lot.center.z)
      bounds.max_z = math.max(bounds.max_z, lot.footprint_max.z, lot.door and lot.door.z or lot.center.z)
    end
  end
  for _, worksite in ipairs(placed_worksites) do
    if worksite.bounds then
      bounds.min_x = math.min(bounds.min_x, worksite.bounds.min.x)
      bounds.max_x = math.max(bounds.max_x, worksite.bounds.max.x)
      bounds.min_z = math.min(bounds.min_z, worksite.bounds.min.z)
      bounds.max_z = math.max(bounds.max_z, worksite.bounds.max.z)
    end
  end

  local settlement_record = {
    settlement_id = candidate.id,
    candidate_id = candidate.id,
    region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
    generator_version = profile.generator_version,
    settlement_grammar_version = profile.settlement_grammar_version,
    seed_key = profile.seed_key,
    status = settlement_status,
    specialization = profile.specialization,
    specialization_score = profile.specialization_score,
    resource_features = deep_copy(profile.resource_features),
    required_worksite = profile.required_worksite,
    required_role_counts = deep_copy(profile.required_role_counts),
    regional_anchor = deep_copy(profile.regional_anchor),
    selected_site = deep_copy(profile.selected_site),
    ecology = deep_copy(profile.ecology),
    name = perfectworld.settlements.name_for(candidate.id,
      profile.environment and profile.environment.biome_family,
      profile.specialization, profile.settlement_type),
    settlement_type = profile.settlement_type,
    center_pos = settlement_center,
    bell_pos = bell_placed,
    street_anchor = street_anchor,
    bounds = bounds,
    environment_profile = profile.environment,
    biome_name = profile.environment and profile.environment.biome_name,
    biome_family = profile.environment and profile.environment.biome_family,
    archetype = profile.archetype,
    size_class = profile.size_class,
    palette_id = profile.palette_id,
    material_palette = palette,
    required_roles = profile.required_roles,
    optional_roles = profile.optional_roles,
    missing_required_roles = missing_required,
    role_counts = placed_roles,
    village_fingerprint = plan.exact_plan_fingerprint,
    exact_plan_fingerprint = plan.exact_plan_fingerprint,
    structural_fingerprint = plan.structural_fingerprint,
    road_graph_fingerprint = plan.road_graph_fingerprint,
    structure_ids = {},
    structure_variants = {},
    road_ids = {},
    worksite_ids = {},
    worksite_kinds = {},
    worksites = deep_copy(placed_worksites),
    road_segment_count = 0,
    lot_count = #placed_structures,
    planned_lot_count = #plan.lots,
    errors = errors,
    warnings = warnings,
    created_at = minetest.get_gametime(),
  }
  for _, s in ipairs(placed_structures) do
    table.insert(settlement_record.structure_ids, s.structure_id)
    table.insert(settlement_record.structure_variants, s.structure_name)
  end
  for _, r in ipairs(placed_roads) do
    table.insert(settlement_record.road_ids, r.id)
    settlement_record.road_segment_count = settlement_record.road_segment_count + (r.segment_count or 0)
  end
  for _, worksite in ipairs(placed_worksites) do
    settlement_record.worksite_ids[#settlement_record.worksite_ids + 1] =
      worksite.id
    settlement_record.worksite_kinds[#settlement_record.worksite_kinds + 1] =
      worksite.kind
  end

  perfectworld.planner.save_settlement_plan(candidate.id, {
    plan = plan,
    profile = profile,
    settlement = settlement_record,
  })
  perfectworld.planner.mark_placed(candidate.id)

  -- People move in as soon as there is somewhere to sleep. Doing it here rather
  -- than on a later visit means the village is inhabited the first time anyone
  -- sees it, and the buildings are still loaded, which is what the bed search
  -- needs. A failure to populate is not a failure to build: it is recorded and
  -- the settlement stands regardless.
  if perfectworld.population and perfectworld.population.populate then
    local settled, detail = perfectworld.population.populate(candidate.id)
    if not settled then
      warnings[#warnings + 1] = "unpopulated:"
        .. tostring(type(detail) == "table" and detail.reason or detail)
    end
  end

  return true, {
    settlement = settlement_record,
    structures = placed_structures,
    roads = placed_roads,
    worksites = placed_worksites,
    errors = errors,
    warnings = warnings,
  }
end

-- === Public API: New Village Materialization ===

function perfectworld.planner.materialize_village_new(candidate)
  if perfectworld.materialization_enabled == false then
    return false, perfectworld.world_format_error or "materialization_disabled"
  end

  if perfectworld.planner.is_placed(candidate.id) then
    local existing = perfectworld.planner.get_settlement_plan(candidate.id)
    if existing and existing.settlement then
      return true, {settlement = existing.settlement, from_cache = true}
    end
    return false, "already_placed_no_record"
  end

  local plan, profile = perfectworld.planner.plan_village(candidate)

  -- "The map is not generated here yet" is a transient condition, not a
  -- verdict on the site. Never burn the candidate on it.
  if not plan.viable and (plan.rejections.no_surface or 0) > 0 then
    return false, {
      reason = "terrain_not_ready",
      missing_surface_probes = plan.rejections.no_surface,
    }
  end

  if not plan.viable then
    -- Never persist an unbuildable settlement as a real one.
    local record = {
      settlement_id = candidate.id,
      candidate_id = candidate.id,
      region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
      generator_version = profile.generator_version,
      settlement_grammar_version = profile.settlement_grammar_version,
      status = "failed",
      reason = "no_viable_layout",
      specialization = profile.specialization,
      specialization_score = profile.specialization_score,
      resource_features = deep_copy(profile.resource_features),
      required_worksite = profile.required_worksite,
      required_role_counts = deep_copy(profile.required_role_counts),
      required_roles = deep_copy(profile.required_roles),
      optional_roles = deep_copy(profile.optional_roles),
      missing_required_roles = deep_copy(plan.missing_required_roles),
      role_counts = deep_copy(plan.role_counts),
      regional_anchor = deep_copy(profile.regional_anchor),
      selected_site = deep_copy(profile.selected_site),
      ecology = deep_copy(profile.ecology),
      rejections = plan.rejections,
      center_pos = {x = candidate.x, y = 0, z = candidate.z},
      bounds = plan.bounds,
      archetype = profile.archetype,
      size_class = profile.size_class,
      palette_id = profile.palette_id,
      biome_family = profile.environment and profile.environment.biome_family,
      environment_profile = profile.environment,
      exact_plan_fingerprint = plan.exact_plan_fingerprint,
      structural_fingerprint = plan.structural_fingerprint,
      road_graph_fingerprint = plan.road_graph_fingerprint,
      village_fingerprint = plan.exact_plan_fingerprint,
      structure_ids = {},
      structure_variants = {},
      road_ids = {},
      worksite_ids = {},
      worksite_kinds = {},
      worksites = {},
      lot_count = 0,
      planned_lot_count = #plan.lots,
      errors = {},
      warnings = {},
      created_at = minetest.get_gametime(),
    }
    perfectworld.planner.save_settlement_plan(candidate.id, {
      plan = plan, profile = profile, settlement = record,
    })
    perfectworld.planner.mark_placed(candidate.id)
    return false, {settlement = record, reason = "no_viable_layout"}
  end

  return materialize_village_plan(plan, profile, candidate)
end

-- === Public API: Fingerprint ===

function perfectworld.planner.get_village_fingerprint(candidate)
  local existing = perfectworld.planner.get_settlement_plan(candidate.id)
  if existing and existing.settlement then
    return existing.settlement.village_fingerprint
  end
  return nil
end

-- === Settlement Validation ===
--
-- Checks the persisted record *and* the actual world. A record in mod_storage
-- is not evidence that anything was built.

local function rects_overlap_margin(a, b, margin)
  return a.min.x - margin <= b.max.x and a.max.x + margin >= b.min.x
    and a.min.z - margin <= b.max.z and a.max.z + margin >= b.min.z
end

function perfectworld.planner.validate_settlement(settlement_id)
  local report = {
    settlement_id = settlement_id,
    ok = false,
    issues = {},
    checks = {},
  }
  local function issue(code, detail)
    table.insert(report.issues, detail and (code .. ":" .. detail) or code)
  end
  local function check(name, ok, detail)
    report.checks[name] = ok and "ok" or ("FAIL" .. (detail and (":" .. detail) or ""))
    if not ok then issue(name, detail) end
    return ok
  end

  local stored = perfectworld.planner.get_settlement_plan(settlement_id)
  local settlement = stored and stored.settlement
  if not settlement then
    issue("record_missing")
    return report
  end
  local plan = stored.plan or {}
  -- Mapblocks are unloaded once nobody is nearby and get_node then reports
  -- "ignore", so every world-reading check below — including the pathfinder —
  -- needs the area pulled back in first.
  if minetest.load_area and settlement.bounds then
    local b = settlement.bounds
    pcall(minetest.load_area,
      {x = b.min_x - 8, y = -32, z = b.min_z - 8},
      {x = b.max_x + 8, y = 200, z = b.max_z + 8})
  end
  report.status = settlement.status
  report.archetype = settlement.archetype
  report.lot_count = settlement.lot_count
  local worksite_records = settlement.worksites or {}

  -- 1. status / completeness contract
  if settlement.status == "complete" then
    check("complete_has_lots", (settlement.lot_count or 0) > 0)
    check("complete_has_required_roles", #(settlement.missing_required_roles or {}) == 0,
      table.concat(settlement.missing_required_roles or {}, ","))
    check("complete_has_no_errors", #(settlement.errors or {}) == 0,
      tostring((settlement.errors or {})[1]))
    check("complete_fully_materialized",
      (settlement.lot_count or 0) >= (settlement.planned_lot_count or 0),
      tostring(settlement.lot_count) .. "/" .. tostring(settlement.planned_lot_count))
    if settlement.required_worksite then
      local required_recorded = false
      for _, worksite in ipairs(worksite_records) do
        if worksite.kind == settlement.required_worksite
          and worksite.required == true
          and worksite.status == "materialized" then
          required_recorded = true
          break
        end
      end
      check("complete_has_required_worksite", required_recorded,
        tostring(settlement.required_worksite))
    end
  elseif settlement.status == "failed" then
    check("failed_has_no_lots", (settlement.lot_count or 0) == 0)
  end
  check("has_fingerprints",
    settlement.exact_plan_fingerprint ~= nil
    and settlement.structural_fingerprint ~= nil
    and settlement.road_graph_fingerprint ~= nil)

  -- 2. referenced records exist and resolve
  local structures = {}
  for _, sid in ipairs(settlement.structure_ids or {}) do
    local record = perfectworld.planner.get_structure(sid)
    if not record then
      issue("missing_structure", sid)
    else
      if not perfectworld.structures.get(record.structure_name) then
        issue("unregistered_structure", record.structure_name)
      end
      table.insert(structures, record)
    end
  end
  report.checks.structures_resolve = (#structures == #(settlement.structure_ids or {}))
    and "ok" or "FAIL"

  local roads = {}
  for _, rid in ipairs(settlement.road_ids or {}) do
    local road = perfectworld.planner.get_road(rid)
    if not road then
      issue("missing_road", rid)
    else
      table.insert(roads, road)
    end
  end
  report.checks.roads_resolve = (#roads == #(settlement.road_ids or {})) and "ok" or "FAIL"

  -- 3. geometry: footprints, road corridors, bounds
  local boxes = {}
  for _, record in ipairs(structures) do
    local def = perfectworld.structures.get(record.structure_name)
    local origin = record.position or {x = 0, y = 0, z = 0}
    local fmin, fmax
    if record.footprint_min and record.footprint_max then
      fmin, fmax = record.footprint_min, record.footprint_max
    elseif def then
      fmin, fmax = perfectworld.structures.get_footprint(def, origin, record.rotation or 0)
    end
    if fmin and fmax then
      table.insert(boxes, {
        id = record.structure_id,
        min = {x = math.min(fmin.x, fmax.x), z = math.min(fmin.z, fmax.z)},
        max = {x = math.max(fmin.x, fmax.x), z = math.max(fmin.z, fmax.z)},
        record = record,
        def = def,
      })
    end
  end

  local overlap = nil
  local neighbour_damage = nil
  for i = 1, #boxes do
    for j = i + 1, #boxes do
      if rects_overlap_margin(boxes[i], boxes[j], 0) then
        overlap = boxes[i].id .. "|" .. boxes[j].id
      elseif rects_overlap_margin(boxes[i], boxes[j], 1) then
        -- terrain preparation reaches one block past the footprint
        neighbour_damage = boxes[i].id .. "|" .. boxes[j].id
      end
    end
  end
  check("footprints_disjoint", overlap == nil, overlap)
  check("terrain_prep_isolated", neighbour_damage == nil, neighbour_damage)

  -- Carriageways must never cross a building; driveways deliberately run up to
  -- a door, so they only count towards connectivity.
  local road_cells = {}
  local reachable_cells = {}
  for _, road in ipairs(roads) do
    local is_driveway = road.kind == "driveway"
    for _, cell in ipairs(perfectworld.roads.rasterize_record(road)) do
      local key = cell.x .. ":" .. cell.z
      reachable_cells[key] = true
      if not is_driveway then road_cells[key] = true end
    end
  end

  local road_through = nil
  for _, box in ipairs(boxes) do
    for x = box.min.x, box.max.x do
      for z = box.min.z, box.max.z do
        if road_cells[x .. ":" .. z] then road_through = box.id break end
      end
      if road_through then break end
    end
    if road_through then break end
  end
  check("roads_avoid_buildings", road_through == nil, road_through)

  -- Work sites are physical settlement components. Persistence tells the
  -- validator where to inspect, but never proves that the field, dock, yard
  -- or minehead still exists in the world.
  local missing_worksite, worksite_road_overlap, worksite_building_overlap
  for _, worksite in ipairs(worksite_records) do
    local physical_nodes = 0
    for _, expected in ipairs(worksite.expected_nodes or {}) do
      local pos = expected.position
      if pos then
        local node = minetest.get_node(pos)
        if node.name ~= "air" and node.name ~= "ignore" then
          physical_nodes = physical_nodes + 1
        end
      end
    end
    if worksite.status ~= "materialized" or physical_nodes == 0 then
      missing_worksite = missing_worksite or tostring(worksite.id or worksite.kind)
    end

    for _, cell in ipairs(worksite.footprint_cells or {}) do
      local key = cell.x .. ":" .. cell.z
      if reachable_cells[key] then
        worksite_road_overlap = worksite_road_overlap
          or (tostring(worksite.id or worksite.kind) .. "@" .. key)
      end
      for _, box in ipairs(boxes) do
        if cell.x >= box.min.x and cell.x <= box.max.x
          and cell.z >= box.min.z and cell.z <= box.max.z then
          worksite_building_overlap = worksite_building_overlap
            or (tostring(worksite.id or worksite.kind) .. "|" .. box.id)
          break
        end
      end
    end
  end
  if #worksite_records > 0
    or (settlement.required_worksite and settlement.status ~= "failed") then
    if #worksite_records == 0 then
      missing_worksite = tostring(settlement.required_worksite)
    end
    check("worksites_present_in_world", missing_worksite == nil, missing_worksite)
    check("worksites_avoid_roads", worksite_road_overlap == nil, worksite_road_overlap)
    check("worksites_avoid_buildings",
      worksite_building_overlap == nil, worksite_building_overlap)
  end

  -- 4. every building reaches a road, and its door is not walled in
  local unconnected, blocked_door = nil, nil
  for _, box in ipairs(boxes) do
    local record = box.record
    local origin = record.position
    local door = origin
    if box.def then
      for _, c in ipairs(box.def.connectors or {}) do
        if c.type == "road" and c.offset_pos then
          local rotated = perfectworld.structures.rotate_point(c.offset_pos, record.rotation or 0)
          door = {x = origin.x + rotated.x, y = origin.y, z = origin.z + rotated.z}
          break
        end
      end
    end
    local reached = false
    for dx = -2, 2 do
      for dz = -2, 2 do
        if reachable_cells[(door.x + dx) .. ":" .. (door.z + dz)] then reached = true break end
      end
      if reached then break end
    end
    if not reached then unconnected = record.structure_id end

    -- the node just outside the door must be passable
    local outside = minetest.get_node({x = door.x, y = door.y + 1, z = door.z})
    local outside_def = minetest.registered_nodes[outside.name]
    if outside.name ~= "air" and outside.name ~= "ignore"
      and outside_def and outside_def.walkable then
      blocked_door = record.structure_id .. "@" .. outside.name
    end
  end
  if #boxes > 0 then
    check("lots_connected_to_road", unconnected == nil, unconnected)
    check("doors_accessible", blocked_door == nil, blocked_door)
  end

  -- 4b. Can somebody actually walk there?
  --
  -- Proximity to a road cell is not reachability. This runs the engine's own
  -- pathfinder on foot from the village centre to every door, with the step
  -- and drop limits a walking villager has. A door nobody can reach is a
  -- house nobody can live in.
  if #boxes > 0 and minetest.find_path then
    local centre = settlement.street_anchor or settlement.center_pos
    local origin = standing_spot(centre.x, centre.z, centre.y)
      or {x = centre.x, y = centre.y + 1, z = centre.z}
    local unwalkable = nil
    local reached = 0
    for _, box in ipairs(boxes) do
      local record = box.record
      local target = record.position
      if box.def then
        for _, c in ipairs(box.def.connectors or {}) do
          if c.type == "road" and c.offset_pos then
            local rotated = perfectworld.structures.rotate_point(c.offset_pos, record.rotation or 0)
            -- Stand *on* the threshold, not inside it: the connector cell
            -- itself is the solid step in front of the door.
            local tx = record.position.x + rotated.x
            local tz = record.position.z + rotated.z
            target = standing_spot(tx, tz, record.position.y)
              or {x = tx, y = record.position.y + 1, z = tz}
            break
          end
        end
      end
      -- Try from the village street and from the kerb outside this very
      -- house: either counts as "you can walk there from the street".
      local origins = {origin}
      if record.road_point then
        local kerb = standing_spot(record.road_point.x, record.road_point.z,
          record.position.y)
        if kerb then table.insert(origins, kerb) end
      end
      local path = nil
      for _, from in ipairs(origins) do
        path = path or minetest.find_path(from, target, 128, 1, 2, "A*_noprefetch")
      end
      if path then
        reached = reached + 1
      else
        unwalkable = (unwalkable and (unwalkable .. ",") or "") .. record.structure_id
      end
    end
    report.doors_reached_on_foot = reached
    report.doors_total = #boxes
    check("doors_reachable_on_foot", unwalkable == nil, unwalkable)
  end

  -- 5. bounds contain everything
  local bounds = settlement.bounds
  if bounds then
    local outside = nil
    local function inside(x, z)
      return x >= bounds.min_x and x <= bounds.max_x and z >= bounds.min_z and z <= bounds.max_z
    end
    for _, box in ipairs(boxes) do
      if not (inside(box.min.x, box.min.z) and inside(box.max.x, box.max.z)) then
        outside = box.id
      end
    end
    for cell in pairs(reachable_cells) do
      local sx, sz = cell:match("^(-?%d+):(-?%d+)$")
      if sx and not inside(tonumber(sx), tonumber(sz)) then
        outside = outside or ("road@" .. cell)
      end
    end
    for _, worksite in ipairs(worksite_records) do
      local worksite_bounds = worksite.bounds
      if worksite_bounds and worksite_bounds.min and worksite_bounds.max
        and not (inside(worksite_bounds.min.x, worksite_bounds.min.z)
          and inside(worksite_bounds.max.x, worksite_bounds.max.z)) then
        outside = outside or ("worksite@" .. tostring(worksite.id or worksite.kind))
      end
    end
    check("bounds_contain_all", outside == nil, outside)
  else
    check("bounds_present", false)
  end

  -- 6. the world actually contains the buildings.
  local missing_in_world, floating, unregistered_node = nil, nil, nil
  for _, box in ipairs(boxes) do
    local origin = box.record.position
    local built = 0
    local scanned = 0
    for x = box.min.x, box.max.x do
      for z = box.min.z, box.max.z do
        for y = origin.y, origin.y + ((box.def and box.def.size.y) or 5) do
          local node = minetest.get_node({x = x, y = y, z = z})
          if node.name ~= "air" and node.name ~= "ignore" then
            scanned = scanned + 1
            if not minetest.registered_nodes[node.name] then
              unregistered_node = node.name
            end
            built = built + 1
          end
        end
      end
    end
    if built < 8 then
      missing_in_world = box.id .. "(nodes=" .. built .. ")"
    end
    -- Ground must exist under the built extent. Use the building footprint:
    -- the full footprint can include a roof overhang, which is supposed to
    -- have nothing beneath it.
    local ground_min, ground_max = box.min, box.max
    if box.def then
      ground_min, ground_max =
        perfectworld.structures.get_building_footprint(box.def, origin, box.record.rotation or 0)
    end
    for x = math.min(ground_min.x, ground_max.x), math.max(ground_min.x, ground_max.x) do
      for z = math.min(ground_min.z, ground_max.z), math.max(ground_min.z, ground_max.z) do
        local below = minetest.get_node({x = x, y = origin.y - 1, z = z})
        if below.name == "air" then
          floating = box.id .. "@" .. x .. "," .. z
        end
      end
    end
  end
  if #boxes > 0 then
    check("structures_present_in_world", missing_in_world == nil, missing_in_world)
    check("no_floating_buildings", floating == nil, floating)
    check("nodes_registered", unregistered_node == nil, unregistered_node)
  end

  -- 7. terrain preparation is bounded to the footprint + a small margin, so a
  -- settlement can never carve an oversized artificial platform
  local oversized = nil
  for _, box in ipairs(boxes) do
    local margin = (box.def and box.def.terrain and box.def.terrain.modification_margin) or 1
    if margin > 2 then
      oversized = box.id .. "(margin=" .. margin .. ")"
    end
  end
  check("no_oversized_platform", oversized == nil, oversized)

  -- 8. no duplicated structures at the same spot (re-materialization guard)
  local seen_positions = {}
  local duplicate = nil
  for _, record in ipairs(structures) do
    local pos = record.position or {x = 0, y = 0, z = 0}
    local key = record.structure_name .. "@" .. pos.x .. "," .. pos.y .. "," .. pos.z
    if seen_positions[key] then duplicate = key end
    seen_positions[key] = true
  end
  check("no_duplicate_structures", duplicate == nil, duplicate)

  report.structure_count = #structures
  report.road_count = #roads
  report.worksite_count = #worksite_records
  report.plan_lot_count = #(plan.lots or {})
  report.ok = #report.issues == 0
  return report
end

-- === Single Structure Materialization ===

local function materialize_single_structure(candidate)
	if perfectworld.materialization_enabled == false then
		return false, perfectworld.world_format_error or "materialization_disabled"
	end

	-- Guard: composite candidates must go through the village pipeline.
	if perfectworld.planner.is_composite_candidate(candidate) then
		return false, "composite_candidate_in_single_pipeline"
	end

	-- Guard: structure_name must resolve to a registered definition.
	if not perfectworld.structures.get(candidate.structure_name) then
		return false, "unregistered_structure:" .. tostring(candidate.structure_name)
	end

	local x = candidate.x
	local z = candidate.z
	local sid = candidate.id

	if perfectworld.planner.is_placed(sid) then
		return false, "already_placed"
	end

	local offsets = {
		{x = 0, z = 0},
		{x = 8, z = 0},
		{x = -8, z = 0},
		{x = 0, z = 8},
		{x = 0, z = -8},
		{x = 8, z = 8},
		{x = -8, z = -8},
	}

	local last_error = nil
	for _, offset in ipairs(offsets) do
		local pos = {x = x + offset.x, y = 0, z = z + offset.z}
		local ctx = {
			structure_id = candidate.structure_id,
			pos = pos,
			rotation = candidate.rotation or 0,
			region_id = candidate.region_id,
			settlement_id = candidate.id,
		}
		if candidate.skip_terrain_check then
			ctx.skip_terrain_check = true
		end
		local ok, result = perfectworld.structures.place(candidate.structure_name, ctx)
		if ok then
			local def = perfectworld.structures.get(candidate.structure_name)
			local record = {
				structure_id = candidate.structure_id,
				structure_name = candidate.structure_name,
				definition_version = def and def.version or 1,
				status = "materialized",
				position = result.position,
				rotation = result.rotation,
				region_id = candidate.region_id,
				settlement_id = candidate.id,
			}
			record.entrances = {}
			for _, connector in ipairs((def and def.connectors) or {}) do
				if connector.type == "road" and connector.offset_pos then
					local rotated = perfectworld.structures.rotate_point(
						connector.offset_pos, result.rotation or 0)
					record.entrances[#record.entrances + 1] = {
						position = {
							x = result.position.x + rotated.x,
							y = result.position.y + (rotated.y or 0),
							z = result.position.z + rotated.z,
						},
					}
				end
			end
			perfectworld.planner.record_structure(record)
			perfectworld.planner.mark_placed(sid)

			-- A farmstead has a bed in it, and four candidates in five are a
			-- farmstead rather than a village. Populating only through the
			-- village pipeline left most of the inhabited buildings in the world
			-- standing empty.
			if perfectworld.population and perfectworld.population.populate_structure then
				perfectworld.population.populate_structure(record)
			end
			return true, record
		end
		last_error = result and result.reason or tostring(result)
	end

	return false, last_error or "no_valid_placement"
end

-- === Region Candidate Materialization ===

local materialize_village = perfectworld.planner.materialize_village_new

function perfectworld.planner.materialize_region_candidate(rx, rz, index, opts)
	opts = opts or {}
	local plan = perfectworld.planner.plan_region(rx, rz)
	local candidate = (plan.settlement_candidates or {})[(tonumber(index) or 0) + 1]
	if not candidate then
		return false, "candidate_not_found"
	end
	candidate.region_id = plan.id
	if opts.force then
		perfectworld.planner._test_unmark_placed(candidate.id)
		perfectworld.planner._test_clear_structure(candidate.structure_id)
		perfectworld.planner._test_clear_settlement(candidate.id)
	end
	-- GUARD: skip_terrain_check bypasses analyze_terrain slope check.
	-- Only photo/test fixture commands (pw_photo_*) should set this.
	-- Normal generation (materialize_chunk) must NOT pass skip_terrain_check.
	candidate.skip_terrain_check = opts.skip_terrain_check

	if perfectworld.planner.is_composite_candidate(candidate) then
		return materialize_village(candidate)
	else
		return materialize_single_structure(candidate)
	end
end

-- === Mapgen Hook ===

-- A village spans up to ~110 blocks, so the mapchunk that contains its centre
-- is never enough terrain to plan on. Villages are therefore queued: the site
-- is emerged first, and only then is the village materialized. Without this the
-- planner reads "ignore" for most of the site, finds no viable layout, and
-- burns the candidate.
local pending_villages = {}

function perfectworld.planner.queue_village(candidate)
	local id = candidate.id
	if pending_villages[id] or perfectworld.planner.is_placed(id) then
		return false
	end
	pending_villages[id] = true
	local queued = perfectworld.core.deep_copy(candidate)
	minetest.after(0, function()
		perfectworld.planner.emerge_village_area(queued, function()
			if perfectworld.planner.is_placed(queued.id) then
				pending_villages[id] = nil
				return
			end
			local ok, result = perfectworld.planner.materialize_village_new(queued)
			pending_villages[id] = nil
			if not ok then
				local reason = type(result) == "table" and result.reason or tostring(result)
				minetest.log("action", "[pw_planner] village " .. tostring(queued.id)
					.. " not materialized: " .. tostring(reason))
			end
		end)
	end)
	return true
end

-- Test helper: forget that a village is in flight so a test can re-queue it.
function perfectworld.planner._test_clear_pending_village(id)
	pending_villages[id] = nil
end

function perfectworld.planner.pending_village_count()
	local n = 0
	for _ in pairs(pending_villages) do n = n + 1 end
	return n
end

-- === Roads between settlements ===
--
-- Village streets are built when the village is; the roads that join villages
-- cannot be, because the far end of a link is usually hundreds of nodes away in
-- terrain nobody has generated yet, and `minetest.set_node` into an unloaded
-- block writes nothing at all.
--
-- So a link is paved the way the world is discovered: each mapchunk lays the
-- stretch that crosses it, and the road grows to meet itself. Which end was
-- built first stops mattering, and no pass ever writes outside the chunk it was
-- handed.

--- How far outside the chunk a segment may start and still be worth paving.
--- A road two wide, drawn diagonally, reaches a little past its centreline.
local LINK_CHUNK_MARGIN = 4

local function segment_touches_chunk(a, b, minp, maxp)
  local low_x = math.min(a.x, b.x) - LINK_CHUNK_MARGIN
  local high_x = math.max(a.x, b.x) + LINK_CHUNK_MARGIN
  local low_z = math.min(a.z, b.z) - LINK_CHUNK_MARGIN
  local high_z = math.max(a.z, b.z) + LINK_CHUNK_MARGIN
  return low_x <= maxp.x and high_x >= minp.x
    and low_z <= maxp.z and high_z >= minp.z
end

perfectworld.planner._segment_touches_chunk = segment_touches_chunk

--- Every link that could possibly cross this chunk, each one once.
--
-- `plan_links` returns the links with an end in the region it is asked about,
-- so a link merely passing overhead is only found by asking the region its far
-- end sits in. A link is capped below one region in length, which is why one
-- ring of neighbours is enough to catch every one of them.
local function links_near_chunk(minp, maxp)
  if not perfectworld.roads or not perfectworld.roads.plan_links then return {} end
  local rx_min, rz_min = perfectworld.get_region_coords(minp)
  local rx_max, rz_max = perfectworld.get_region_coords(maxp)
  local seen, found = {}, {}
  for rx = rx_min - 1, rx_max + 1 do
    for rz = rz_min - 1, rz_max + 1 do
      for _, link in ipairs(perfectworld.roads.plan_links(rx, rz)) do
        if not seen[link.id] then
          seen[link.id] = true
          found[#found + 1] = link
        end
      end
    end
  end
  table.sort(found, function(a, b) return a.id < b.id end)
  return found
end

perfectworld.planner._links_near_chunk = links_near_chunk

--- Ground that already has a building on it.
--
-- A link is drawn to the middle of the settlement it serves, because that is
-- where the anchor is; what it must actually do on arrival is stop at the
-- houses and let the village's own streets take over.
local function standing_buildings(minp, maxp)
  local rx_min, rz_min = perfectworld.get_region_coords(minp)
  local rx_max, rz_max = perfectworld.get_region_coords(maxp)
  local coord_tag = perfectworld.core.coord_tag
  local boxes = {}

  -- Only the regions around this chunk. A settlement's structures are stored in
  -- its own region's shard, and a settlement near a border can spill one region
  -- over, so one ring of neighbours covers everything that could stand here.
  local visited = {}
  for rx = rx_min - 1, rx_max + 1 do
    for rz = rz_min - 1, rz_max + 1 do
      local shard = coord_tag(rx) .. "_" .. coord_tag(rz)
      if not visited[shard] then
        visited[shard] = true
        for _, record in pairs(store.region("structures", shard)) do
          if record and record.status == "materialized"
            and record.footprint_min and record.footprint_max then
            local low, high = record.footprint_min, record.footprint_max
            if low.x - 1 <= maxp.x and high.x + 1 >= minp.x
              and low.z - 1 <= maxp.z and high.z + 1 >= minp.z then
              boxes[#boxes + 1] = {
                min_x = low.x - 1, max_x = high.x + 1,
                min_z = low.z - 1, max_z = high.z + 1,
              }
            end
          end
        end
      end
    end
  end
  if #boxes == 0 then return nil end
  return function(x, z)
    for _, box in ipairs(boxes) do
      if x >= box.min_x and x <= box.max_x
        and z >= box.min_z and z <= box.max_z then
        return true
      end
    end
    return false
  end
end

perfectworld.planner._standing_buildings = standing_buildings


--- Put the settlement's name where somebody arriving would read it.
--
-- At every way in, not at one of them. A settlement joined to three neighbours
-- has three roads arriving and a traveller comes down whichever one they were
-- already on; a single sign at a nominal front gate is a sign nobody sees.
--
-- The sign goes beside the carriageway rather than on it, at the point where
-- the road crosses into the settlement, facing back down the road — which is
-- the direction the reader is coming from.
local SIGN_MARGIN = 10

local function sign_node_name()
  -- Whatever wood this game registered signs in. Asking rather than naming one
  -- means a game with different trees still gets signs.
  for name, _ in pairs(minetest.registered_nodes) do
    if name:match("^mcl_signs:standing_sign_") then return name end
  end
  return nil
end

function perfectworld.planner.signpost_settlement(candidate, profile, bounds, ways, name)
  if type(bounds) ~= "table" or not bounds.min_x or not name then
    return {placed = 0}
  end
  local sign = sign_node_name()
  if not sign then return {placed = 0, reason = "no_sign_node"} end

  local low_x = bounds.min_x - SIGN_MARGIN
  local high_x = bounds.max_x + SIGN_MARGIN
  local low_z = bounds.min_z - SIGN_MARGIN
  local high_z = bounds.max_z + SIGN_MARGIN

  local function inside(x, z)
    return x >= low_x and x <= high_x and z >= low_z and z <= high_z
  end

  local placed, seen = 0, {}
  for _, way in ipairs(ways or {}) do
    local points = way.path or way.points or {}
    -- Walk the way and find where it crosses the boundary. Both directions
    -- matter: a road that starts inside and leaves is the same entrance as one
    -- that arrives, and a settlement at the end of a road still has one.
    local previous_inside = nil
    local cells = {}
    for i = 1, #points - 1 do
      local from, to = points[i], points[i + 1]
      local dx, dz = to.x - from.x, to.z - from.z
      local steps = math.max(math.abs(dx), math.abs(dz), 1)
      for step = 0, steps do
        local t = step / steps
        cells[#cells + 1] = {
          x = math.floor(from.x + dx * t + 0.5),
          z = math.floor(from.z + dz * t + 0.5),
        }
      end
    end

    for index, cell in ipairs(cells) do
      local here = inside(cell.x, cell.z)
      if previous_inside ~= nil and here ~= previous_inside then
        -- A crossing. Put the sign one node to the side of the road, on the
        -- outside, so the traveller passes it rather than walks through it.
        local before = cells[math.max(index - 1, 1)]
        local after = cells[math.min(index + 1, #cells)]
        local dx, dz = after.x - before.x, after.z - before.z
        local length = math.sqrt(dx * dx + dz * dz)
        if length > 0.001 then
          local px = math.floor(cell.x - dz / length * 2 + 0.5)
          local pz = math.floor(cell.z + dx / length * 2 + 0.5)
          local key = math.floor(px / 8) .. ":" .. math.floor(pz / 8)
          if not seen[key] then
            seen[key] = true
            local ground = paving_level(px, pz)
            if ground then
              local above = minetest.get_node({x = px, y = ground + 1, z = pz}).name
              if above == "air" or above == "ignore" then
                minetest.set_node({x = px, y = ground + 1, z = pz},
                  {name = sign, param2 = 0})
                local meta = minetest.get_meta({x = px, y = ground + 1, z = pz})
                if mcl_signs and mcl_signs.string_to_ustring then
                  meta:set_string("utext",
                    minetest.serialize(mcl_signs.string_to_ustring(name)))
                end
                meta:set_string("text", name)
                meta:set_string("infotext", name)
                if mcl_signs and mcl_signs.update_sign then
                  mcl_signs.update_sign({x = px, y = ground + 1, z = pz})
                end
                placed = placed + 1
              end
            end
          end
        end
      end
      previous_inside = here
    end
  end

  return {placed = placed}
end

--- Ring a town with fields, outside its wall.
--
-- A town eats more than it can grow inside itself, and a walled town with
-- nothing but wall outside it reads as a fort. The fields go beyond the wall
-- because that is where farmland is when there is a wall — the ground inside is
-- worth too much to plant.
--
-- Each one is an ordinary `field` worksite, the same kind a farming village
-- gets, so it is fenced, watered, cropped and recorded exactly as those are and
-- nothing here needs to know how a field is built.
function perfectworld.planner.ring_town_with_fields(plan, profile, candidate, wall)
  if not wall then return {placed = 0, tried = 0} end
  local centre_x = (wall.min_x + wall.max_x) / 2
  local centre_z = (wall.min_z + wall.max_z) / 2
  -- Far enough out that a field's fence clears the wall, and its own nine by
  -- seven does not reach back over it.
  local reach = math.max(wall.max_x - centre_x, wall.max_z - centre_z) + 14

  -- One field for every three or four buildings, bounded. A ring of twenty
  -- fields is a farm with a town in the middle.
  local wanted = math.max(3, math.min(6, math.floor(#(plan.lots or {}) / 3)))
  local turn = choice.range(profile.seed_key, "town:fields:turn", 0, math.pi * 2)

  local placed, tried = 0, 0
  for index = 1, wanted do
    local angle = turn + (index - 1) * (math.pi * 2 / wanted)
    local x = math.floor(centre_x + math.cos(angle) * reach + 0.5)
    local z = math.floor(centre_z + math.sin(angle) * reach + 0.5)
    local y = paving_level(x, z)
    if y then
      tried = tried + 1
      local ok = perfectworld.planner.worksites.place("field", {
        worksite_id = candidate.id .. "_field_ring_" .. index,
        required = false,
        anchor = {x = x, y = y, z = z},
        candidate_anchors = {{x = x, y = y, z = z}},
        surface_y = function(px, pz) return paving_level(px, pz, y) end,
        palette = profile.material_palette,
        seed_key = profile.seed_key,
      })
      if ok then placed = placed + 1 end
    end
  end
  return {placed = placed, tried = tried, wanted = wanted}
end

--- Ring a town with a wall, leaving a gate wherever a way crosses it.
--
-- The wall follows the ground: each column is built from the surface up, so on
-- a slope it steps rather than floating or burying itself. Two nodes go below
-- the surface as well, because a wall whose foot sits exactly on the grass
-- lifts off the ground the moment anything erodes under it.
--
-- Gates are cut where a way passes, three wide and three high with a lintel
-- over them. Getting this wrong does not look wrong — it looks like a town —
-- and the symptom is that nobody can get in or out, which is why the ways
-- include the roads arriving from other settlements and not only the streets
-- inside.
function perfectworld.planner.build_town_wall(bounds, profile, ways)
  if type(bounds) ~= "table" or not bounds.min_x then return nil end
  local stone = perfectworld.structures.palette_material(
    profile.material_palette, "foundation", "foundation")
  local cap = perfectworld.structures.palette_material(
    profile.material_palette, "roof_slab", "roof")

  local margin = 8
  local height = 4
  local min_x = math.floor(bounds.min_x - margin)
  local max_x = math.ceil(bounds.max_x + margin)
  local min_z = math.floor(bounds.min_z - margin)
  local max_z = math.ceil(bounds.max_z + margin)

  -- Where the ways cross the line. A cell within two of a way's centreline is
  -- a gate cell, which makes the opening five wide for a road drawn straight
  -- and a little wider for one crossing at an angle — a road three wide needs
  -- more than three of gap to pass a wall without scraping it.
  local gate_cells = {}
  local gates = 0
  for _, way in ipairs(ways or {}) do
    local points = way.path or way.points or {}
    for i = 1, #points - 1 do
      local from, to = points[i], points[i + 1]
      local dx, dz = to.x - from.x, to.z - from.z
      local steps = math.max(math.abs(dx), math.abs(dz), 1)
      for step = 0, steps do
        local t = step / steps
        local x = math.floor(from.x + dx * t + 0.5)
        local z = math.floor(from.z + dz * t + 0.5)
        for ox = -2, 2 do
          for oz = -2, 2 do
            gate_cells[(x + ox) .. ":" .. (z + oz)] = true
          end
        end
      end
    end
  end

  -- Four walls, walked one at a time.
  --
  -- They used to be walked interleaved — south, north, south, north — with a
  -- single "am I still in the same opening" flag shared between them. The
  -- openings were always in the right place, cut where a road crosses and
  -- nowhere else; it was the count that was nonsense, and not in a consistent
  -- direction. Two roads leaving opposite sides of a town line up on the
  -- interleaved walk and were counted as one gate; openings that do not line up
  -- were counted once per cell. The guard detail is sized from that number.
  local walls = {{}, {}, {}, {}}
  for x = min_x, max_x do
    walls[1][#walls[1] + 1] = {x = x, z = min_z}
    walls[2][#walls[2] + 1] = {x = x, z = max_z}
  end
  for z = min_z + 1, max_z - 1 do
    walls[3][#walls[3] + 1] = {x = min_x, z = z}
    walls[4][#walls[4] + 1] = {x = max_x, z = z}
  end

  world_terrain.reset()
  local nodes = 0
  local gate_spots = {}
  for _, wall in ipairs(walls) do
  local in_gate = false
  for _, cell in ipairs(wall) do
    local ground = paving_level(cell.x, cell.z)
    if ground then
      local gate = gate_cells[cell.x .. ":" .. cell.z]
      if gate then
        if not in_gate then
          gates = gates + 1
          gate_spots[#gate_spots + 1] = {x = cell.x, y = ground, z = cell.z}
        end
        in_gate = true
        -- Clear the opening and put a lintel over it, so the wall reads as
        -- continuous rather than as two walls with a hole between them.
        for y = ground + 1, ground + 3 do
          local existing = minetest.get_node({x = cell.x, y = y, z = cell.z}).name
          if existing ~= "air" and existing ~= "ignore" then
            minetest.set_node({x = cell.x, y = y, z = cell.z}, {name = "air"})
          end
        end
        minetest.set_node({x = cell.x, y = ground + 4, z = cell.z}, {name = stone})
        nodes = nodes + 1
      else
        in_gate = false
        for depth = 0, 2 do
          minetest.set_node({x = cell.x, y = ground - depth, z = cell.z}, {name = stone})
        end
        for y = ground + 1, ground + height do
          minetest.set_node({x = cell.x, y = y, z = cell.z}, {name = stone})
          nodes = nodes + 1
        end
        if cap and cap ~= "air" then
          minetest.set_node({x = cell.x, y = ground + height + 1, z = cell.z}, {name = cap})
          nodes = nodes + 1
        end
      end
    end
  end
  end

  return {nodes = nodes, gates = gates, gate_spots = gate_spots,
    min_x = min_x, max_x = max_x,
    min_z = min_z, max_z = max_z, height = height}
end

--- Lay the stretch of every settlement link that crosses this chunk.
function perfectworld.planner.pave_links_in_chunk(minp, maxp)
  local result = {links = 0, segments = 0, nodes = 0, bridged = 0, unbridged = 0,
    tunnelled = 0, deepest_cut = 0, landings = 0}
  if perfectworld.materialization_enabled == false then return result end

  local blocked = standing_buildings(minp, maxp)
  world_terrain.reset()
  for _, link in ipairs(links_near_chunk(minp, maxp)) do
    local nodes, segments = 0, 0

    -- Cheap rejection first. Walking a link cell by cell means up to nine
    -- hundred columns, and most links near a chunk do not come near it.
    local worth_walking = false
    for i = 1, #link.points - 1 do
      if segment_touches_chunk(link.points[i], link.points[i + 1], minp, maxp) then
        worth_walking = true
        break
      end
    end

    local cells = worth_walking and link_centreline(link) or {}

    -- The run of cells this chunk is responsible for, widened so that the
    -- neighbouring chunk's run overlaps it rather than butting against it.
    local first, last = nil, nil
    for i = 1, #cells do
      local cell = cells[i]
      if cell.x >= minp.x - LINK_CHUNK_MARGIN and cell.x <= maxp.x + LINK_CHUNK_MARGIN
        and cell.z >= minp.z - LINK_CHUNK_MARGIN and cell.z <= maxp.z + LINK_CHUNK_MARGIN then
        first = first or i
        last = i
      end
    end

    if first then
      first = math.max(1, first - LINK_SEAM_OVERLAP)
      last = math.min(#cells, last + LINK_SEAM_OVERLAP)
      segments = 1
      local bridged, unbridged, deepest, tunnelled
      local landings
      nodes, bridged, unbridged, deepest, tunnelled, landings =
        pave_way(cells, first, last, {
          width = link.width or 1,
          surface = link.surface,
          blocked = blocked,
        })
      result.landings = (result.landings or 0) + (landings or 0)
      result.bridged = result.bridged + bridged
      result.unbridged = result.unbridged + unbridged
      result.tunnelled = (result.tunnelled or 0) + (tunnelled or 0)
      result.deepest_cut = math.max(result.deepest_cut or 0, deepest or 0)
    end

    if segments > 0 then
      result.links = result.links + 1
      result.segments = result.segments + segments
      result.nodes = result.nodes + nodes

      -- Record what exists, adding to whatever earlier chunks laid rather than
      -- replacing it: no single pass ever sees the whole road.
      local existing = perfectworld.planner.get_road(link.id)
      local record = deep_copy(link)
      record.path = link.points
      record.length = #link.points
      record.segment_count = math.max(#link.points - 1, 0)
      record.nodes_placed = (existing and existing.nodes_placed or 0) + nodes
      record.chunks_paved = (existing and existing.chunks_paved or 0) + 1
      perfectworld.planner.save_road(record)
    end
  end
  return result
end

function perfectworld.planner.materialize_chunk(minp, maxp)
	local rx_min, rz_min = perfectworld.get_region_coords(minp)
	local rx_max, rz_max = perfectworld.get_region_coords(maxp)
	local result = {
		attempted = 0,
		materialized = 0,
		queued = 0,
		skipped = {},
	}

	for rx = rx_min, rx_max do
		for rz = rz_min, rz_max do
			local plan = perfectworld.planner.plan_region(rx, rz)
			for _, candidate in ipairs(plan.settlement_candidates or {}) do
				candidate.region_id = plan.id
				if candidate.x >= minp.x and candidate.x <= maxp.x
				   and candidate.z >= minp.z and candidate.z <= maxp.z then
					if not perfectworld.planner.is_placed(candidate.id) then
						if perfectworld.planner.is_composite_candidate(candidate) then
							if perfectworld.planner.queue_village(candidate) then
								result.queued = result.queued + 1
							end
						else
							result.attempted = result.attempted + 1
							local ok, placed_or_reason = materialize_single_structure(candidate)
							if ok then
								result.materialized = result.materialized + 1
							else
								table.insert(result.skipped, {
									settlement_id = candidate.id,
									structure_id = candidate.structure_id,
									reason = placed_or_reason,
								})
								minetest.log("warning", "[pw_planner] skipped settlement " ..
									tostring(candidate.id) .. ": " .. tostring(placed_or_reason))
							end
						end
					end
				end
			end
		end
	end

	-- Roads last, so the chunk's own buildings are standing and the paving
	-- stops at them rather than through them.
	result.roads = perfectworld.planner.pave_links_in_chunk(minp, maxp)
	return result
end

minetest.register_on_generated(function(minp, maxp)
	perfectworld.planner.materialize_chunk(minp, maxp)
end)

minetest.log("action", "[pw_planner] loaded")
