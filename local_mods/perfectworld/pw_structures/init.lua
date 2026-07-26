perfectworld = perfectworld or {}
perfectworld.structures = perfectworld.structures or {}

local structures = {}

local deep_copy = perfectworld.core.deep_copy

local function material(name, opts)
	return perfectworld.compat.get_material(name, opts or {required = true})
end

local function is_replaceable(pos)
	local node = minetest.get_node(pos)
	if perfectworld.compat and perfectworld.compat.is_replaceable then
		return perfectworld.compat.is_replaceable(node.name)
	end
	return node.name == "air" or node.name == "ignore"
end

local function is_protected_area(minp, maxp)
	for x = minp.x, maxp.x do
		for y = minp.y, maxp.y do
			for z = minp.z, maxp.z do
				if minetest.is_protected({x = x, y = y, z = z}, "") then
					return true, {x = x, y = y, z = z}
				end
			end
		end
	end
	return false
end

function perfectworld.structures.validate(def)
	if type(def) ~= "table" then return false, "definition must be a table" end
	if type(def.version) ~= "number" then return false, "version must be a number" end
	if type(def.size) ~= "table" then return false, "size must be a table" end
	for _, axis in ipairs({"x", "y", "z"}) do
		if type(def.size[axis]) ~= "number" or def.size[axis] < 1 then
			return false, "size." .. axis .. " must be a positive number"
		end
	end
	if type(def.origin) ~= "table" then return false, "origin must be a table" end
	for _, axis in ipairs({"x", "y", "z"}) do
		if type(def.origin[axis]) ~= "number" then
			return false, "origin." .. axis .. " must be a number"
		end
	end
	if type(def.categories) ~= "table" then return false, "categories must be a table" end
	if type(def.allowed_settlement_types) ~= "table" then return false, "allowed_settlement_types must be a table" end
	if type(def.rotations) ~= "table" then return false, "rotations must be a table" end
	if type(def.terrain) ~= "table" then return false, "terrain must be a table" end
	if type(def.connectors) ~= "table" then return false, "connectors must be a table" end
	if type(def.placement) ~= "table" then return false, "placement must be a table" end
	if def.placement.type ~= "lua" and def.placement.type ~= "schematic" then
		return false, "placement.type must be lua or schematic"
	end
	if def.placement.type == "lua" and type(def.placement.generator) ~= "function" then
		return false, "placement.generator must be a function for lua placement"
	end
	if def.placement.type == "lua" and def.placement.preflight and type(def.placement.preflight) ~= "function" then
		return false, "placement.preflight must be a function for lua placement"
	end
	if def.placement.type == "schematic" and not def.placement.schematic then
		return false, "placement.schematic must be set for schematic placement"
	end
	return true
end

function perfectworld.structures.register(name, definition)
	if type(name) ~= "string" or name == "" then
		return false, "name must be a non-empty string"
	end
	local ok, err = perfectworld.structures.validate(definition)
	if not ok then
		return false, "invalid structure '" .. name .. "': " .. tostring(err)
	end
	local copy = deep_copy(definition)
	copy.name = name
	structures[name] = copy
	return true
end

function perfectworld.structures.get(name)
	local def = structures[name]
	if not def then return nil end
	return deep_copy(def)
end

function perfectworld.structures.list()
	local result = {}
	for name, _ in pairs(structures) do
		table.insert(result, name)
	end
	table.sort(result)
	return result
end

function perfectworld.structures.rotate_point(pos, rotation)
	rotation = rotation % 360
	if rotation == 0 then
		return {x = pos.x, y = pos.y, z = pos.z}
	elseif rotation == 90 then
		return {x = -pos.z, y = pos.y, z = pos.x}
	elseif rotation == 180 then
		return {x = -pos.x, y = pos.y, z = -pos.z}
	elseif rotation == 270 then
		return {x = pos.z, y = pos.y, z = -pos.x}
	end
	error("unsupported rotation: " .. tostring(rotation))
end

local side_rotation = {
	south = { [0] = "south", [90] = "west", [180] = "north", [270] = "east" },
	west = { [0] = "west", [90] = "north", [180] = "east", [270] = "south" },
	north = { [0] = "north", [90] = "east", [180] = "south", [270] = "west" },
	east = { [0] = "east", [90] = "south", [180] = "west", [270] = "north" },
}

function perfectworld.structures.rotate_connector(connector, rotation)
	local copy = deep_copy(connector)
	copy.side = (side_rotation[connector.side] or side_rotation.south)[rotation % 360]
	if connector.offset_pos then
		copy.offset_pos = perfectworld.structures.rotate_point(connector.offset_pos, rotation)
	end
	return copy
end

local function local_to_world(origin, local_pos, rotation)
	local rotated = perfectworld.structures.rotate_point(local_pos, rotation)
	return {
		x = origin.x + rotated.x,
		y = origin.y + rotated.y,
		z = origin.z + rotated.z,
	}
end

local function snapshot_area(minp, maxp)
	local snapshot = {}
	for x = minp.x, maxp.x do
		for y = minp.y, maxp.y do
			for z = minp.z, maxp.z do
				local pos = {x = x, y = y, z = z}
				table.insert(snapshot, {pos = pos, node = minetest.get_node(pos)})
			end
		end
	end
	return snapshot
end

local function restore_area(snapshot)
	for i = #snapshot, 1, -1 do
		local entry = snapshot[i]
		minetest.set_node(entry.pos, entry.node)
	end
end

function perfectworld.structures.get_footprint(def, origin, rotation)
	local minp = {x = math.huge, y = origin.y, z = math.huge}
	local maxp = {x = -math.huge, y = origin.y + def.size.y - 1, z = -math.huge}
	for _, corner in ipairs({
		{x = -def.origin.x, y = 0, z = -def.origin.z},
		{x = def.size.x - 1 - def.origin.x, y = 0, z = -def.origin.z},
		{x = -def.origin.x, y = 0, z = def.size.z - 1 - def.origin.z},
		{x = def.size.x - 1 - def.origin.x, y = 0, z = def.size.z - 1 - def.origin.z},
	}) do
		local world = local_to_world(origin, corner, rotation)
		minp.x = math.min(minp.x, world.x)
		minp.z = math.min(minp.z, world.z)
		maxp.x = math.max(maxp.x, world.x)
		maxp.z = math.max(maxp.z, world.z)
	end
	return minp, maxp
end

function perfectworld.structures.get_building_footprint(def, origin, rotation)
	local building = def.terrain.building_footprint
	if not building then
		return perfectworld.structures.get_footprint(def, origin, rotation)
	end
	local minp = {x = math.huge, y = origin.y, z = math.huge}
	local maxp = {x = -math.huge, y = origin.y + def.size.y - 1, z = -math.huge}
	for _, corner in ipairs({
		{x = building.min_x, y = 0, z = building.min_z},
		{x = building.max_x, y = 0, z = building.min_z},
		{x = building.min_x, y = 0, z = building.max_z},
		{x = building.max_x, y = 0, z = building.max_z},
	}) do
		local world = local_to_world(origin, corner, rotation)
		minp.x = math.min(minp.x, world.x)
		minp.z = math.min(minp.z, world.z)
		maxp.x = math.max(maxp.x, world.x)
		maxp.z = math.max(maxp.z, world.z)
	end
	return minp, maxp
end

local function find_surface_y(x, z)
	for y = 256, -64, -1 do
		local node = minetest.get_node({x = x, y = y, z = z})
		if node.name ~= "air" and node.name ~= "ignore" then
			return y
		end
	end
	return nil
end

function perfectworld.structures.analyze_terrain(def, origin, rotation)
	local margin = def.terrain.modification_margin or 1
	local max_cut = def.terrain.max_cut_depth or 3
	local max_fill = def.terrain.max_fill_height or 3
	local building_minp, building_maxp = perfectworld.structures.get_building_footprint(def, origin, rotation)
	local minp = {x = building_minp.x - margin, y = building_minp.y, z = building_minp.z - margin}
	local maxp = {x = building_maxp.x + margin, y = building_maxp.y, z = building_maxp.z + margin}
	local min_y, max_y = nil, nil
	for x = minp.x, maxp.x do
		for z = minp.z, maxp.z do
			local y = find_surface_y(x, z)
			if not y then
				return false, {reason = "missing_surface", pos = {x = x, z = z}}
			end
			min_y = min_y and math.min(min_y, y) or y
			max_y = max_y and math.max(max_y, y) or y
		end
	end
	local slope = max_y - min_y
	local max_slope = def.terrain.max_slope or 2
	if slope > max_slope then
		return false, {reason = "slope_too_steep", slope = slope, max_slope = max_slope}
	end
	-- reject terrain that would require excessive cut or fill
	local reference_y = max_y
	local excessive_cut = false
	local excessive_fill = false
	for x = minp.x, maxp.x do
		for z = minp.z, maxp.z do
			local y = find_surface_y(x, z)
			if y then
				local depth_below = reference_y - y
				if depth_below > max_cut then
					excessive_cut = true
				end
				local height_above = y - reference_y
				if height_above > max_fill then
					excessive_fill = true
				end
			end
		end
	end
	if excessive_cut then
		return false, {reason = "excessive_cut", max_cut = max_cut}
	end
	if excessive_fill then
		return false, {reason = "excessive_fill", max_fill = max_fill}
	end
	return true, {
		minp = minp,
		maxp = maxp,
		surface_y = max_y,
		slope = slope,
		building_minp = building_minp,
		building_maxp = building_maxp,
		margin = margin,
	}
end

function perfectworld.structures.prepare_terrain(def, origin, rotation, analysis)
	local foundation = material("foundation")
	local air = "air"
	local base_y = analysis.surface_y + 1
	local minp, maxp = analysis.minp, analysis.maxp

	local max_cut = def.terrain.max_cut_depth or 3
	local max_fill = def.terrain.max_fill_height or 3

	local cut_top_y = base_y - 1
	local cut_bottom_y = math.max(base_y - (def.terrain.foundation_depth or 2), base_y - max_cut)

	local fill_bottom_y = base_y
	local fill_top_y = math.min(base_y + (def.terrain.clearance_height or def.size.y + 2), base_y + max_fill)

	local protected, protected_pos = is_protected_area(
		{x = minp.x, y = cut_bottom_y, z = minp.z},
		{x = maxp.x, y = fill_top_y, z = maxp.z}
	)
	if protected then
		return false, {reason = "protected", pos = protected_pos}
	end

	-- distance from point (x,z) to the building footprint rectangle
	local function dist_to_footprint(px, pz)
		local bminx = analysis.building_minp.x
		local bmaxx = analysis.building_maxp.x
		local bminz = analysis.building_minp.z
		local bmaxz = analysis.building_maxp.z
		local dx = math.max(bminx - px, 0, px - bmaxx)
		local dz = math.max(bminz - pz, 0, pz - bmaxz)
		return math.sqrt(dx * dx + dz * dz)
	end

	-- smooth edge: return a fractional blend factor [0..1] where 0 = fully outside, 1 = fully inside footprint
	local blend_margin = math.max(1, analysis.margin)
	local function edge_blend(px, pz)
		local bminx = analysis.building_minp.x
		local bmaxx = analysis.building_maxp.x
		local bminz = analysis.building_minp.z
		local bmaxz = analysis.building_maxp.z
		if px >= bminx and px <= bmaxx and pz >= bminz and pz <= bmaxz then
			return 1
		end
		local d = dist_to_footprint(px, pz)
		if d <= blend_margin then
			return 1 - (d / blend_margin)
		end
		return 0
	end

	for x = minp.x, maxp.x do
		for z = minp.z, maxp.z do
			local blend = edge_blend(x, z)
			local orig_surface = find_surface_y(x, z)
			if not orig_surface then
				return false, {reason = "missing_surface_after_analysis", pos = {x = x, z = z}}
			end
			-- compute modified height target with smooth transition
			local target_top = math.floor(base_y + (fill_top_y - base_y) * blend)
			-- foundation fill: only inside footprint (blend > 0.5)
			if blend >= 0.5 then
				for y = cut_bottom_y, cut_top_y do
					minetest.set_node({x = x, y = y, z = z}, {name = foundation})
				end
			end
			-- air clearance: apply with blend
			for y = fill_bottom_y, target_top do
				local p = {x = x, y = y, z = z}
				if y <= orig_surface and blend < 0.5 then
					-- outside footprint blending zone: only clear replaceable
					if is_replaceable(p) then
						local node_name = minetest.get_node(p).name
						local defn = minetest.registered_nodes[node_name]
						if defn and (defn.groups and (defn.groups.flora or defn.groups.leaves or defn.groups.plant)) then
							minetest.set_node(p, {name = air})
						end
						-- leave non-replaceable non-flora nodes untouched
					end
				else
					if not is_replaceable(p) then
						local node_name = minetest.get_node(p).name
						local defn = minetest.registered_nodes[node_name]
						if defn and (defn.groups and (defn.groups.flora or defn.groups.leaves or defn.groups.plant)) then
							minetest.set_node(p, {name = air})
						else
							return false, {reason = "blocked", pos = p, node = node_name}
						end
					else
						minetest.set_node(p, {name = air})
					end
				end
			end
			-- for cells that remain above target but below orig_surface in blend zone, reshape terrain
			if blend > 0 and blend < 1 then
				local new_surface = math.floor(orig_surface * (1 - blend) + base_y * blend)
				for y = new_surface + 1, orig_surface do
					local p = {x = x, y = y, z = z}
					if is_replaceable(p) then
						minetest.set_node(p, {name = air})
					end
				end
				for y = cut_bottom_y, new_surface do
					local existing = minetest.get_node({x = x, y = y, z = z}).name
					if existing == air or existing == "ignore" then
						minetest.set_node({x = x, y = y, z = z}, {name = foundation})
					end
				end
			end
		end
	end
	return true, {position = {x = origin.x, y = base_y, z = origin.z}}
end

local function place_node(origin, rotation, local_pos, node_name, param2)
	local p = local_to_world(origin, local_pos, rotation)
	minetest.set_node(p, {name = node_name, param2 = param2 or 0})
end

local function resolve_farmstead_materials()
	return {
		foundation = material("foundation"),
		wall = material("wall"),
		roof = material("roof"),
		floor = material("floor"),
		road = material("road"),
		fence = material("fence", {required = false, fallback = "air"}),
		door = material("door"),
		door_top = material("door_top", {required = false, fallback = "air"}),
		window = material("window", {required = false, fallback = "air"}),
		light = material("light"),
		bed = material("bed", {required = false, fallback = "air"}),
		table = material("table", {required = false, fallback = "air"}),
		container = material("container"),
		garden_soil = material("garden_soil", {required = false, fallback = material("ground")}),
		crop = material("crop", {required = false, fallback = "air"}),
	}
end

local function farmstead_preflight()
	resolve_farmstead_materials()
	return true
end

local function farmstead_generator(context, def)
	local pos = context.prepared_position or context.pos
	local rotation = context.rotation or 0
	local mats = resolve_farmstead_materials()

	for x = -3, 3 do
		for z = -3, 3 do
			place_node(pos, rotation, {x = x, y = 0, z = z}, mats.floor)
		end
	end

	for x = -3, 3 do
		for y = 1, 3 do
			place_node(pos, rotation, {x = x, y = y, z = -3}, mats.wall)
			place_node(pos, rotation, {x = x, y = y, z = 3}, mats.wall)
		end
	end
	for z = -3, 3 do
		for y = 1, 3 do
			place_node(pos, rotation, {x = -3, y = y, z = z}, mats.wall)
			place_node(pos, rotation, {x = 3, y = y, z = z}, mats.wall)
		end
	end

	-- Door and windows
	place_node(pos, rotation, {x = 0, y = 1, z = 3}, mats.door)
	place_node(pos, rotation, {x = 0, y = 2, z = 3}, mats.door_top)
	place_node(pos, rotation, {x = -3, y = 2, z = -1}, mats.window)
	place_node(pos, rotation, {x = 3, y = 2, z = 1}, mats.window)

	for x = -4, 4 do
		for z = -4, 4 do
			if math.abs(x) == 4 or math.abs(z) == 4 or (x + z) % 2 == 0 then
				place_node(pos, rotation, {x = x, y = 4, z = z}, mats.roof)
			end
		end
	end

	-- Porch, short path, interior
	for z = 4, 7 do
		place_node(pos, rotation, {x = 0, y = 0, z = z}, mats.road)
	end
	place_node(pos, rotation, {x = 1, y = 1, z = 1}, mats.light)
	place_node(pos, rotation, {x = -1, y = 1, z = -1}, mats.table)
	place_node(pos, rotation, {x = 2, y = 1, z = -2}, mats.container)

	-- Small fenced garden.
	for x = -7, -4 do
		for z = -3, 2 do
			if x == -7 or x == -4 or z == -3 or z == 2 then
				place_node(pos, rotation, {x = x, y = 1, z = z}, mats.fence)
			else
				place_node(pos, rotation, {x = x, y = 0, z = z}, mats.garden_soil)
				if (x + z) % 2 == 0 and mats.crop ~= "air" then
					place_node(pos, rotation, {x = x, y = 1, z = z}, mats.crop)
				end
			end
		end
	end

	return true
end

function perfectworld.structures.place(name, context)
	local def = structures[name]
	if not def then
		return false, {reason = "not_registered", structure_name = name}
	end
	if type(context) ~= "table" or type(context.pos) ~= "table" then
		return false, {reason = "invalid_context"}
	end
	if context.structure_id and perfectworld.planner and perfectworld.planner.get_structure(context.structure_id) then
		return false, {reason = "already_materialized", structure_id = context.structure_id}
	end
	local rotation = context.rotation or 0
	local allowed = false
	for _, r in ipairs(def.rotations or {}) do
		if r == rotation then allowed = true break end
	end
	if not allowed then
		return false, {reason = "unsupported_rotation", rotation = rotation}
	end
	if def.placement.type == "lua" and def.placement.preflight then
		local preflight_ok, preflight_result, preflight_err = pcall(def.placement.preflight, context, def)
		if not preflight_ok then
			return false, {reason = "material_unavailable", error = tostring(preflight_result)}
		end
		if preflight_result == false then
			return false, {reason = "material_unavailable", error = tostring(preflight_err or preflight_result)}
		end
	end

	local footprint_minp, footprint_maxp = perfectworld.structures.get_footprint(def, context.pos, rotation)
	if minetest.load_area then
		pcall(minetest.load_area,
			{x = footprint_minp.x, y = -64, z = footprint_minp.z},
			{x = footprint_maxp.x, y = 256, z = footprint_maxp.z})
	end

	local terrain_ok, analysis
	if context.skip_terrain_check then
		-- fake analysis: pass any slope, find surface at origin
		local origin_pos = context.pos
		local local_ground
		for y = 256, -64, -1 do
			local node = minetest.get_node({x = origin_pos.x, y = y, z = origin_pos.z})
			if node.name ~= "air" and node.name ~= "ignore" then
				local_ground = y
				break
			end
		end
		local_ground = local_ground or 0
		analysis = {
			surface_y = local_ground,
			minp = {x = origin_pos.x - 10, y = local_ground - 5, z = origin_pos.z - 10},
			maxp = {x = origin_pos.x + 10, y = local_ground + 15, z = origin_pos.z + 10},
			building_minp = {x = origin_pos.x - 5, y = local_ground, z = origin_pos.z - 5},
			building_maxp = {x = origin_pos.x + 5, y = local_ground + 5, z = origin_pos.z + 5},
			margin = 1,
		}
		terrain_ok = true
	else
		terrain_ok, analysis = perfectworld.structures.analyze_terrain(def, context.pos, rotation)
		if not terrain_ok then
			return false, analysis
		end
	end
	local base_y = analysis.surface_y + 1
	local max_cut = def.terrain.max_cut_depth or 3
	local max_fill = def.terrain.max_fill_height or 3
	local cut_bottom_y = math.max(base_y - (def.terrain.foundation_depth or 2), base_y - max_cut)
	local fill_top_y = math.min(base_y + (def.terrain.clearance_height or def.size.y + 2), base_y + max_fill)
	local rollback_minp = {
		x = analysis.minp.x,
		y = cut_bottom_y,
		z = analysis.minp.z,
	}
	local rollback_maxp = {
		x = analysis.maxp.x,
		y = fill_top_y,
		z = analysis.maxp.z,
	}
	local rollback = snapshot_area(rollback_minp, rollback_maxp)
	local prep_ok, prep = perfectworld.structures.prepare_terrain(def, context.pos, rotation, analysis)
	if not prep_ok then
		restore_area(rollback)
		return false, prep
	end

	local placement_context = deep_copy(context)
	placement_context.prepared_position = prep.position
	local ok, placed, err
	if def.placement.type == "lua" then
		ok, placed, err = pcall(def.placement.generator, placement_context, def)
	else
		ok, placed, err = pcall(minetest.place_schematic, prep.position, def.placement.schematic, rotation, nil, true)
	end
	if not ok or placed == false then
		restore_area(rollback)
		return false, {reason = "placement_failed", error = tostring(err or placed)}
	end
	return true, {
		position = prep.position,
		rotation = rotation,
		minp = analysis.minp,
		maxp = analysis.maxp,
	}
end

local ok, err = perfectworld.structures.register("pw_farmstead_v1", {
	version = 1,
	size = {x = 15, y = 7, z = 14},
	origin = {x = 7, y = 0, z = 6},
	categories = {"settlement", "farm", "hamlet"},
	weight = 1,
	allowed_settlement_types = {"farm", "hamlet", "village"},
	rotations = {0, 90, 180, 270},
	terrain = {
		max_slope = 2,
		foundation_depth = 3,
		clearance_height = 8,
		modification_margin = 1,
		max_cut_depth = 3,
		max_fill_height = 4,
		building_footprint = {min_x = -3, max_x = 3, min_z = -3, max_z = 3},
	},
	connectors = {
		{type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 7}},
	},
	placement = {
		type = "lua",
		generator = farmstead_generator,
		preflight = farmstead_preflight,
	},
})
if not ok then
	minetest.log("error", "[pw_structures] failed to register pw_farmstead_v1: " .. tostring(err))
end

-- === Helper: generic small building generator ===
-- Used by house_small_v1, house_small_v2, barn_v1, well_v1.
-- opts fields:
--   wall_mat, roof_mat, floor_mat, door_mat, door_top_mat, window_mat (with fallbacks)
--   size = {x, y, z}, origin = {x, y, z}
--   wall_height, roof_height, roof_overlap
--   door_side, door_offset_x, door_offset_z
--   windows = {{x, y, z}, ...}
--   interior = {{x, y, z, mat}, ...}
--   building_footprint = {min_x, max_x, min_z, max_z}
--   terrain = {max_slope, foundation_depth, clearance_height, modification_margin, max_cut_depth, max_fill_height}
--   road_connector_side, road_connector_offset_x, road_connector_offset_z

	local function make_building_generator(opts)
	return function(context, def)
		local pos = context.prepared_position or context.pos
		local rotation = context.rotation or 0
		local mats = perfectworld.compat

		local wall_mat = mats.get_material(opts.wall_mat or "wall", {required = false}) or "air"
		local roof_mat = mats.get_material(opts.roof_mat or "roof", {required = false}) or "air"
		local floor_mat = mats.get_material(opts.floor_mat or "floor", {required = false}) or "air"
		local door_mat = mats.get_material(opts.door_mat or "door", {required = false}) or wall_mat
		local door_top_mat = mats.get_material(opts.door_top_mat or "door_top", {required = false}) or "air"
		local window_mat = mats.get_material(opts.window_mat or "window", {required = false}) or "air"
		local interior = opts.interior or {}

		local ws_x = (opts.size and opts.size.x) or (def.size and def.size.x) or 7
		local ws_y = (opts.size and opts.size.y) or (def.size and def.size.y) or 5
		local ws_z = (opts.size and opts.size.z) or (def.size and def.size.z) or 5

		-- Floor
		local fp = opts.building_footprint
		if fp then
			for x = fp.min_x, fp.max_x do
				for z = fp.min_z, fp.max_z do
					place_node(pos, rotation, {x = x, y = 0, z = z}, floor_mat)
				end
			end
		end

		-- Walls
		local wh = opts.wall_height or 3
		for y = 1, wh do
			for x = -math.floor(ws_x / 2), math.floor(ws_x / 2) do
				place_node(pos, rotation, {x = x, y = y, z = -math.floor(ws_z / 2)}, wall_mat)
				place_node(pos, rotation, {x = x, y = y, z = math.floor(ws_z / 2)}, wall_mat)
			end
			for z = -math.floor(ws_z / 2) + 1, math.floor(ws_z / 2) - 1 do
				place_node(pos, rotation, {x = -math.floor(ws_x / 2), y = y, z = z}, wall_mat)
				place_node(pos, rotation, {x = math.floor(ws_x / 2), y = y, z = z}, wall_mat)
			end
		end

		-- Door (replace wall node)
		local door_off = opts.door_offset or {x = 0, z = math.floor(ws_z / 2)}
		place_node(pos, rotation, {x = door_off.x, y = 1, z = door_off.z}, door_mat)
		place_node(pos, rotation, {x = door_off.x, y = 2, z = door_off.z}, door_top_mat)
		local door_back = {x = door_off.x, y = 1, z = door_off.z - 1}
		local back_in_fp = false
		if fp then
			back_in_fp = door_back.x >= fp.min_x and door_back.x <= fp.max_x and door_back.z >= fp.max_z
		end
		if not back_in_fp then
			-- clear a walkable space in front of door
			place_node(pos, rotation, {x = door_off.x, y = 1, z = door_off.z + 1}, "air")
			place_node(pos, rotation, {x = door_off.x, y = 2, z = door_off.z + 1}, "air")
		end

		-- Windows
		for _, w in ipairs(opts.windows or {}) do
			if window_mat ~= "air" then
				place_node(pos, rotation, w, window_mat)
			end
		end

		-- Roof
		local rh = opts.roof_height or (ws_y - wh - 1)
		local ro = opts.roof_overlap or 0
		for y = wh + 1, ws_y do
			local inset = (y == wh + 1) and ro or 0
			for x = -math.floor(ws_x / 2) + inset, math.floor(ws_x / 2) - inset do
				for z = -math.floor(ws_z / 2) + inset, math.floor(ws_z / 2) - inset do
					place_node(pos, rotation, {x = x, y = y, z = z}, roof_mat)
				end
			end
		end

		-- Interior
		for _, item in ipairs(interior) do
			local imat = mats.get_material(item.mat, {required = false}) or "air"
			if imat ~= "air" then
				place_node(pos, rotation, {x = item.x, y = item.y, z = item.z}, imat)
			end
		end

		return true
	end
end

-- === pw_house_small_v1: compact 7x5, low roof, 1 window ===
local house_small_v1_ok = perfectworld.structures.register("pw_house_small_v1", {
	version = 1,
	size = {x = 7, y = 5, z = 5},
	origin = {x = 3, y = 0, z = 2},
	categories = {"settlement", "house", "residential"},
	weight = 1,
	allowed_settlement_types = {"village", "hamlet"},
	rotations = {0, 90, 180, 270},
	terrain = {
		max_slope = 2, foundation_depth = 2, clearance_height = 5,
		modification_margin = 1, max_cut_depth = 3, max_fill_height = 3,
		building_footprint = {min_x = -2, max_x = 2, min_z = -2, max_z = 2},
	},
	connectors = {
		{type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 3}},
	},
	placement = {
		type = "lua",
		generator = make_building_generator({
			wall_mat = "wall", roof_mat = "roof", floor_mat = "floor",
			wall_height = 3, roof_height = 2, roof_overlap = 0,
			door_offset = {x = 0, z = 2},
			windows = {{x = -2, y = 2, z = 0}},
			interior = {
				{x = 1, y = 1, z = 0, mat = "light"},
				{x = -1, y = 1, z = -1, mat = "table"},
			},
			building_footprint = {min_x = -2, max_x = 2, min_z = -2, max_z = 2},
		}),
		preflight = function()
			-- ensure critical materials exist
			perfectworld.compat.get_material("wall")
			return true
		end,
	},
})
if not house_small_v1_ok then
	minetest.log("error", "[pw_structures] failed to register pw_house_small_v1")
end

-- === pw_house_small_v2: wider 9x6, higher walls, 2 windows, door on long side ===
local house_small_v2_ok = perfectworld.structures.register("pw_house_small_v2", {
	version = 1,
	size = {x = 9, y = 6, z = 5},
	origin = {x = 4, y = 0, z = 2},
	categories = {"settlement", "house", "residential"},
	weight = 1,
	allowed_settlement_types = {"village", "hamlet"},
	rotations = {0, 90, 180, 270},
	terrain = {
		max_slope = 2, foundation_depth = 2, clearance_height = 6,
		modification_margin = 1, max_cut_depth = 3, max_fill_height = 3,
		building_footprint = {min_x = -3, max_x = 3, min_z = -2, max_z = 2},
	},
	connectors = {
		{type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 3}},
	},
	placement = {
		type = "lua",
		generator = make_building_generator({
			wall_mat = "wall", roof_mat = "roof", floor_mat = "floor",
			wall_height = 4, roof_height = 2, roof_overlap = 1,
			door_offset = {x = 0, z = 2},
			windows = {{x = -3, y = 2, z = 0}, {x = 3, y = 2, z = 0}},
			interior = {
				{x = 0, y = 1, z = 0, mat = "light"},
				{x = 2, y = 1, z = 0, mat = "container"},
			},
			building_footprint = {min_x = -3, max_x = 3, min_z = -2, max_z = 2},
		}),
		preflight = function()
			perfectworld.compat.get_material("wall")
			return true
		end,
	},
})
if not house_small_v2_ok then
	minetest.log("error", "[pw_structures] failed to register pw_house_small_v2")
end

-- === pw_barn_v1: wide 9x6 storage building, no windows, large door ===
local barn_v1_ok = perfectworld.structures.register("pw_barn_v1", {
	version = 1,
	size = {x = 9, y = 6, z = 7},
	origin = {x = 4, y = 0, z = 3},
	categories = {"settlement", "farmyard", "storage"},
	weight = 1,
	allowed_settlement_types = {"village"},
	rotations = {0, 90, 180, 270},
	terrain = {
		max_slope = 2, foundation_depth = 2, clearance_height = 6,
		modification_margin = 1, max_cut_depth = 3, max_fill_height = 3,
		building_footprint = {min_x = -3, max_x = 3, min_z = -3, max_z = 3},
	},
	connectors = {
		{type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 4}},
	},
	placement = {
		type = "lua",
		generator = make_building_generator({
			wall_mat = "wall", roof_mat = "roof", floor_mat = "floor",
			wall_height = 4, roof_height = 2, roof_overlap = 1,
			door_offset = {x = 0, z = 3},
			windows = {},
			interior = {
				{x = -2, y = 1, z = -1, mat = "container"},
				{x = 2, y = 1, z = -1, mat = "container"},
			},
			building_footprint = {min_x = -3, max_x = 3, min_z = -3, max_z = 3},
		}),
		preflight = function()
			perfectworld.compat.get_material("wall")
			return true
		end,
	},
})
if not barn_v1_ok then
	minetest.log("error", "[pw_structures] failed to register pw_barn_v1")
end

-- === pw_well_v1: small 3x4 public structure, open ===
local well_v1_ok = perfectworld.structures.register("pw_well_v1", {
	version = 1,
	size = {x = 3, y = 4, z = 3},
	origin = {x = 1, y = 0, z = 1},
	categories = {"settlement", "public", "well"},
	weight = 1,
	allowed_settlement_types = {"village", "hamlet"},
	rotations = {0},
	terrain = {
		max_slope = 1, foundation_depth = 1, clearance_height = 4,
		modification_margin = 0, max_cut_depth = 2, max_fill_height = 2,
		building_footprint = {min_x = -1, max_x = 1, min_z = -1, max_z = 1},
	},
	connectors = {},
	placement = {
		type = "lua",
		generator = function(context, def)
			local pos = context.prepared_position or context.pos
			local rotation = context.rotation or 0
			local cobble = perfectworld.compat.get_material("cobble")
			local water = perfectworld.compat.get_material("water")

			-- 4 corner pillars
			for y = 1, 3 do
				place_node(pos, rotation, {x = -1, y = y, z = -1}, cobble)
				place_node(pos, rotation, {x = 1, y = y, z = -1}, cobble)
				place_node(pos, rotation, {x = -1, y = y, z = 1}, cobble)
				place_node(pos, rotation, {x = 1, y = y, z = 1}, cobble)
			end
			-- top cross-beams
			place_node(pos, rotation, {x = 0, y = 4, z = -1}, cobble)
			place_node(pos, rotation, {x = 0, y = 4, z = 1}, cobble)
			place_node(pos, rotation, {x = -1, y = 4, z = 0}, cobble)
			place_node(pos, rotation, {x = 1, y = 4, z = 0}, cobble)
			-- water in the center
			if water ~= "air" then
				place_node(pos, rotation, {x = 0, y = 0, z = 0}, water)
				place_node(pos, rotation, {x = 0, y = 1, z = 0}, water)
				place_node(pos, rotation, {x = 0, y = 2, z = 0}, water)
			end
			return true
		end,
		preflight = function()
			perfectworld.compat.get_material("cobble")
			return true
		end,
	},
})
if not well_v1_ok then
	minetest.log("error", "[pw_structures] failed to register pw_well_v1")
end

minetest.log("action", "[pw_structures] loaded")
