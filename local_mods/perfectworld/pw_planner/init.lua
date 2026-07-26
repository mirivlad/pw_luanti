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
	if perfectworld.materialization_enabled == false then
		return false, perfectworld.world_format_error or "materialization_disabled"
	end

	if perfectworld.planner.is_placed(candidate.id) then
		return false, "already_placed"
	end

	-- Check if we already have a layout
	local existing = perfectworld.planner.get_settlement_plan(candidate.id)
	if existing then
		-- Re-materialize from existing layout
		local vresult = perfectworld.village.materialize(existing)
		perfectworld.planner.mark_placed(candidate.id)
		return true, {village_result = vresult, settlement_id = candidate.id}
	end

	-- Generate new layout
	local settlement = {
		id = candidate.id,
		type = "village",
		cx = candidate.x,
		cz = candidate.z,
		rx = candidate.rx,
		rz = candidate.rz,
	}

	local layout = perfectworld.village.plan_layout(settlement)
	layout.region_id = candidate.region_id or perfectworld.get_region_id(candidate.rx, candidate.rz)

	-- Save the plan
	perfectworld.planner.save_settlement_plan(candidate.id, layout)

	-- Propagate skip_terrain_check
	layout.skip_terrain_check = candidate.skip_terrain_check

	-- Materialize village (street + buildings)
	local vresult = perfectworld.village.materialize(layout)
	minetest.log("action", "[pw_planner] village materialize: plots_placed=" .. tostring(vresult.plots_placed) .. " skipped=" .. tostring(vresult.plots_skipped))

	-- Save updated layout (with materialized positions)
	perfectworld.planner.save_settlement_plan(candidate.id, layout)

	-- Find a farm location and create road
	local farm_result = nil
	local road_result = nil

	if vresult.plots_placed >= 3 then
		minetest.log("action", "[pw_planner] farm search: starting")
		local farm = find_farm_location(candidate, layout)
		minetest.log("action", "[pw_planner] farm search: farm=" .. tostring(farm))
		if farm then
			-- Flatten terrain if slope was too steep
			if farm.needs_flatten then
				flatten_farm_site(farm)
				minetest.log("action", "[pw_planner] flattened farm site at (" .. farm.x .. "," .. farm.z .. ")")
			end

			-- Place farm structure with offsets (like village plots)
			local farm_offsets = {
				{x = 0, z = 0},
				{x = 4, z = 0},
				{x = -4, z = 0},
				{x = 0, z = 4},
				{x = 0, z = -4},
				{x = 8, z = 0},
				{x = -8, z = 0},
			}
			for _, off in ipairs(farm_offsets) do
				local farm_ctx = {
					structure_id = candidate.id .. "_farm",
					pos = {x = farm.x + off.x, y = 0, z = farm.z + off.z},
					rotation = farm.rotation,
					region_id = candidate.region_id,
					settlement_id = candidate.id .. "_farm",
				}
				if candidate.skip_terrain_check then
					farm_ctx.skip_terrain_check = true
				end
				local farm_place_ok, farm_place_res
				farm_place_ok, farm_place_res = perfectworld.structures.place("pw_farmstead_v1", farm_ctx)
				if farm_place_ok then
					farm_result = farm_place_res
					break
				end
			end

			if not farm_result and not candidate.skip_terrain_check then
				-- Aggressive flatten retry for farm (same as village plots)
				local building_half = 5
				local air = "air"
				local ground_mat = perfectworld.compat.get_material("ground")
				local sy = 0
				for y = 256, -64, -1 do
					local node = minetest.get_node({x = farm.x, y = y, z = farm.z})
					if node.name ~= "air" and node.name ~= "ignore" then
						sy = y
						break
					end
				end
				for dx = -building_half, building_half do
					for dz = -building_half, building_half do
						local px, pz = farm.x + dx, farm.z + dz
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
				minetest.log("action", "[pw_planner] aggressive flatten for farm at (" .. farm.x .. "," .. farm.z .. ")")
				local retry_ctx = {
					structure_id = candidate.id .. "_farm",
					pos = {x = farm.x, y = 0, z = farm.z},
					rotation = farm.rotation,
					region_id = candidate.region_id,
					settlement_id = candidate.id .. "_farm",
					skip_terrain_check = true,
				}
				local farm_place_ok, farm_place_res = perfectworld.structures.place("pw_farmstead_v1", retry_ctx)
				if farm_place_ok then
					farm_result = farm_place_res
					minetest.log("action", "[pw_planner] farm placed after aggressive flatten")
				end
			end

			if farm_result then
				perfectworld.planner.save_structure(candidate.id .. "_farm", {
					structure_id = candidate.id .. "_farm",
					structure_name = "pw_farmstead_v1",
					position = farm_result.position,
					rotation = farm.rotation,
					status = "materialized",
					settlement_id = candidate.id,
				})

				local road_path = build_road(layout.external_connector, farm.connector)
				if road_path then
					local road_id = candidate.id .. "_road_to_farm"
					road_result = {
						id = road_id,
						type = "local_road",
						from_settlement = candidate.id,
						to_farm = candidate.id .. "_farm",
						path = road_path,
						length = #road_path,
					}
					perfectworld.planner.save_road(road_result)
				else
					minetest.log("warning", "[pw_planner] road build failed for " .. tostring(candidate.id))
				end
			end
		else
			minetest.log("warning", "[pw_planner] no suitable farm location found for " .. tostring(candidate.id))
		end
	end

	perfectworld.planner.mark_placed(candidate.id)
	return true, {
		village_result = vresult,
		farm = farm_result,
		road = road_result,
		settlement_id = candidate.id,
	}
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
