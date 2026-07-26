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

local function det_prng(seed)
	local state = seed
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local deep_copy = perfectworld.core.deep_copy

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

-- === Village Layout Planner ===
-- Generates a deterministic village layout: main street, plots on both sides,
-- building assignment, road connectors.

local function village_layout_seed(settlement_id, rx, rz)
	return perfectworld.core.stable_hash(table.concat({
		"village_layout", tostring(settlement_id), tostring(rx), tostring(rz),
	}, "|"))
end

local function village_prng(seed)
	local state = seed
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function pick_structure(prng, allowed)
	if #allowed == 0 then return nil end
	local idx = 1 + math.floor(prng() * #allowed)
	return allowed[idx]
end

local function get_road_connector(def, rotation)
	if not def or not def.connectors then return nil end
	for _, c in ipairs(def.connectors) do
		if c.type == "road" then
			local rotated = perfectworld.structures.rotate_connector(c, rotation)
			return rotated.offset_pos or {x = 0, y = 0, z = 0}
		end
	end
	return nil
end

-- Main village layout function
function perfectworld.village_plan_layout(settlement)
	local prng = village_prng(village_layout_seed(settlement.id, settlement.rx or 0, settlement.rz or 0))

	local cx = settlement.cx or settlement.x or 0
	local cz = settlement.cz or settlement.z or 0

	local street_rot_idx = 1 + math.floor(prng() * 4)
	local street_rot = ({0, 90, 180, 270})[street_rot_idx]

	local street_len = 40 + math.floor(prng() * 41)
	local street_width = 2

	local dx = ({0, 1, 0, -1})[street_rot_idx]
	local dz = ({1, 0, -1, 0})[street_rot_idx]
	local half_len = math.floor(street_len / 2)

	local street_start = {x = cx - dx * half_len, z = cz - dz * half_len}
	local street_end_ = {x = cx + dx * half_len, z = cz + dz * half_len}

	local num_plots = 4 + math.floor(prng() * 4)

	local residential = {"pw_house_small_v1", "pw_house_small_v2"}
	local farmyard = {"pw_barn_v1"}
	local public_structs = {"pw_well_v1"}

	local min_houses = 2
	local min_public = 1
	local placed_houses = 0
	local placed_public = 0

	local plots = {}
	local used_footprints = {}

	local plot_idx = 0
	local side = 1
	local offset_along = -half_len + 8

	while plot_idx < num_plots and offset_along < half_len - 8 do
		side = side * -1

		local perp_dx = ({0, -1, 0, 1})[street_rot_idx] * side
		local perp_dz = ({1, 0, -1, 0})[street_rot_idx] * side
		local perp_dist = 8 + math.floor(prng() * 7)

		local px = cx + dx * offset_along + perp_dx * perp_dist
		local pz = cz + dz * offset_along + perp_dz * perp_dist

		local btype, bname
		if placed_houses < min_houses then
			btype = "residential"
			bname = pick_structure(prng, residential)
			placed_houses = placed_houses + 1
		elseif placed_public < min_public and plot_idx >= num_plots - 2 then
			btype = "public"
			bname = pick_structure(prng, public_structs)
			placed_public = placed_public + 1
		else
			local roll = prng()
			if roll < 0.5 then
				btype = "residential"
				bname = pick_structure(prng, residential)
				placed_houses = placed_houses + 1
			elseif roll < 0.75 then
				btype = "farmyard"
				bname = pick_structure(prng, farmyard)
			else
				btype = "public"
				bname = pick_structure(prng, public_structs)
				placed_public = placed_public + 1
			end
		end

		if not bname then
			btype = "residential"
			bname = residential[1]
			placed_houses = placed_houses + 1
		end

		local def = perfectworld.structures.get(bname)
		if not def then
			offset_along = offset_along + 12
			goto village_continue
		end

		local plot_rot
		if dx == 0 and dz == 1 then plot_rot = 0
		elseif dx == 1 and dz == 0 then plot_rot = 90
		elseif dx == 0 and dz == -1 then plot_rot = 180
		elseif dx == -1 and dz == 0 then plot_rot = 270
		else plot_rot = 0 end

		local fp_minp, fp_maxp = perfectworld.structures.get_footprint(def, {x = px, y = 0, z = pz}, plot_rot)
		local overlaps = false
		for _, existing in ipairs(used_footprints) do
			if fp_minp.x <= existing.max_x and fp_maxp.x >= existing.min_x and
			   fp_minp.z <= existing.max_z and fp_maxp.z >= existing.min_z then
				overlaps = true
				break
			end
		end

		if not overlaps then
			plot_idx = plot_idx + 1
			local plot_id = settlement.id .. "_plot_" .. plot_idx

			local conn_offset = get_road_connector(def, plot_rot)
			local conn_world = {x = px, y = 0, z = pz}
			if conn_offset then
				local rotated = perfectworld.structures.rotate_point(conn_offset, plot_rot)
				conn_world = {x = px + rotated.x, y = 0, z = pz + rotated.z}
			end

			table.insert(plots, {
				id = plot_id,
				settlement_id = settlement.id,
				type = btype,
				center = {x = px, y = 0, z = pz},
				rotation = plot_rot,
				structure_name = bname,
				status = "planned",
				road_connector = conn_world,
			})

			table.insert(used_footprints, {
				min_x = fp_minp.x, max_x = fp_maxp.x,
				min_z = fp_minp.z, max_z = fp_maxp.z,
			})
		end

		offset_along = offset_along + 10 + math.floor(prng() * 6)
		::village_continue::
	end

	local ext_conn = {
		x = street_start.x + math.floor(dx * 3),
		y = 0,
		z = street_start.z + math.floor(dz * 3),
	}

	return {
		center = {x = cx, z = cz},
		rotation = street_rot,
		plots = plots,
		street = {
			start = street_start,
			end_ = street_end_,
			width = street_width,
			direction = {x = dx, z = dz},
		},
		external_connector = ext_conn,
	}
end

-- Forward declarations for terrain helpers (defined below, used by village_materialize)
local quick_slope_check, find_farm_location, flatten_farm_site, build_road

-- Materialize a village layout
function perfectworld.village_materialize(layout)
	local result = {
		plots_placed = 0,
		plots_skipped = 0,
		street_segments = 0,
		errors = {},
	}

	if not layout or not layout.plots then
		return result
	end

	-- Materialize street
	local street = layout.street
	if street then
		local sx, sz = street.start.x, street.start.z
		local ex, ez = street.end_.x, street.end_.z
		local w = street.width or 2

		local steps = math.max(math.abs(ex - sx), math.abs(ez - sz))
		local road_mat = perfectworld.compat.get_material("road")

		for i = 0, steps do
			local t = steps > 0 and (i / steps) or 0
			local x = math.floor(sx + (ex - sx) * t)
			local z = math.floor(sz + (ez - sz) * t)

			for ox = -math.floor(w / 2), math.floor(w / 2) do
				for oz = -math.floor(w / 2), math.floor(w / 2) do
					local px = x + ox
					local pz = z + oz
					local surface_y = nil
					for y = 256, -64, -1 do
						local node = minetest.get_node({x = px, y = y, z = pz})
						if node.name ~= "air" and node.name ~= "ignore" then
							surface_y = y
							break
						end
					end
					if surface_y then
						minetest.set_node({x = px, y = surface_y, z = pz}, {name = road_mat})
					end
				end
			end
		end
		result.street_segments = steps
	end

	-- Materialize plots
	for _, plot in ipairs(layout.plots) do
		if plot.status ~= "planned" then
			goto plot_continue
		end

		local def = perfectworld.structures.get(plot.structure_name)
		if not def then
			plot.status = "skipped"
			result.plots_skipped = result.plots_skipped + 1
			table.insert(result.errors, "structure not found: " .. tostring(plot.structure_name))
			goto plot_continue
		end

		local offsets = {
			{x = 0, z = 0},
			{x = 4, z = 0},
			{x = -4, z = 0},
			{x = 0, z = 4},
			{x = 0, z = -4},
		}

		local placed = false
		for _, off in ipairs(offsets) do
			local pos = {x = plot.center.x + off.x, y = 0, z = plot.center.z + off.z}
			local ctx = {
				structure_id = plot.id,
				pos = pos,
				rotation = plot.rotation,
				region_id = layout.region_id,
				settlement_id = plot.settlement_id,
			}
			if layout.skip_terrain_check then
				ctx.skip_terrain_check = true
			end
			local ok, res = perfectworld.structures.place(plot.structure_name, ctx)
			if ok then
				plot.status = "materialized"
				plot.position = res.position
				result.plots_placed = result.plots_placed + 1
				placed = true

				-- Place a short path from plot door to street
				if plot.road_connector and street then
					local pcx, pcz = plot.road_connector.x, plot.road_connector.z
					local sx, sz = street.start.x, street.start.z
					local path_steps = 8
					local road_mat = perfectworld.compat.get_material("road")
					for pi = 0, path_steps do
						local pt = path_steps > 0 and (pi / path_steps) or 0
						local path_x = math.floor(pcx + (sx - pcx) * pt)
						local path_z = math.floor(pcz + (sz - pcz) * pt)
						local psurface = nil
						for y = 256, -64, -1 do
							local node = minetest.get_node({x = path_x, y = y, z = path_z})
							if node.name ~= "air" and node.name ~= "ignore" then
								psurface = y
								break
							end
						end
						if psurface then
							minetest.set_node({x = path_x, y = psurface, z = path_z}, {name = road_mat})
						end
					end
				end

				break
			end
		end

		if not placed and not layout.skip_terrain_check then
			local building_half = 5
			if def.terrain and def.terrain.building_footprint then
				local bf = def.terrain.building_footprint
				building_half = math.max(math.abs(bf.min_x), math.abs(bf.max_x), math.abs(bf.min_z), math.abs(bf.max_z)) + 2
			end
			local air = "air"
			local ground_mat = perfectworld.compat.get_material("ground")
			local sy = 0
			for y = 256, -64, -1 do
				local node = minetest.get_node({x = plot.center.x, y = y, z = plot.center.z})
				if node.name ~= "air" and node.name ~= "ignore" then
					sy = y
					break
				end
			end
			for dx = -building_half, building_half do
				for dz = -building_half, building_half do
					local px, pz = plot.center.x + dx, plot.center.z + dz
					for y = sy + 10, sy, -1 do
						local node = minetest.get_node({x = px, y = y, z = pz})
						if node.name ~= "air" then
							minetest.set_node({x = px, y = y, z = pz}, {name = air})
						end
					end
					for y = sy, sy - 4, -1 do
						local node = minetest.get_node({x = px, y = y, z = pz})
						if node.name == "air" or node.name == "ignore" then
							minetest.set_node({x = px, y = y, z = pz}, {name = ground_mat})
						end
					end
					minetest.set_node({x = px, y = sy, z = pz}, {name = ground_mat})
				end
			end
			minetest.log("action", "[pw_planner] flattened plot at (" .. plot.center.x .. "," .. plot.center.z .. ")")
			local retry_ctx = {
				structure_id = plot.id,
				pos = {x = plot.center.x, y = 0, z = plot.center.z},
				rotation = plot.rotation,
				region_id = layout.region_id,
				settlement_id = plot.settlement_id,
				skip_terrain_check = true,
			}
			local ok, res = perfectworld.structures.place(plot.structure_name, retry_ctx)
			if ok then
				plot.status = "materialized"
				plot.position = res.position
				result.plots_placed = result.plots_placed + 1
				placed = true
			else
				minetest.log("warning", "[pw_planner] flatten retry failed for " .. tostring(plot.id) .. ": " .. tostring(res and res.reason or res))
			end
		end

		if not placed then
			plot.status = "skipped"
			result.plots_skipped = result.plots_skipped + 1
		end

		::plot_continue::
	end

	return result
end

-- Shorthand aliases used by materialize_village
perfectworld.village = perfectworld.village or {}
perfectworld.village.plan_layout = perfectworld.village_plan_layout
perfectworld.village.materialize = perfectworld.village_materialize

-- === Region Planning ===

function perfectworld.planner.plan_region(rx, rz)
	local cache_key = rx .. "_" .. rz
	local cached = cache[cache_key]
	if cached then
		return deep_copy(cached)
	end

	local base_seed = perfectworld.region_seed(rx, rz, perfectworld.PLANNER_VERSION)
	local prng = det_prng(base_seed + perfectworld.PLANNER_VERSION * 1000003)

	local minp = {x = rx * REGION_SIZE, y = -64, z = rz * REGION_SIZE}
	local maxp = {x = (rx + 1) * REGION_SIZE - 1, y = 256, z = (rz + 1) * REGION_SIZE - 1}

	local settlement_candidates = {}
	local reserved_areas = {}
	local road_anchors = {}

	local r = prng()
	local num_candidates
	if r < 0.2 then
		num_candidates = 0
	elseif r < 0.7 then
		num_candidates = 1
	else
		num_candidates = 2
	end

	for i = 0, num_candidates - 1 do
		local x, z
		local valid = false
		for _attempt = 1, 50 do
			x = minp.x + MARGIN + math.floor(prng() * (REGION_SIZE - 2 * MARGIN))
			z = minp.z + MARGIN + math.floor(prng() * (REGION_SIZE - 2 * MARGIN))

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

		local type_roll = prng()
		local stype
		if type_roll < 0.4 then
			stype = "farm"
		elseif type_roll < 0.8 then
			stype = "hamlet"
		else
			stype = "village"
		end

		local priority
		if stype == "farm" then
			priority = 1 + math.floor(prng() * 2)
		elseif stype == "hamlet" then
			priority = 2 + math.floor(prng() * 3)
		else
			priority = 4 + math.floor(prng() * 2)
		end

		local candidate_id = perfectworld.core.settlement_id(rx, rz, i)
		local structure_id = perfectworld.core.structure_id(candidate_id, 0)
		local rotation = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]

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
-- Deterministic multi-structure settlement generation with biome-aware profiles,
-- multiple archetypes, and a grammar-based planning pipeline.

-- Stable PRNG: deterministic hash-based random for village generation.
-- Different seeds produce different sequences; same seed always produces same sequence.
local function village_prng_new(seed)
  local state = (seed % 2147483648)
  return function()
    state = (state * 1103515245 + 12345) % 2147483648
    return state / 2147483648
  end
end

-- Generate a deterministic seed from candidate and environment data.
local function village_seed(candidate, profile)
  local parts = {
    "village_v2",
    tostring(perfectworld.region_seed(candidate.rx or 0, candidate.rz or 0)),
    tostring(candidate.id),
    tostring(profile.biome_family or "unknown"),
    tostring(profile.roughness or 0),
    tostring(perfectworld.PLANNER_VERSION),
  }
  return perfectworld.core.stable_hash(table.concat(parts, "|"))
end

-- === Archetype Selection ===
-- Three archetypes with weighted selection based on terrain profile.

local archetypes = {"linear", "compact", "hillside"}

local function select_archetype(prng, profile)
  local roughness = profile.roughness or 0
  local water = profile.water_proximity or 999
  local family = profile.biome_family or "temperate"

  -- Weighted selection: [linear_weight, compact_weight, hillside_weight]
  local w_linear = 35
  local w_compact = 40
  local w_hillside = 25

  -- Hillside preference: rough terrain
  if roughness > 3 then
    w_hillside = w_hillside + 30
    w_compact = w_compact - 10
  end
  if roughness > 6 then
    w_hillside = w_hillside + 25
    w_linear = w_linear - 10
    w_compact = w_compact - 15
  end

  -- Linear preference: near water (along shore/river)
  if water < 20 then
    w_linear = w_linear + 25
    w_compact = w_compact - 10
  end

  -- Compact preference: dry/rocky open areas
  if family == "dry" or family == "rocky" then
    w_compact = w_compact + 15
  end

  local total = w_linear + w_compact + w_hillside
  local roll = prng() * total
  if roll < w_linear then return "linear"
  elseif roll < w_linear + w_compact then return "compact"
  else return "hillside" end
end

-- === Village Profile ===
-- Created once per candidate, deterministically from seed and environment.

function perfectworld.planner.create_village_profile(candidate, environment)
  local profile = {
    village_id = candidate.id,
    generator_version = perfectworld.PLANNER_VERSION,
    environment = environment,
    seed_key = village_seed(candidate, environment),
  }
  local prng = village_prng_new(profile.seed_key)
  profile.archetype = select_archetype(prng, environment)

  -- Size class: small (3-5), medium (5-8), large (8-12)
  local size_roll = prng()
  if size_roll < 0.3 then
    profile.size_class = "small"
    profile.target_lots = 3 + math.floor(prng() * 3)  -- 3-5
    profile.density = 0.3 + prng() * 0.15
  elseif size_roll < 0.8 then
    profile.size_class = "medium"
    profile.target_lots = 5 + math.floor(prng() * 4)  -- 5-8
    profile.density = 0.35 + prng() * 0.2
  else
    profile.size_class = "large"
    profile.target_lots = 8 + math.floor(prng() * 5)  -- 8-12
    profile.density = 0.4 + prng() * 0.25
  end

  -- Road character
  profile.road_character = {
    main_length = 30 + math.floor(prng() * 51),  -- 30-80
    branches = profile.archetype == "compact" and (1 + math.floor(prng() * 2)) or (prng() < 0.4 and 1 or 0),
    curve = prng() * 0.3,  -- 0-0.3 curvature factor
    crossing = prng() < 0.3,
  }

  -- Lot spacing
  profile.lot_spacing = {
    min_gap = 6 + math.floor(prng() * 5),
    max_gap = 10 + math.floor(prng() * 7),
    depth = 6 + math.floor(prng() * 5),
    set_back = 3 + math.floor(prng() * 3),
  }

  -- Structure roles allocation
  local remaining = profile.target_lots
  profile.structure_roles = {}
  -- Minimum 2 dwellings
  local dwellings = 2 + (profile.size_class == "large" and math.floor(prng() * 2) or 0)
  for _ = 1, dwellings do table.insert(profile.structure_roles, "dwelling") end
  remaining = remaining - dwellings
  -- 1 farm if enough lots
  if remaining >= 2 and prng() < 0.8 then
    table.insert(profile.structure_roles, "farm")
    remaining = remaining - 1
  end
  -- 1 utility if enough lots
  if remaining >= 2 then
    table.insert(profile.structure_roles, "utility")
    remaining = remaining - 1
  end
  -- 1 central/public if medium or larger
  if profile.size_class ~= "small" and remaining >= 1 then
    table.insert(profile.structure_roles, "central")
    remaining = remaining - 1
  end
  -- Fill remaining with optional/decorative
  while remaining > 0 do
    table.insert(profile.structure_roles, "optional")
    remaining = remaining - 1
  end
  -- Shuffle roles deterministically
  for i = #profile.structure_roles, 2, -1 do
    local j = 1 + math.floor(prng() * i)
    profile.structure_roles[i], profile.structure_roles[j] = profile.structure_roles[j], profile.structure_roles[i]
  end

  -- Material palette
  local palette = perfectworld.compat.get_family_palette(environment.biome_family)
  if not palette then
    palette = perfectworld.compat.get_family_palette("temperate")
  end
  profile.material_palette = palette

  -- Variation parameters for structure selection
  profile.variation_parameters = {
    dwelling_variant = 1 + math.floor(prng() * 2),  -- 1 or 2
    orientation_noise = prng() * 0.3,
    spacing_jitter = prng() * 0.4,
  }

  return profile
end

-- === Village Grammar: Road Network ===
-- Builds the road skeleton based on archetype.

local function build_road_network(prng, center, profile)
  local archetype = profile.archetype
  local roads = {}
  local road_id_counter = 0

  local function next_road_id(suffix)
    road_id_counter = road_id_counter + 1
    return profile.village_id .. "_road_" .. suffix .. "_" .. road_id_counter
  end

  local cx, cz = center.x, center.z
  local curve = profile.road_character.curve or 0
  local main_len = profile.road_character.main_length or 40
  local branches = profile.road_character.branches or 0

  if archetype == "linear" then
    -- One main street, possibly curved
    local angle = prng() * 2 * math.pi
    local dx = math.cos(angle)
    local dz = math.sin(angle)
    local half = math.floor(main_len / 2)
    local points = {}
    for i = -half, half, 2 do
      local px = cx + dx * i
      local pz = cz + dz * i
      if curve > 0 and i ~= 0 then
        local perp_x = -dz * curve * i * prng()
        local perp_z = dx * curve * i * prng()
        px = px + perp_x
        pz = pz + perp_z
      end
      table.insert(points, {x = math.floor(px), z = math.floor(pz)})
    end
    table.insert(roads, {
      id = next_road_id("main"),
      points = points,
      width = 2,
      kind = "main_street",
    })

  elseif archetype == "compact" then
    -- Crossroads or fork
    local main_angle = prng() * 2 * math.pi
    local mdx = math.cos(main_angle)
    local mdz = math.sin(main_angle)
    local half = math.floor(main_len / 2)
    local main_points = {}
    for i = -half, half, 2 do
      table.insert(main_points, {x = math.floor(cx + mdx * i), z = math.floor(cz + mdz * i)})
    end
    table.insert(roads, {
      id = next_road_id("main"),
      points = main_points,
      width = 2,
      kind = "main_street",
    })
    -- Crossing street
    if profile.road_character.crossing then
      local cross_half = math.floor(main_len * 0.5)
      local perp_angle = main_angle + math.pi / 2
      local pdx = math.cos(perp_angle)
      local pdz = math.sin(perp_angle)
      local cross_points = {}
      for i = -cross_half, cross_half, 2 do
        table.insert(cross_points, {x = math.floor(cx + pdx * i), z = math.floor(cz + pdz * i)})
      end
      table.insert(roads, {
        id = next_road_id("cross"),
        points = cross_points,
        width = 2,
        kind = "cross_street",
      })
    end
    -- Branch streets
    for b = 1, branches do
      local b_angle = main_angle + (prng() - 0.5) * math.pi * 0.8
      local bdx = math.cos(b_angle)
      local bdz = math.sin(b_angle)
      local b_len = 15 + math.floor(prng() * 20)
      local b_points = {}
      local bx = cx + mdx * half * (prng() * 0.6 - 0.3)
      local bz = cz + mdz * half * (prng() * 0.6 - 0.3)
      for i = 0, b_len, 2 do
        table.insert(b_points, {x = math.floor(bx + bdx * i), z = math.floor(bz + bdz * i)})
      end
      table.insert(roads, {
        id = next_road_id("branch"),
        points = b_points,
        width = 1,
        kind = "branch",
      })
    end

  elseif archetype == "hillside" then
    -- Contour-following road: try to stay at similar elevation
    local angle = prng() * 2 * math.pi
    local dx = math.cos(angle)
    local dz = math.sin(angle)
    local half = math.floor(main_len / 2)
    local points = {}
    local prev_y = nil
    for i = -half, half, 2 do
      local px = cx + dx * i
      local pz = cz + dz * i
      -- Adjust to follow contour
      if prev_y then
        for sy = 256, -64, -1 do
          local node = minetest.get_node({x = math.floor(px), y = sy, z = math.floor(pz)})
          if node.name ~= "air" and node.name ~= "ignore" then
            if math.abs(sy - prev_y) > 3 then
              -- Steep change: shift laterally to find gentler slope
              local shifted = false
              for lateral = -4, 4, 2 do
                local lx = px - dz * lateral
                local lz = pz + dx * lateral
                for ly = 256, -64, -1 do
                  local ln = minetest.get_node({x = math.floor(lx), y = ly, z = math.floor(lz)})
                  if ln.name ~= "air" and ln.name ~= "ignore" then
                    if math.abs(ly - prev_y) <= 3 then
                      px, pz = lx, lz
                      shifted = true
                    end
                    break
                  end
                end
                if shifted then break end
              end
            end
            prev_y = sy
            break
          end
        end
      else
        for sy = 256, -64, -1 do
          local node = minetest.get_node({x = math.floor(px), y = sy, z = math.floor(pz)})
          if node.name ~= "air" and node.name ~= "ignore" then
            prev_y = sy
            break
          end
        end
      end
      table.insert(points, {x = math.floor(px), z = math.floor(pz)})
    end
    table.insert(roads, {
      id = next_road_id("main"),
      points = points,
      width = 2,
      kind = "main_street",
    })
  end

  return roads
end

-- === Village Grammar: Lot Allocation ===
-- Places lots along roads based on spacing and terrain suitability.

local function allocate_lots(prng, roads, profile, environment)
  local lots = {}
  local spacing = profile.lot_spacing
  local used_positions = {}

  local function is_too_close(px, pz, min_dist)
    for _, up in ipairs(used_positions) do
      local dx = up.x - px
      local dz = up.z - pz
      if dx * dx + dz * dz < min_dist * min_dist then
        return true
      end
    end
    return false
  end

  local function terrain_ok(px, pz)
    local sy = nil
    for y = 256, -64, -1 do
      local node = minetest.get_node({x = px, y = y, z = pz})
      if node.name ~= "air" and node.name ~= "ignore" then
        sy = y
        break
      end
    end
    if not sy then return false end
    -- Check for water
    for y = sy, sy + 3 do
      local node = minetest.get_node({x = px, y = y, z = pz})
      if node.name:find("water") then return false end
    end
    -- Check local slope
    local min_y, max_y = sy, sy
    for dx = -2, 2, 2 do
      for dz = -2, 2, 2 do
        local ly = nil
        for y = 256, -64, -1 do
          local node = minetest.get_node({x = px + dx, y = y, z = pz + dz})
          if node.name ~= "air" and node.name ~= "ignore" then
            ly = y
            break
          end
        end
        if ly then
          min_y = math.min(min_y, ly)
          max_y = math.max(max_y, ly)
        end
      end
    end
    return (max_y - min_y) <= 4  -- max 4-block slope for lots
  end

  for _, road in ipairs(roads) do
    if #road.points < 2 then goto road_continue end
    local road_vec = {
      x = road.points[#road.points].x - road.points[1].x,
      z = road.points[#road.points].z - road.points[1].z,
    }
    local road_len = math.sqrt(road_vec.x * road_vec.x + road_vec.z * road_vec.z)
    if road_len < 4 then goto road_continue end
    local rdx = road_vec.x / road_len
    local rdz = road_vec.z / road_len
    -- Perpendicular directions (both sides)
    local perp_x = -rdz
    local perp_z = rdx

    local accumulated = spacing.min_gap + prng() * spacing.min_gap
    while accumulated < road_len - spacing.min_gap do
      local t = accumulated / road_len
      local sx = math.floor(road.points[1].x + road_vec.x * t)
      local sz = math.floor(road.points[1].z + road_vec.z * t)
      -- Try both sides
      for side = 1, -1, -2 do
        if #lots >= profile.target_lots then break end
        local offset = spacing.set_back + math.floor(spacing.depth / 2)
        local lx = math.floor(sx + perp_x * side * offset)
        local lz = math.floor(sz + perp_z * side * offset)
        local min_dist = math.max(spacing.min_gap, offset * 0.8)
        if not is_too_close(lx, lz, min_dist) and terrain_ok(lx, lz) then
          table.insert(lots, {
            center = {x = lx, z = lz},
            road_point = {x = sx, z = sz},
            side = side,
            road_id = road.id,
          })
          table.insert(used_positions, {x = lx, z = lz})
        end
      end
      accumulated = accumulated + spacing.min_gap + prng() * (spacing.max_gap - spacing.min_gap)
    end
    ::road_continue::
  end

  return lots
end

-- === Village Grammar: Structure Selection ===

local function select_structure_variant(prng, role, profile)
  local var = profile.variation_parameters.dwelling_variant or 1

  if role == "dwelling" then
    if var == 1 then return "pw_house_small_v1"
    else return "pw_house_small_v2" end
  elseif role == "farm" then
    return "pw_farmstead_v1"
  elseif role == "utility" then
    if prng() < 0.5 then return "pw_barn_v1"
    else return "pw_well_v1" end
  elseif role == "central" then
    return "pw_well_v1"
  elseif role == "optional" then
    local r = prng()
    if r < 0.4 then return "pw_house_small_v1"
    elseif r < 0.7 then return "pw_barn_v1"
    else return "pw_well_v1" end
  end
  return "pw_house_small_v1"
end

-- === Village Grammar: Full Plan Generation ===

local function generate_village_plan(candidate, profile, environment)
  local prng = village_prng_new(profile.seed_key)
  local center = {x = candidate.x, z = candidate.z}

  -- Step 1: Build road network
  local roads = build_road_network(prng, center, profile)

  -- Step 2: Allocate lots
  local lots = allocate_lots(prng, roads, profile, environment)

  -- Step 3: Assign roles to lots
  local role_idx = 0
  for _, lot in ipairs(lots) do
    role_idx = role_idx + 1
    local role = profile.structure_roles[role_idx] or "dwelling"
    local structure_name = select_structure_variant(prng, role, profile)
    local def = perfectworld.structures.get(structure_name)
    local rot = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]
    lot.role = role
    lot.structure_name = structure_name
    lot.rotation = rot
    if def then
      lot.footprint_min, lot.footprint_max = perfectworld.structures.get_footprint(
        def, {x = lot.center.x, y = 0, z = lot.center.z}, rot)
    end
  end

  -- Step 4: Filter overlapping lots
  local filtered_lots = {}
  for i, lot in ipairs(lots) do
    local overlaps = false
    if lot.footprint_min and lot.footprint_max then
      for j, other in ipairs(filtered_lots) do
        if other.footprint_min and other.footprint_max then
          if lot.footprint_min.x <= other.footprint_max.x and lot.footprint_max.x >= other.footprint_min.x and
             lot.footprint_min.z <= other.footprint_max.z and lot.footprint_max.z >= other.footprint_min.z then
            overlaps = true
            break
          end
        end
      end
    end
    if not overlaps then
      table.insert(filtered_lots, lot)
    end
  end

  -- Now assign actual roles to remaining lots
  local final_lots = {}
  local roles = {}
  for _, r in ipairs(profile.structure_roles) do
    roles[r] = (roles[r] or 0) + 1
  end
  local mandatory_order = {"dwelling", "farm", "utility", "central", "optional"}
  local lot_idx = 0
  for _, role in ipairs(mandatory_order) do
    local count = roles[role] or 0
    for _ = 1, count do
      lot_idx = lot_idx + 1
      if filtered_lots[lot_idx] then
        filtered_lots[lot_idx].role = role
        filtered_lots[lot_idx].structure_name = select_structure_variant(prng, role, profile)
        local def = perfectworld.structures.get(filtered_lots[lot_idx].structure_name)
        if def then
          local rot = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]
          filtered_lots[lot_idx].rotation = rot
          filtered_lots[lot_idx].footprint_min, filtered_lots[lot_idx].footprint_max =
            perfectworld.structures.get_footprint(def, {x = filtered_lots[lot_idx].center.x, y = 0, z = filtered_lots[lot_idx].center.z}, rot)
        end
        table.insert(final_lots, filtered_lots[lot_idx])
      end
    end
  end

  -- Build plan
  local plan = {
    village_id = profile.village_id,
    generator_version = profile.generator_version,
    archetype = profile.archetype,
    size_class = profile.size_class,
    environment = environment,
    material_palette = profile.material_palette,
    center = center,
    roads = roads,
    lots = final_lots,
    structure_roles = profile.structure_roles,
    -- Fingerprint for determinism verification
    fingerprint = nil, -- computed below
  }

  -- Compute road graph fingerprint (normalized to center, captures real geometry)
  local rg_parts = { "rg1", profile.archetype }
  for _, road in ipairs(roads) do
    table.insert(rg_parts, road.kind)
    table.insert(rg_parts, tostring(#road.points))
    table.insert(rg_parts, tostring(road.width or 2))
    -- Normalized relative coordinates
    for i, pt in ipairs(road.points) do
      table.insert(rg_parts, tostring(math.floor((pt.x - center.x) / 2)))
      table.insert(rg_parts, tostring(math.floor((pt.z - center.z) / 2)))
    end
  end
  plan.road_graph_fingerprint = perfectworld.core.stable_hash(table.concat(rg_parts, "|"))

  -- Compute village fingerprint (includes all lots and roads)
  local fp_parts = { "v3", profile.archetype, environment.biome_family,
    profile.size_class, tostring(#final_lots), tostring(#roads) }
  -- Lots: roles, structures, rotations, normalized positions
  for _, lot in ipairs(final_lots) do
    table.insert(fp_parts, lot.role)
    table.insert(fp_parts, lot.structure_name)
    table.insert(fp_parts, tostring(lot.rotation))
    table.insert(fp_parts, tostring(math.floor((lot.center.x - center.x) / 2)))
    table.insert(fp_parts, tostring(math.floor((lot.center.z - center.z) / 2)))
  end
  -- Road graph fingerprint
  table.insert(fp_parts, plan.road_graph_fingerprint)
  plan.fingerprint = perfectworld.core.stable_hash(table.concat(fp_parts, "|"))

  return plan
end

-- === Village Materialization (New) ===

local function materialize_village_plan(plan, profile, candidate)
  -- Mark settlement as placed first (idempotency gate)
  if perfectworld.planner.is_placed(candidate.id) then
    return true, {reason = "already_placed", settlement_id = candidate.id}
  end

  local placed_structures = {}
  local placed_roads = {}
  local errors = {}

  -- Materialize roads
  for _, road in ipairs(plan.roads) do
    if road.points and #road.points >= 2 then
      local road_mat = profile.material_palette.path or perfectworld.compat.get_material("road")
      for i = 1, #road.points - 1 do
        local p1 = road.points[i]
        local p2 = road.points[i + 1]
        local steps = math.max(math.abs(p2.x - p1.x), math.abs(p2.z - p1.z))
        if steps < 1 then steps = 1 end
        for s = 0, steps do
          local t = steps > 0 and (s / steps) or 0
          local rx = math.floor(p1.x + (p2.x - p1.x) * t)
          local rz = math.floor(p1.z + (p2.z - p1.z) * t)
          for w = -math.floor(road.width / 2), math.floor(road.width / 2) do
            local px = rx + w
            for py = 256, -64, -1 do
              local node = minetest.get_node({x = px, y = py, z = rz})
              if node.name ~= "air" and node.name ~= "ignore" then
                minetest.set_node({x = px, y = py, z = rz}, {name = road_mat})
                break
              end
            end
          end
        end
      end
      -- Save road record
      local road_record = {
        id = road.id,
        type = "local_road",
        from_settlement = candidate.id,
        path = road.points,
        length = #road.points,
        width = road.width,
        kind = road.kind,
      }
      perfectworld.planner.save_road(road_record)
      table.insert(placed_roads, road_record)
    end
  end

  -- Materialize structures
  for _, lot in ipairs(plan.lots) do
    local def = perfectworld.structures.get(lot.structure_name)
    if not def then
      table.insert(errors, "structure_not_found:" .. tostring(lot.structure_name))
      goto lot_continue
    end
    local structure_id = candidate.id .. "_struct_" .. (#placed_structures + 1)
    local ctx = {
      structure_id = structure_id,
      pos = {x = lot.center.x, y = 0, z = lot.center.z},
      rotation = lot.rotation,
      region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
      settlement_id = candidate.id,
    }
    local ok, result = perfectworld.structures.place(lot.structure_name, ctx)
    if ok then
      local record = {
        structure_id = structure_id,
        structure_name = lot.structure_name,
        role = lot.role,
        status = "materialized",
        position = result.position,
        rotation = lot.rotation,
        region_id = ctx.region_id,
        settlement_id = candidate.id,
      }
      perfectworld.planner.record_structure(record)
      table.insert(placed_structures, record)
    else
      table.insert(errors, "placement_failed:" .. tostring(lot.structure_name) .. ":" .. tostring(result and result.reason))
    end
    ::lot_continue::
  end

  -- Build settlement record
  local settlement_status
  if #placed_structures == 0 then
    settlement_status = "failed"
  elseif #errors > 0 then
    settlement_status = "partial"
  else
    settlement_status = "complete"
  end
  local settlement_record = {
    settlement_id = candidate.id,
    candidate_id = candidate.id,
    region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx or 0, candidate.rz or 0),
    generator_version = profile.generator_version,
    status = settlement_status,
    center_pos = {x = candidate.x, y = 0, z = candidate.z},
    bounds = {
      min_x = candidate.x - 50, max_x = candidate.x + 50,
      min_z = candidate.z - 50, max_z = candidate.z + 50,
    },
    environment_profile = profile.environment,
    archetype = profile.archetype,
    village_fingerprint = plan.fingerprint,
    road_graph_fingerprint = plan.road_graph_fingerprint,
    structure_ids = {},
    road_ids = {},
    lot_count = #placed_structures,
    created_at = minetest.get_gametime(),
  }
  for _, s in ipairs(placed_structures) do
    table.insert(settlement_record.structure_ids, s.structure_id)
  end
  for _, r in ipairs(placed_roads) do
    table.insert(settlement_record.road_ids, r.id)
  end

  -- Persist
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
    -- Check if already saved
    local existing = perfectworld.planner.get_settlement_plan(candidate.id)
    if existing and existing.settlement then
      return true, {settlement = existing.settlement, from_cache = true}
    end
    return false, "already_placed_no_record"
  end

  -- Get environment profile
  local pos = {x = candidate.x, y = 0, z = candidate.z}
  local environment = perfectworld.compat.get_environment(pos)

  -- Create village profile
  local profile = perfectworld.planner.create_village_profile(candidate, environment)

  -- Generate plan
  local plan = generate_village_plan(candidate, profile, environment)

  -- Materialize
  local ok, result = materialize_village_plan(plan, profile, candidate)
  return ok, result
end

-- === Public API: Fingerprint ===

function perfectworld.planner.get_village_fingerprint(candidate)
  local existing = perfectworld.planner.get_settlement_plan(candidate.id)
  if existing and existing.settlement then
    return existing.settlement.village_fingerprint
  end
  return nil
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

-- === Farm Location Finder ===

local function quick_slope_check_fn(cx, cz, half_size)
	pcall(minetest.load_area,
		{x = cx - half_size - 5, y = -10, z = cz - half_size - 5},
		{x = cx + half_size + 5, y = 60, z = cz + half_size + 5})
	local min_y, max_y, sum_y, count = nil, nil, 0, 0
	for dx = -half_size, half_size do
		for dz = -half_size, half_size do
			local y = nil
			for sy = 256, -64, -1 do
				local node = minetest.get_node({x = cx + dx, y = sy, z = cz + dz})
				if node.name ~= "air" and node.name ~= "ignore" then
					y = sy
					break
				end
			end
			if not y then
				return false, 999, "missing_surface", 0
			end
			min_y = min_y and math.min(min_y, y) or y
			max_y = max_y and math.max(max_y, y) or y
			sum_y = sum_y + y
			count = count + 1
		end
	end
	local slope = max_y - min_y
	local avg_y = count > 0 and math.floor(sum_y / count + 0.5) or 0
	return true, slope, nil, avg_y
end
quick_slope_check = quick_slope_check_fn

local function find_farm_location_fn(candidate, layout)
	minetest.log("action", "[pw_planner] find_farm_location called for " .. tostring(candidate.id))
	local prng = det_prng(perfectworld.core.stable_hash(candidate.id .. "_farm_search"))

	local best_farm = nil
	local best_score = math.huge
	local fallback_farm = nil
	local fallback_slope = math.huge

	local function try_location(fx, fz, dist, allow_steep)
		if layout and layout.plots then
			for _, plot in ipairs(layout.plots) do
				if plot.center then
					local ddx = fx - plot.center.x
					local ddz = fz - plot.center.z
					if ddx * ddx + ddz * ddz < 400 then
						return nil
					end
				end
			end
		end

		-- Load chunks around the candidate position
		pcall(minetest.load_area,
			{x = fx - 10, y = -10, z = fz - 10},
			{x = fx + 10, y = 60, z = fz + 10})
		local ok, slope, reason, avg_y = quick_slope_check(fx, fz, 3)
		if not ok then
			return nil
		end

		if slope <= 2 then
			local ref_y = 0
			for dx = -3, 3 do
				for dz = -3, 3 do
					local y = nil
					for sy = 256, -64, -1 do
						local node = minetest.get_node({x = fx + dx, y = sy, z = fz + dz})
						if node.name ~= "air" and node.name ~= "ignore" then
							y = sy
							break
						end
					end
					if not y then return nil end
					if ref_y == 0 then ref_y = y end
					local diff = y - ref_y
					if diff > 4 or diff < -3 then
						return nil
					end
				end
			end

			local rot = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]
			local conn_offset = {x = 0, z = 7}
			local rotated = perfectworld.structures.rotate_point(conn_offset, rot)
			return {
				x = fx, z = fz,
				rotation = rot,
				connector = {x = fx + rotated.x, z = fz + rotated.z},
				needs_flatten = false,
				surface_y = avg_y,
			}
		end

		if allow_steep and slope < fallback_slope then
			fallback_slope = slope
			minetest.log("action", "[pw_planner] farm fallback at (" .. fx .. "," .. fz .. ") slope=" .. slope)
			local rot = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]
			local conn_offset = {x = 0, z = 7}
			local rotated = perfectworld.structures.rotate_point(conn_offset, rot)
			fallback_farm = {
				x = fx, z = fz,
				rotation = rot,
				connector = {x = fx + rotated.x, z = fz + rotated.z},
				needs_flatten = true,
				surface_y = avg_y,
			}
		end

		return nil
	end

	for attempt = 1, 50 do
		local angle = prng() * 2 * math.pi
		local dist = 80 + prng() * 170
		local fx = candidate.x + math.floor(math.cos(angle) * dist)
		local fz = candidate.z + math.floor(math.sin(angle) * dist)

		local farm = try_location(fx, fz, dist, true)
		if farm and not farm.needs_flatten then
			local score = math.abs(dist - 150)
			if score < best_score then
				best_score = score
				best_farm = farm
			end
		end
	end
	if best_farm then
		minetest.log("action", "[pw_planner] farm found strict at (" .. best_farm.x .. "," .. best_farm.z .. ")")
		return best_farm
	end
	if fallback_farm then
		minetest.log("action", "[pw_planner] farm found fallback at (" .. fallback_farm.x .. "," .. fallback_farm.z .. ") slope=" .. fallback_slope)
		return fallback_farm
	end

	for ring = 1, 3 do
		local base_dist = 100 + ring * 100
		for dir_i = 0, 7 do
			local angle = dir_i * math.pi / 4
			for offset = -40, 40, 10 do
				local dist = base_dist + offset
				if dist >= 80 and dist <= 500 then
					local fx = candidate.x + math.floor(math.cos(angle) * dist)
					local fz = candidate.z + math.floor(math.sin(angle) * dist)
					local farm = try_location(fx, fz, dist, false)
					if farm and not farm.needs_flatten then
						return farm
					end
				end
			end
		end
	end
	if fallback_farm then return fallback_farm end

	if layout and layout.external_connector then
		local dirs = {
			{dx =  1, dz =  0}, {dx = -1, dz = 0},
			{dx =  0, dz =  1}, {dx =  0, dz = -1},
			{dx =  1, dz =  1}, {dx = -1, dz = -1},
			{dx =  1, dz = -1}, {dx = -1, dz =  1},
		}
		local base = layout.external_connector
		for step = 80, 260, 20 do
			for _, dir in ipairs(dirs) do
				local fx = base.x + dir.dx * step
				local fz = base.z + dir.dz * step
				local farm = try_location(fx, fz, step, true)
				if farm and not farm.needs_flatten then
					return farm
				end
			end
		end
	end
	if fallback_farm then
		minetest.log("action", "[pw_planner] farm found fallback phase3 at (" .. fallback_farm.x .. "," .. fallback_farm.z .. ")")
		return fallback_farm
	end

	-- Final fallback: try very close to external connector (50-100 blocks) in all 8 directions
	if layout and layout.external_connector then
		local base = layout.external_connector
		local dirs = {
			{dx =  1, dz =  0}, {dx = -1, dz = 0},
			{dx =  0, dz =  1}, {dx =  0, dz = -1},
			{dx =  1, dz =  1}, {dx = -1, dz = -1},
			{dx =  1, dz = -1}, {dx = -1, dz =  1},
		}
		for step = 50, 120, 10 do
			for _, dir in ipairs(dirs) do
				local fx = base.x + dir.dx * step
				local fz = base.z + dir.dz * step
				local farm = try_location(fx, fz, step, false)
				if farm and not farm.needs_flatten then return farm end
			end
		end
	end
	if fallback_farm then
		minetest.log("action", "[pw_planner] farm found fallback phase4 at (" .. fallback_farm.x .. "," .. fallback_farm.z .. ")")
		return fallback_farm
	end

	-- Last resort: use external_connector offset itself, mark for flatten
	if layout and layout.external_connector then
		local ec = layout.external_connector
		for _, dir in ipairs({{dx=60, dz=60}, {dx=-60, dz=60}, {dx=60, dz=-60}, {dx=-60, dz=-60}, {dx=80, dz=0}, {dx=-80, dz=0}, {dx=0, dz=80}, {dx=0, dz=-80}}) do
			local fx = ec.x + dir.dx
			local fz = ec.z + dir.dz
			local ok, slope, reason, avg_y = quick_slope_check(fx, fz, 3)
			if ok then
				minetest.log("action", "[pw_planner] farm last-resort FOUND at (" .. fx .. "," .. fz .. ") slope=" .. slope)
				local rot = ({0, 90, 180, 270})[1 + math.floor(prng() * 4)]
				local conn_offset = {x = 0, z = 7}
				local rotated = perfectworld.structures.rotate_point(conn_offset, rot)
				return {
					x = fx, z = fz,
					rotation = rot,
					connector = {x = fx + rotated.x, z = fz + rotated.z},
					needs_flatten = true,
					surface_y = avg_y,
				}
			end
		end
	end

	minetest.log("action", "[pw_planner] find_farm_location returning nil")
	return nil
end
find_farm_location = find_farm_location_fn

local function flatten_farm_site_fn(farm)
	if not farm.needs_flatten then return end
	local ground_mat = perfectworld.compat.get_material("ground")
	local cx, cz = farm.x, farm.z
	local sy = farm.surface_y or 0

	for dx = -4, 4 do
		for dz = -4, 4 do
			local px, pz = cx + dx, cz + dz
			for y = sy + 1, 256 do
				local node = minetest.get_node({x = px, y = y, z = pz})
				if node.name ~= "air" then
					minetest.set_node({x = px, y = y, z = pz}, {name = "air"})
				else
					break
				end
			end
			for y = sy, math.max(sy - 3, -64), -1 do
				local node = minetest.get_node({x = px, y = y, z = pz})
				if node.name == "air" or node.name == "ignore" then
					minetest.set_node({x = px, y = y, z = pz}, {name = ground_mat})
				else
					break
				end
			end
			minetest.set_node({x = px, y = sy, z = pz}, {name = ground_mat})
		end
	end
end
flatten_farm_site = flatten_farm_site_fn

-- === Simple Road Builder ===

local function build_road_fn(start_conn, farm_conn)
	if not start_conn or not farm_conn then return nil end

	local road_path = {}
	local sx, sz = start_conn.x, start_conn.z
	local ex, ez = farm_conn.x, farm_conn.z

	local dx = ex - sx
	local dz = ez - sz
	local dist = math.sqrt(dx * dx + dz * dz)
	local steps = math.floor(dist)

	if steps < 2 then return nil end

	local road_mat = perfectworld.compat.get_material("road")
	local half_width = 1
	local prev_y = nil

	for i = 0, steps do
		local t = steps > 0 and (i / steps) or 0
		local x = math.floor(sx + dx * t)
		local z = math.floor(sz + dz * t)

		local surface_y = nil
		for y = 256, -64, -1 do
			local node = minetest.get_node({x = x, y = y, z = z})
			if node.name ~= "air" and node.name ~= "ignore" then
				surface_y = y
				break
			end
		end

		if not surface_y then
			if prev_y then
				surface_y = prev_y
			else
				goto road_continue
			end
		end

		if prev_y then
			local diff = surface_y - prev_y
			if diff > 1 then
				for step_y = prev_y + 1, surface_y do
					for w = -half_width, half_width do
						minetest.set_node({x = x + w, y = step_y, z = z}, {name = road_mat})
					end
				end
			elseif diff < -1 then
				surface_y = prev_y
			end
		end

		for w = -half_width, half_width do
			minetest.set_node({x = x + w, y = surface_y, z = z}, {name = road_mat})
			minetest.set_node({x = x + w, y = surface_y - 1, z = z}, {name = road_mat})
		end

		table.insert(road_path, {x = x, y = surface_y, z = z})
		prev_y = surface_y

		::road_continue::
	end

	return road_path
end
build_road = build_road_fn

-- === Village Materialization ===

local function materialize_village(candidate)
  -- Delegate to the new biome-aware village generation system.
  return perfectworld.planner.materialize_village_new(candidate)
end

-- === Region Candidate Materialization ===

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
