perfectworld = perfectworld or {}
perfectworld.planner = perfectworld.planner or {}

local REGION_SIZE = perfectworld.REGION_SIZE
local MARGIN = 80
local MIN_DISTANCE = 200
local cache = {}
local storage = minetest.get_mod_storage()
local PLACED_KEY = "pw_placed_settlements"
local STRUCTURES_KEY = "pw_materialized_structures"
local SETTLEMENTS_KEY = "pw_settlement_plans"
local ROADS_KEY = "pw_roads"

local deep_copy = perfectworld.core.deep_copy
local choice = perfectworld.core.choice

local function read_json(key)
	local raw = storage:get_string(key)
	if raw and raw ~= "" then
		local ok, data = pcall(minetest.parse_json, raw)
		if ok and type(data) == "table" then
			return data
		end
	end
	return {}
end

local function write_json(key, data)
	storage:set_string(key, minetest.write_json(data))
end

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

	local num_candidates = choice.weighted(seed_key, "candidate_count", {
		{value = 0, weight = 20},
		{value = 1, weight = 50},
		{value = 2, weight = 30},
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

		local stype = choice.weighted(seed_key, "candidate:" .. i .. ":type", {
			{value = "farm", weight = 40},
			{value = "hamlet", weight = 40},
			{value = "village", weight = 20},
		})

		local priority
		if stype == "farm" then
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 1, 2)
		elseif stype == "hamlet" then
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 2, 4)
		else
			priority = choice.int(seed_key, "candidate:" .. i .. ":priority", 4, 5)
		end

		local candidate_id = perfectworld.core.settlement_id(rx, rz, i)
		local structure_id = perfectworld.core.structure_id(candidate_id, 0)
		local rotation = choice.pick(seed_key, "candidate:" .. i .. ":rotation", {0, 90, 180, 270})

		local structure_name
		if stype == "village" then
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
	return read_json(PLACED_KEY)[settlement_id] == true
end

function perfectworld.planner.mark_placed(settlement_id)
	local data = read_json(PLACED_KEY)
	data[settlement_id] = true
	write_json(PLACED_KEY, data)
end

function perfectworld.planner.list_placed()
	local data = read_json(PLACED_KEY)
	local ids = {}
	for id, _ in pairs(data) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function perfectworld.planner._test_unmark_placed(settlement_id)
	local data = read_json(PLACED_KEY)
	data[settlement_id] = nil
	write_json(PLACED_KEY, data)
end

-- === Structure Tracking ===

function perfectworld.planner.record_structure(record)
	local data = read_json(STRUCTURES_KEY)
	data[record.structure_id] = deep_copy(record)
	write_json(STRUCTURES_KEY, data)
end

function perfectworld.planner.save_structure(structure_id, record)
	local data = read_json(STRUCTURES_KEY)
	data[structure_id] = deep_copy(record)
	write_json(STRUCTURES_KEY, data)
end

function perfectworld.planner.get_structure(structure_id)
	return deep_copy(read_json(STRUCTURES_KEY)[structure_id])
end

function perfectworld.planner.list_structures()
	local data = read_json(STRUCTURES_KEY)
	local ids = {}
	for id, _ in pairs(data) do
		table.insert(ids, id)
	end
	table.sort(ids)
	local out = {}
	for _, id in ipairs(ids) do
		table.insert(out, deep_copy(data[id]))
	end
	return out
end

function perfectworld.planner._test_clear_structure(structure_id)
	local data = read_json(STRUCTURES_KEY)
	data[structure_id] = nil
	write_json(STRUCTURES_KEY, data)
end

-- === Settlement Plan Persistence ===

function perfectworld.planner.save_settlement_plan(settlement_id, plan)
	local data = read_json(SETTLEMENTS_KEY)
	data[settlement_id] = deep_copy(plan)
	write_json(SETTLEMENTS_KEY, data)
end

function perfectworld.planner.get_settlement_plan(settlement_id)
	return deep_copy(read_json(SETTLEMENTS_KEY)[settlement_id])
end

function perfectworld.planner.list_settlements()
	local data = read_json(SETTLEMENTS_KEY)
	local ids = {}
	for id, _ in pairs(data) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function perfectworld.planner._test_clear_settlement(settlement_id)
	local data = read_json(SETTLEMENTS_KEY)
	data[settlement_id] = nil
	write_json(SETTLEMENTS_KEY, data)
end

-- === Road Persistence ===

function perfectworld.planner.save_road(road)
	local data = read_json(ROADS_KEY)
	data[road.id] = deep_copy(road)
	write_json(ROADS_KEY, data)
end

function perfectworld.planner.get_road(road_id)
	return deep_copy(read_json(ROADS_KEY)[road_id])
end

function perfectworld.planner.list_roads()
	local data = read_json(ROADS_KEY)
	local ids = {}
	for id, _ in pairs(data) do
		table.insert(ids, id)
	end
	table.sort(ids)
	local out = {}
	for _, id in ipairs(ids) do
		table.insert(out, deep_copy(data[id]))
	end
	return out
end

-- === Cache Management ===

function perfectworld.planner._test_clear_cache()
	cache = {}
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

local ARCHETYPES = {"linear", "compact", "hillside"}
perfectworld.planner.ARCHETYPES = ARCHETYPES

-- Roles a lot can carry. `dwelling` is the only role a finished settlement
-- must contain (at least MIN_DWELLINGS of them).
local ROLE_ORDER = {"dwelling", "farm", "utility", "central", "optional"}
local MIN_DWELLINGS = 2
perfectworld.planner.ROLE_ORDER = ROLE_ORDER
perfectworld.planner.MIN_DWELLINGS = MIN_DWELLINGS

local ROLE_VARIANTS = {
  dwelling = {"pw_house_small_v1", "pw_house_small_v2"},
  farm = {"pw_farmstead_v1"},
  utility = {"pw_barn_v1", "pw_well_v1"},
  central = {"pw_well_v1"},
  optional = {"pw_house_small_v1", "pw_house_small_v2", "pw_barn_v1", "pw_well_v1"},
}

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

  function terrain.surface_y(x, z)
    local key = x .. ":" .. z
    local cached = cache[key]
    if cached ~= nil then
      if cached == false then return nil end
      return cached
    end
    for y = 200, -32, -1 do
      local node = minetest.get_node({x = x, y = y, z = z})
      if node.name ~= "air" and node.name ~= "ignore" then
        cache[key] = y
        return y
      end
    end
    cache[key] = false
    return nil
  end

  function terrain.is_liquid(x, z)
    local y = terrain.surface_y(x, z)
    if not y then return false end
    local name = minetest.get_node({x = x, y = y, z = z}).name
    return name:find("water") ~= nil or name:find("lava") ~= nil
  end

  function terrain.reset()
    cache = {}
  end

  return terrain
end

--- Deterministic synthetic terrain for tests and for probing layout rules.
-- `spec` fields: base, slope_x, slope_z, relief, water_line, seed_key.
function perfectworld.planner.make_synthetic_terrain(spec)
  spec = spec or {}
  local base = spec.base or 32
  local slope_x = spec.slope_x or 0
  local slope_z = spec.slope_z or 0
  local relief = spec.relief or 0
  local water_line = spec.water_line
  local seed_key = spec.seed_key or "synthetic"
  local cache = {}
  local terrain = {kind = "synthetic", spec = spec}

  function terrain.surface_y(x, z)
    local key = x .. ":" .. z
    local cached = cache[key]
    if cached == nil then
      local height = base + x * slope_x + z * slope_z
      if relief > 0 then
        height = height + math.floor(
          perfectworld.core.choice.range(seed_key, "relief:" .. x .. ":" .. z, -relief, relief))
      end
      cached = math.floor(height)
      cache[key] = cached
    end
    return cached
  end

  function terrain.is_liquid(x, z)
    if not water_line then return false end
    return terrain.surface_y(x, z) <= water_line
  end

  function terrain.reset() end

  return terrain
end

local world_terrain = make_world_terrain()
perfectworld.planner._world_terrain = world_terrain

-- === Seed key ===
-- Depends only on world seed, region, candidate identity and planner version,
-- exactly as documented in docs/development.md. Terrain influences the plan
-- through decision *weights*, never through the seed.

-- `world_seed_override` exists so the diversity harness can probe the
-- "different world seed" axis without regenerating the map. Normal generation
-- never sets it.
local function village_seed_key(candidate)
  return table.concat({
    "pwv2",
    candidate.world_seed_override or perfectworld.world_seed_string,
    "v" .. tostring(perfectworld.PLANNER_VERSION),
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

-- === Village Profile ===

function perfectworld.planner.create_village_profile(candidate, environment)
  local seed_key = village_seed_key(candidate)
  local profile = {
    village_id = candidate.id,
    generator_version = perfectworld.PLANNER_VERSION,
    environment = environment,
    seed_key = seed_key,
    seed_hash = hash32(seed_key),
  }

  profile.archetype = select_archetype(seed_key, environment)

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

  local branches
  if profile.archetype == "compact" then
    branches = choice.int(seed_key, "road:branches:compact", 1, 2)
  else
    branches = choice.bool(seed_key, "road:branches:linear", 0.4) and 1 or 0
  end
  profile.road_character = {
    main_length = choice.int(seed_key, "road:main_length", 30, 80),
    branches = branches,
    curve = choice.range(seed_key, "road:curve", 0, 0.30),
    crossing = choice.bool(seed_key, "road:crossing", 0.35),
    direction_index = choice.index(seed_key, "road:main:direction", 8),
  }

  profile.lot_spacing = {
    min_gap = choice.int(seed_key, "spacing:min_gap", 6, 10),
    max_gap = choice.int(seed_key, "spacing:max_gap", 10, 16),
    depth = choice.int(seed_key, "spacing:depth", 6, 10),
    set_back = choice.int(seed_key, "spacing:set_back", 3, 5),
  }
  if profile.lot_spacing.max_gap <= profile.lot_spacing.min_gap then
    profile.lot_spacing.max_gap = profile.lot_spacing.min_gap + 4
  end

  -- Role composition. Mandatory roles come first so that, when terrain trims
  -- the lot list, the surviving lots are the ones the contract requires.
  local roles = {}
  local remaining = profile.target_lots
  local dwellings = MIN_DWELLINGS
  if profile.size_class == "large" then
    dwellings = dwellings + choice.int(seed_key, "roles:extra_dwellings", 0, 2)
  elseif profile.size_class == "medium" then
    dwellings = dwellings + choice.int(seed_key, "roles:extra_dwellings", 0, 1)
  end
  dwellings = math.min(dwellings, remaining)
  for _ = 1, dwellings do table.insert(roles, "dwelling") end
  remaining = remaining - dwellings

  if remaining >= 2 and choice.bool(seed_key, "roles:farm", 0.8) then
    table.insert(roles, "farm")
    remaining = remaining - 1
  end
  if remaining >= 2 then
    table.insert(roles, "utility")
    remaining = remaining - 1
  end
  if profile.size_class ~= "small" and remaining >= 1 then
    table.insert(roles, "central")
    remaining = remaining - 1
  end
  while remaining > 0 do
    table.insert(roles, "optional")
    remaining = remaining - 1
  end
  profile.structure_roles = roles

  profile.required_roles = {"dwelling"}
  profile.optional_roles = {}
  do
    local seen = {dwelling = true}
    for _, role in ipairs(roles) do
      if not seen[role] then
        seen[role] = true
        table.insert(profile.optional_roles, role)
      end
    end
  end

  local family = environment.biome_family or "temperate"
  local palette = perfectworld.compat.get_family_palette(family)
  if not palette then
    family = "temperate"
    palette = perfectworld.compat.get_family_palette(family)
  end
  profile.material_palette = palette
  profile.palette_id = family

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

  if profile.archetype == "linear" then
    table.insert(roads, {
      id = road_id("main", 1),
      points = main_points("road:main", mdx, mdz, -half, half, curve),
      width = 3,
      kind = "main_street",
    })

  elseif profile.archetype == "compact" then
    table.insert(roads, {
      id = road_id("main", 1),
      points = main_points("road:main", mdx, mdz, -half, half, curve * 0.5),
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
    for b = 1, branches do
      local label = "road:branch:" .. b
      local turn = choice.pick(seed_key, label .. ":turn", {-1, 1})
      local bdx, bdz = -mdz * turn, mdx * turn
      local b_len = choice.int(seed_key, label .. ":length", 14, 34)
      local anchor = choice.int(seed_key, label .. ":anchor", -half + 4, half - 4)
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

  -- Drop degenerate roads (fewer than two distinct points).
  local cleaned = {}
  for _, road in ipairs(roads) do
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
    local half_w = math.floor((road.width or 2) / 2)
    for i = 1, #road.points - 1 do
      local p1, p2 = road.points[i], road.points[i + 1]
      local steps = math.max(math.abs(p2.x - p1.x), math.abs(p2.z - p1.z), 1)
      for s = 0, steps do
        local t = s / steps
        local rx = math.floor(p1.x + (p2.x - p1.x) * t + 0.5)
        local rz = math.floor(p1.z + (p2.z - p1.z) * t + 0.5)
        for ox = -half_w, half_w do
          for oz = -half_w, half_w do
            cells[(rx + ox) .. ":" .. (rz + oz)] = true
          end
        end
      end
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

--- Is the ground at this anchor usable for a lot?
local function terrain_verdict(anchor, max_slope, terrain)
  local cx, cz = anchor.center.x, anchor.center.z
  local base = terrain.surface_y(cx, cz)
  if not base then return false, "no_surface" end
  if terrain.is_liquid(cx, cz) then return false, "water" end

  local min_y, max_y = base, base
  for dx = -3, 3, 3 do
    for dz = -3, 3, 3 do
      if terrain.is_liquid(cx + dx, cz + dz) then return false, "water" end
      local y = terrain.surface_y(cx + dx, cz + dz)
      if y then
        min_y = math.min(min_y, y)
        max_y = math.max(max_y, y)
      end
    end
  end
  local slope = max_y - min_y
  if slope > max_slope then return false, "slope" end
  return true, nil, base, slope
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

--- Exact plan signature: full normalised geometry, no quantisation.
local function exact_plan_signature(plan)
  local center = plan.center
  local parts = {
    "exact1",
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
  for _, role in ipairs(ROLE_ORDER) do
    if role_counts[role] then table.insert(roles, role .. "x" .. role_counts[role]) end
  end
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
    "struct1",
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
  -- than the flat archetypes.
  local hillside = profile.archetype == "hillside"
  local lot_max_slope = hillside and 6 or 4
  local terrain_overrides = hillside
    and {max_slope = 6, max_cut_depth = 5, max_fill_height = 4, foundation_depth = 4}
    or nil

  local anchors = lot_anchors(seed_key, roads, profile)
  local lots = {}
  local role_index = 0

  for anchor_index, anchor in ipairs(anchors) do
    if #lots >= profile.target_lots then break end

    local ok, reason = terrain_verdict(anchor, lot_max_slope, terrain)
    if not ok then
      reject(reason)
    else
      local role = profile.structure_roles[role_index + 1]
      if not role then break end
      local structure_name = choice.pick(seed_key,
        "lot:" .. anchor_index .. ":variant", ROLE_VARIANTS[role] or ROLE_VARIANTS.dwelling)
      local def = perfectworld.structures.get(structure_name)
      if not def then
        reject("unknown_structure")
      else
        local origin = {x = anchor.center.x, y = 0, z = anchor.center.z}
        local rotation = orient_to_road(def, origin, anchor.road_point,
          seed_key, "lot:" .. anchor_index .. ":rotation")
        local fp_min, fp_max = perfectworld.structures.get_footprint(def, origin, rotation)

        local blocked = false
        for _, other in ipairs(lots) do
          if rect_overlaps(fp_min, fp_max, other.footprint_min, other.footprint_max) then
            blocked = true
            reject("lot_overlap")
            break
          end
        end

        if not blocked then
          -- A road must never run through a building.
          for x = fp_min.x - 1, fp_max.x + 1 do
            for z = fp_min.z - 1, fp_max.z + 1 do
              if road_cells[x .. ":" .. z] then
                blocked = true
                break
              end
            end
            if blocked then break end
          end
          if blocked then reject("road_conflict") end
        end

        if not blocked then
          role_index = role_index + 1
          table.insert(lots, {
            index = role_index,
            anchor_index = anchor_index,
            center = {x = anchor.center.x, z = anchor.center.z},
            road_point = anchor.road_point,
            road_id = anchor.road_id,
            side = anchor.side,
            role = role,
            structure_name = structure_name,
            rotation = rotation,
            footprint_min = fp_min,
            footprint_max = fp_max,
          })
        end
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
    local half_w = math.floor((road.width or 2) / 2)
    for _, pt in ipairs(road.points) do
      extend(pt.x - half_w, pt.z - half_w)
      extend(pt.x + half_w, pt.z + half_w)
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

  local plan = {
    village_id = profile.village_id,
    generator_version = profile.generator_version,
    seed_key = seed_key,
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
    rejections = rejections,
    viable = #lots > 0 and (role_counts.dwelling or 0) >= MIN_DWELLINGS,
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
  local environment
  if terrain then
    environment = {
      biome_id = "synthetic", biome_name = "synthetic", biome_family = "temperate",
      heat = 50, humidity = 50,
      elevation = terrain.surface_y(candidate.x, candidate.z) or 0,
      roughness = 0, average_slope = 0, water_proximity = 999, vegetation_density = 0,
      available_material_profile = "temperate",
    }
  else
    world_terrain.reset()
    local center = {x = candidate.x, y = 0, z = candidate.z}
    if minetest.load_area then
      pcall(minetest.load_area,
        {x = center.x - 70, y = -32, z = center.z - 70},
        {x = center.x + 70, y = 200, z = center.z + 70})
    end
    local surface = world_terrain.surface_y(center.x, center.z)
    environment = perfectworld.compat.get_environment({x = center.x, y = surface or 0, z = center.z})
  end
  if type(env_override) == "table" then
    for key, value in pairs(env_override) do environment[key] = value end
  end
  local profile = perfectworld.planner.create_village_profile(candidate, environment)
  local plan = perfectworld.planner.build_village_plan(candidate, profile, environment, terrain)
  return plan, profile, environment
end

--- Emerge (generate if needed) the map area a village plan will inspect.
-- minetest.load_area only loads already-generated blocks, so a village planned
-- near the edge of the generated world would see no terrain at all.
function perfectworld.planner.emerge_village_area(candidate, callback)
  local radius = 72
  local minp = {x = candidate.x - radius, y = -16, z = candidate.z - radius}
  local maxp = {x = candidate.x + radius, y = 144, z = candidate.z + radius}
  if not minetest.emerge_area then
    callback()
    return
  end
  minetest.emerge_area(minp, maxp, function(_, _, calls_remaining)
    if calls_remaining == 0 then callback() end
  end)
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
  {name = "steep_slope", base = 60, slope_x = 0.38, slope_z = -0.12, relief = 1},
  {name = "rolling", base = 48, slope_x = 0.02, slope_z = 0.02, relief = 3},
  {name = "rough", base = 70, slope_x = 0.05, slope_z = -0.05, relief = 7},
  {name = "shoreline", base = 6, slope_x = 0.06, slope_z = 0, relief = 1, water_line = 3},
  {name = "submerged", base = 1, slope_x = 0, slope_z = 0, relief = 0, water_line = 8},
  {name = "cliff", base = 50, slope_x = 0.9, slope_z = 0, relief = 2},
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

--- Lay a road surface strip perpendicular to the direction of travel.
local function place_road_strip(p1, p2, width, material_name)
  local dx, dz = p2.x - p1.x, p2.z - p1.z
  local length = math.sqrt(dx * dx + dz * dz)
  if length < 0.001 then return 0 end
  local perp_x, perp_z = -dz / length, dx / length
  local half_w = math.floor(width / 2)
  local steps = math.max(math.abs(dx), math.abs(dz), 1)
  local placed = 0
  for s = 0, steps do
    local t = s / steps
    local bx = p1.x + dx * t
    local bz = p1.z + dz * t
    for w = -half_w, half_w do
      local px = math.floor(bx + perp_x * w + 0.5)
      local pz = math.floor(bz + perp_z * w + 0.5)
      local y = world_terrain.surface_y(px, pz)
      if y then
        local node = minetest.get_node({x = px, y = y, z = pz})
        if node.name ~= material_name and not node.name:find("water") then
          minetest.set_node({x = px, y = y, z = pz}, {name = material_name})
          placed = placed + 1
        end
      end
    end
  end
  return placed
end

local function materialize_village_plan(plan, profile, candidate)
  if perfectworld.planner.is_placed(candidate.id) then
    return true, {reason = "already_placed", settlement_id = candidate.id}
  end

  local palette = profile.material_palette
  local road_material = perfectworld.structures.palette_material(palette, "path", "road")
  local placed_structures = {}
  local placed_roads = {}
  local errors = {}

  -- Structures first: terrain preparation reshapes the surface, and doing it
  -- after the roads were laid would bury or erase them.
  for _, lot in ipairs(plan.lots) do
    local def = perfectworld.structures.get(lot.structure_name)
    if not def then
      table.insert(errors, "structure_not_found:" .. tostring(lot.structure_name))
    else
      local structure_id = candidate.id .. "_struct_" .. (#placed_structures + 1)
      local ctx = {
        structure_id = structure_id,
        pos = {x = lot.center.x, y = 0, z = lot.center.z},
        rotation = lot.rotation,
        region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
        settlement_id = candidate.id,
        palette = palette,
        terrain_overrides = plan.terrain_overrides,
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
  world_terrain.reset()
  for _, road in ipairs(plan.roads) do
    local nodes = 0
    for i = 1, #road.points - 1 do
      nodes = nodes + place_road_strip(road.points[i], road.points[i + 1], road.width or 2, road_material)
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
      place_road_strip(door, lot.road_point, 1, road_material)
      lot.door = door
    end
  end

  -- Completion contract.
  local placed_roles = {}
  for _, s in ipairs(placed_structures) do
    placed_roles[s.role] = (placed_roles[s.role] or 0) + 1
  end
  local missing_required = {}
  if (placed_roles.dwelling or 0) < MIN_DWELLINGS then
    table.insert(missing_required, "dwelling<" .. MIN_DWELLINGS)
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
  for _, s in ipairs(placed_structures) do
    if s.position then
      bounds.min_x = math.min(bounds.min_x, s.position.x)
      bounds.max_x = math.max(bounds.max_x, s.position.x)
      bounds.min_z = math.min(bounds.min_z, s.position.z)
      bounds.max_z = math.max(bounds.max_z, s.position.z)
    end
  end

  local settlement_record = {
    settlement_id = candidate.id,
    candidate_id = candidate.id,
    region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
    generator_version = profile.generator_version,
    seed_key = profile.seed_key,
    status = settlement_status,
    center_pos = {x = candidate.x, y = world_terrain.surface_y(candidate.x, candidate.z) or 0, z = candidate.z},
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
    road_segment_count = 0,
    lot_count = #placed_structures,
    planned_lot_count = #plan.lots,
    errors = errors,
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

  perfectworld.planner.save_settlement_plan(candidate.id, {
    plan = plan,
    profile = profile,
    settlement = settlement_record,
  })
  perfectworld.planner.mark_placed(candidate.id)

  return true, {
    settlement = settlement_record,
    structures = placed_structures,
    roads = placed_roads,
    errors = errors,
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
  if not plan.viable then
    -- Never persist an unbuildable settlement as a real one.
    local record = {
      settlement_id = candidate.id,
      candidate_id = candidate.id,
      region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
      generator_version = profile.generator_version,
      status = "failed",
      reason = "no_viable_layout",
      rejections = plan.rejections,
      center_pos = {x = candidate.x, y = 0, z = candidate.z},
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
      lot_count = 0,
      planned_lot_count = #plan.lots,
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
  report.status = settlement.status
  report.archetype = settlement.archetype
  report.lot_count = settlement.lot_count

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

  local road_cells = {}
  for _, road in ipairs(roads) do
    local half_w = math.floor((road.width or 2) / 2)
    local points = road.path or {}
    for i = 1, #points - 1 do
      local p1, p2 = points[i], points[i + 1]
      local steps = math.max(math.abs(p2.x - p1.x), math.abs(p2.z - p1.z), 1)
      for s = 0, steps do
        local t = s / steps
        local rx = math.floor(p1.x + (p2.x - p1.x) * t + 0.5)
        local rz = math.floor(p1.z + (p2.z - p1.z) * t + 0.5)
        for ox = -half_w, half_w do
          for oz = -half_w, half_w do
            road_cells[(rx + ox) .. ":" .. (rz + oz)] = true
          end
        end
      end
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
    for dx = -4, 4 do
      for dz = -4, 4 do
        if road_cells[(door.x + dx) .. ":" .. (door.z + dz)] then reached = true break end
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
    for cell in pairs(road_cells) do
      local sx, sz = cell:match("^(-?%d+):(-?%d+)$")
      if sx and not inside(tonumber(sx), tonumber(sz)) then
        outside = outside or ("road@" .. cell)
      end
    end
    check("bounds_contain_all", outside == nil, outside)
  else
    check("bounds_present", false)
  end

  -- 6. the world actually contains the buildings
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
    -- ground must exist under every footprint corner
    for _, corner in ipairs({
      {x = box.min.x, z = box.min.z}, {x = box.max.x, z = box.min.z},
      {x = box.min.x, z = box.max.z}, {x = box.max.x, z = box.max.z},
      {x = math.floor((box.min.x + box.max.x) / 2), z = math.floor((box.min.z + box.max.z) / 2)},
    }) do
      local below = minetest.get_node({x = corner.x, y = origin.y - 1, z = corner.z})
      if below.name == "air" then
        floating = box.id .. "@" .. corner.x .. "," .. corner.z
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
			perfectworld.planner.record_structure(record)
			perfectworld.planner.mark_placed(sid)
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

function perfectworld.planner.materialize_chunk(minp, maxp)
	local rx_min, rz_min = perfectworld.get_region_coords(minp)
	local rx_max, rz_max = perfectworld.get_region_coords(maxp)
	local result = {
		attempted = 0,
		materialized = 0,
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
						result.attempted = result.attempted + 1
						local ok, placed_or_reason
						if perfectworld.planner.is_composite_candidate(candidate) then
							ok, placed_or_reason = materialize_village(candidate)
						else
							ok, placed_or_reason = materialize_single_structure(candidate)
						end
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
	return result
end

minetest.register_on_generated(function(minp, maxp)
	perfectworld.planner.materialize_chunk(minp, maxp)
end)

minetest.log("action", "[pw_planner] loaded")
