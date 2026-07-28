perfectworld = perfectworld or {}
perfectworld.structures = perfectworld.structures or {}

local structures = {}

local deep_copy = perfectworld.core.deep_copy

local function material(name, opts)
	return perfectworld.compat.get_material(name, opts or {required = true})
end

--- Resolve a material through the settlement's biome palette when one is given.
-- `palette_key` names an entry of a `pw_compat_mcl` family palette; `role` is
-- the generic material role used when there is no palette (or the palette node
-- is not registered in this game).
function perfectworld.structures.palette_material(palette, palette_key, role)
	if palette and palette_key then
		local node_name = palette[palette_key]
		if node_name and (node_name == "air" or minetest.registered_nodes[node_name]) then
			return node_name
		end
	end
	return perfectworld.compat.get_material(role, {required = false})
end
local palette_material = perfectworld.structures.palette_material

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

local function is_terrain_cover(node_name)
	if perfectworld.compat and perfectworld.compat.classify_node then
		return perfectworld.compat.classify_node(node_name).vegetation
	end
	local def = minetest.registered_nodes[node_name]
	local groups = (def and def.groups) or {}
	return (groups.flora or groups.leaves or groups.plant
		or groups.tree or groups.log or 0) > 0
		or (def and def.buildable_to == true) or false
end

local function find_surface_y(x, z)
	for y = 256, -64, -1 do
		local node = minetest.get_node({x = x, y = y, z = z})
		if node.name ~= "air" and node.name ~= "ignore"
			and not is_terrain_cover(node.name) then
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

function perfectworld.structures.prepare_terrain(def, origin, rotation, analysis, palette)
	local foundation = palette_material(palette, "foundation", "foundation")
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
				-- On a slope the downhill side of a footprint can sit above open
				-- air. Carry the foundation down as a plinth until it meets solid
				-- ground so the building never floats. Bounded in depth and laid
				-- only under the building itself, so it cannot grow into an
				-- artificial platform.
				local plinth_y = cut_bottom_y - 1
				local plinth_floor = plinth_y - (def.terrain.max_plinth_depth or 12)
				while plinth_y >= plinth_floor do
					local existing = minetest.get_node({x = x, y = plinth_y, z = z}).name
					if existing ~= "air" and existing ~= "ignore" then break end
					minetest.set_node({x = x, y = plinth_y, z = z}, {name = foundation})
					plinth_y = plinth_y - 1
				end
			end
			-- air clearance: apply with blend
			for y = fill_bottom_y, target_top do
				local p = {x = x, y = y, z = z}
				if y <= orig_surface and blend < 0.5 then
					-- outside footprint blending zone: only clear replaceable
					if is_replaceable(p) then
						local node_name = minetest.get_node(p).name
						if is_terrain_cover(node_name) then
							minetest.set_node(p, {name = air})
						end
						-- leave non-replaceable non-flora nodes untouched
					end
				else
					if not is_replaceable(p) then
						local node_name = minetest.get_node(p).name
						if is_terrain_cover(node_name) then
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
	-- Per-placement terrain relaxation (hillside lots need deeper cuts than the
	-- structure's default contract allows). Copy first: `def` is the registry entry.
	if type(context.terrain_overrides) == "table" then
		def = deep_copy(def)
		for key, value in pairs(context.terrain_overrides) do
			def.terrain[key] = value
		end
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
	local prep_ok, prep = perfectworld.structures.prepare_terrain(def, context.pos, rotation, analysis, context.palette)
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

-- === Building construction kit ===
--
-- Modelled on the vanilla plains village houses (Minecraft Wiki,
-- Village/Structure/Blueprints): a cobble plinth, timber corner posts, plank
-- infill, glass-pane windows on every wall, and a pitched roof built out of
-- stairs with a slab ridge and a one-block eave. Boxes with flat lids are not
-- houses.

local function pal(palette, key, role)
  return palette_material(palette, key, role)
end

--- Place a node whose facedir must point along a direction given in the
-- structure's own local space (so it survives rotation).
local function place_facing(pos, rotation, local_pos, node_name, local_dir)
  if node_name == "air" then return end
  local world_dir = perfectworld.structures.rotate_point(local_dir, rotation)
  place_node(pos, rotation, local_pos, node_name,
    minetest.dir_to_facedir({x = world_dir.x, y = 0, z = world_dir.z}))
end

local function fill_box(pos, rotation, x1, y1, z1, x2, y2, z2, node_name)
  if node_name == nil then return end
  for x = math.min(x1, x2), math.max(x1, x2) do
    for y = math.min(y1, y2), math.max(y1, y2) do
      for z = math.min(z1, z2), math.max(z1, z2) do
        place_node(pos, rotation, {x = x, y = y, z = z}, node_name)
      end
    end
  end
end

--- Pitched roof: ridge along Z, slopes falling in -X and +X, one-block eaves,
-- slab ridge cap, filled gable triangles at both ends.
local function build_pitched_roof(pos, rotation, opts)
  local half_w, half_d = opts.half_w, opts.half_d
  local base_y = opts.base_y
  local stair = opts.stair
  local slab = opts.slab
  local gable = opts.gable

  for step = 0, half_w + 1 do
    local y = base_y + step
    local left = -half_w - 1 + step
    local right = half_w + 1 - step
    if left > right then break end

    if left == right then
      for z = -half_d - 1, half_d + 1 do
        place_node(pos, rotation, {x = left, y = y, z = z}, slab)
      end
      break
    end

    for z = -half_d - 1, half_d + 1 do
      place_facing(pos, rotation, {x = left, y = y, z = z}, stair, {x = -1, y = 0, z = 0})
      place_facing(pos, rotation, {x = right, y = y, z = z}, stair, {x = 1, y = 0, z = 0})
    end

    -- Close the two gable triangles so the attic is not open to the weather.
    for x = left + 1, right - 1 do
      place_node(pos, rotation, {x = x, y = y, z = -half_d}, gable)
      place_node(pos, rotation, {x = x, y = y, z = half_d}, gable)
    end
  end
end

--- Windows spaced along a wall run, skipping corners and the door column.
local function window_offsets(span, skip)
  local offsets = {}
  for value = -span + 1, span - 1 do
    if value ~= skip and (value + span) % 2 == 0 then
      table.insert(offsets, value)
    end
  end
  return offsets
end

--- The shared house/barn builder.
--
-- opts: width, depth, wall_height, door_offset_x, windows (bool),
--       plinth (bool), interior (function), wide_door (bool)
local function make_building_generator(opts)
  return function(context, def)
    local pos = context.prepared_position or context.pos
    local rotation = context.rotation or 0
    local palette = context.palette

    local wall = pal(palette, "wall_primary", "wall")
    local base = pal(palette, "wall_secondary", "foundation")
    local post = pal(palette, "wall_post", "tree")
    local floor = pal(palette, "floor_block", "floor")
    local stair = pal(palette, "roof_stair", "roof")
    local slab = pal(palette, "roof_slab", "roof")
    local window = pal(palette, "window", "window")
    local door = perfectworld.compat.get_material("door", {required = false})
    local door_top = perfectworld.compat.get_material("door_top", {required = false})

    local width = opts.width
    local depth = opts.depth
    local height = opts.wall_height or 4
    local half_w = math.floor(width / 2)
    local half_d = math.floor(depth / 2)
    local door_x = opts.door_offset_x or 0

    -- Floor, and a solid course directly beneath it so nothing is ever
    -- standing on air once the plinth is carried down by prepare_terrain.
    fill_box(pos, rotation, -half_w, 0, -half_d, half_w, 0, half_d, floor)
    fill_box(pos, rotation, -half_w, -1, -half_d, half_w, -1, half_d, base)

    -- Clear the interior volume before building: leftovers from terrain
    -- preparation would otherwise be sealed inside the walls.
    fill_box(pos, rotation, -half_w, 1, -half_d, half_w, height + 1, half_d, "air")

    for y = 1, height do
      local course = wall
      if opts.plinth ~= false and y == 1 then course = base end
      for x = -half_w, half_w do
        place_node(pos, rotation, {x = x, y = y, z = -half_d}, course)
        place_node(pos, rotation, {x = x, y = y, z = half_d}, course)
      end
      for z = -half_d + 1, half_d - 1 do
        place_node(pos, rotation, {x = -half_w, y = y, z = z}, course)
        place_node(pos, rotation, {x = half_w, y = y, z = z}, course)
      end
    end

    -- Timber corner posts, full height.
    for y = 1, height do
      for _, corner in ipairs({
        {x = -half_w, z = -half_d}, {x = half_w, z = -half_d},
        {x = -half_w, z = half_d}, {x = half_w, z = half_d},
      }) do
        place_node(pos, rotation, {x = corner.x, y = y, z = corner.z}, post)
      end
    end

    -- Windows on every wall, at head height, evenly spaced.
    if opts.windows ~= false and window ~= "air" then
      for _, x in ipairs(window_offsets(half_w, door_x)) do
        place_node(pos, rotation, {x = x, y = 2, z = half_d}, window)
        place_node(pos, rotation, {x = x, y = 2, z = -half_d}, window)
      end
      for _, z in ipairs(window_offsets(half_d, nil)) do
        place_node(pos, rotation, {x = -half_w, y = 2, z = z}, window)
        place_node(pos, rotation, {x = half_w, y = 2, z = z}, window)
      end
      -- Taller houses get a second row, which reads as a real facade.
      if height >= 4 then
        for _, x in ipairs(window_offsets(half_w, door_x)) do
          place_node(pos, rotation, {x = x, y = 3, z = half_d}, window)
          place_node(pos, rotation, {x = x, y = 3, z = -half_d}, window)
        end
      end
    end

    -- Doorway on the +Z wall (the connector side), sill level with the floor.
    local door_width = opts.wide_door and 1 or 0
    for dx = -door_width, door_width do
      place_node(pos, rotation, {x = door_x + dx, y = 1, z = half_d}, "air")
      place_node(pos, rotation, {x = door_x + dx, y = 2, z = half_d}, "air")
      if opts.wide_door and height >= 4 then
        place_node(pos, rotation, {x = door_x + dx, y = 3, z = half_d}, "air")
      end
    end
    if not opts.wide_door then
      place_facing(pos, rotation, {x = door_x, y = 1, z = half_d}, door, {x = 0, y = 0, z = 1})
      place_facing(pos, rotation, {x = door_x, y = 2, z = half_d}, door_top, {x = 0, y = 0, z = 1})
    end
    -- Porch: the doorstep under the eave, and a second step clear of the
    -- roof overhang. The connector sits on the outer one, so nothing
    -- overhangs the point a villager walks to.
    for dz = 1, 2 do
      place_node(pos, rotation, {x = door_x, y = 0, z = half_d + dz}, base)
      place_node(pos, rotation, {x = door_x, y = 1, z = half_d + dz}, "air")
      place_node(pos, rotation, {x = door_x, y = 2, z = half_d + dz}, "air")
    end

    -- Ceiling over the living space, then the roof itself.
    fill_box(pos, rotation, -half_w + 1, height + 1, -half_d + 1,
      half_w - 1, height + 1, half_d - 1, floor)
    build_pitched_roof(pos, rotation, {
      half_w = half_w, half_d = half_d, base_y = height + 1,
      stair = stair, slab = slab, gable = wall,
    })

    if opts.interior then
      opts.interior({
        pos = pos, rotation = rotation, palette = palette,
        half_w = half_w, half_d = half_d, height = height, door_x = door_x,
        place = function(local_pos, node_name, param2)
          place_node(pos, rotation, local_pos, node_name, param2)
        end,
        place_facing = function(local_pos, node_name, local_dir)
          place_facing(pos, rotation, local_pos, node_name, local_dir)
        end,
      })
    end

    return true
  end
end

--- Furniture common to dwellings: bed, hearth light, table, storage, work top.
local function dwelling_interior(ctx)
  local palette = ctx.palette
  local hw, hd = ctx.half_w, ctx.half_d
  local slab = pal(palette, "roof_slab", "roof")
  local fence = pal(palette, "fence", "fence")

  local bed_bottom = "mcl_beds:bed_red_bottom"
  local bed_top = "mcl_beds:bed_red_top"
  if minetest.registered_nodes[bed_bottom] and minetest.registered_nodes[bed_top] then
    -- Head against the back wall, foot towards the room.
    ctx.place_facing({x = -hw + 1, y = 1, z = -hd + 1}, bed_bottom, {x = 0, y = 0, z = 1})
    ctx.place_facing({x = -hw + 1, y = 1, z = -hd + 2}, bed_top, {x = 0, y = 0, z = 1})
  end

  local table_top = slab
  if fence ~= "air" then
    ctx.place({x = hw - 1, y = 1, z = -hd + 1}, fence)
    ctx.place({x = hw - 1, y = 2, z = -hd + 1}, table_top)
  end

  local crafting = "mcl_crafting_table:crafting_table"
  if minetest.registered_nodes[crafting] then
    ctx.place({x = hw - 1, y = 1, z = hd - 1}, crafting)
  end

  local chest = perfectworld.compat.get_material("container", {required = false})
  if chest ~= "air" then
    ctx.place_facing({x = -hw + 1, y = 1, z = hd - 1}, chest, {x = 0, y = 0, z = 1})
  end

  local lantern = "mcl_lanterns:lantern_floor"
  local light = minetest.registered_nodes[lantern] and lantern
    or perfectworld.compat.get_material("light", {required = false})
  if light ~= "air" then
    ctx.place({x = 0, y = ctx.height, z = 0}, light)
  end

  local pot = "mcl_flowers:poppy"
  if minetest.registered_nodes[pot] then
    ctx.place({x = 0, y = 1, z = -hd + 1}, pot)
  end
end

--- Storage buildings: hay, barrels, no bed.
local function barn_interior(ctx)
  local hw, hd = ctx.half_w, ctx.half_d
  local hay = "mcl_farming:hay_block"
  if minetest.registered_nodes[hay] then
    for x = -hw + 1, -hw + 2 do
      for z = -hd + 1, hd - 1 do
        ctx.place({x = x, y = 1, z = z}, hay)
      end
    end
    ctx.place({x = -hw + 1, y = 2, z = -hd + 1}, hay)
  end
  local barrel = "mcl_barrels:barrel_closed"
  if minetest.registered_nodes[barrel] then
    ctx.place({x = hw - 1, y = 1, z = -hd + 1}, barrel)
    ctx.place({x = hw - 1, y = 1, z = -hd + 2}, barrel)
  end
  local chest = perfectworld.compat.get_material("container", {required = false})
  if chest ~= "air" then
    ctx.place_facing({x = hw - 1, y = 1, z = hd - 1}, chest, {x = 0, y = 0, z = 1})
  end
  local light = perfectworld.compat.get_material("light", {required = false})
  if light ~= "air" then
    ctx.place({x = 0, y = ctx.height, z = 0}, light)
  end
end

local function house_terrain(extra)
  -- Vanilla villages cut and fill to make their plots; so do we. The
  -- modified volume stays inside the footprint plus one block of margin, so
  -- a deeper cut buys buildable ground without carving a platform.
  local terrain = {
    max_slope = 3, foundation_depth = 3, clearance_height = 8,
    modification_margin = 1, max_cut_depth = 4, max_fill_height = 4,
    max_plinth_depth = 12,
  }
  for key, value in pairs(extra or {}) do terrain[key] = value end
  return terrain
end

local function register_building(name, spec)
  local half_w = math.floor(spec.width / 2)
  local half_d = math.floor(spec.depth / 2)
  local roof_height = half_w + 2
  local ok = perfectworld.structures.register(name, {
    version = 2,
    size = {x = spec.width + 2, y = spec.wall_height + roof_height + 1, z = spec.depth + 2},
    origin = {x = half_w + 1, y = 0, z = half_d + 1},
    categories = spec.categories,
    weight = 1,
    allowed_settlement_types = {"village", "hamlet"},
    rotations = {0, 90, 180, 270},
    terrain = house_terrain({
      building_footprint = {
        min_x = -half_w, max_x = half_w,
        min_z = -half_d, max_z = half_d + 2,
      },
    }),
    connectors = {
      {type = "road", side = "south", offset = 0,
       offset_pos = {x = spec.door_offset_x or 0, y = 0, z = half_d + 2}},
    },
    placement = {
      type = "lua",
      generator = make_building_generator(spec),
      preflight = function()
        perfectworld.compat.get_material("wall")
        return true
      end,
    },
  })
  if not ok then
    minetest.log("error", "[pw_structures] failed to register " .. name)
  end
end

register_building("pw_house_small_v1", {
  width = 5, depth = 5, wall_height = 4, door_offset_x = 0,
  categories = {"settlement", "house", "residential"},
  interior = dwelling_interior,
})

register_building("pw_house_small_v2", {
  width = 7, depth = 5, wall_height = 4, door_offset_x = -1,
  categories = {"settlement", "house", "residential"},
  interior = dwelling_interior,
})

register_building("pw_house_long_v1", {
  width = 9, depth = 5, wall_height = 4, door_offset_x = 1,
  categories = {"settlement", "house", "residential"},
  interior = dwelling_interior,
})

register_building("pw_house_tall_v1", {
  width = 5, depth = 7, wall_height = 5, door_offset_x = 0,
  categories = {"settlement", "house", "residential"},
  interior = dwelling_interior,
})

--- Farm interior: storage and a work top, no bed — the field is outside.
local function farm_interior(ctx)
  local hw, hd = ctx.half_w, ctx.half_d
  local hay = "mcl_farming:hay_block"
  if minetest.registered_nodes[hay] then
    ctx.place({x = -hw + 1, y = 1, z = -hd + 1}, hay)
    ctx.place({x = -hw + 1, y = 1, z = -hd + 2}, hay)
    ctx.place({x = -hw + 1, y = 2, z = -hd + 1}, hay)
  end
  local composter = "mcl_composters:composter"
  if minetest.registered_nodes[composter] then
    ctx.place({x = hw - 1, y = 1, z = -hd + 1}, composter)
  end
  local crafting = "mcl_crafting_table:crafting_table"
  if minetest.registered_nodes[crafting] then
    ctx.place({x = hw - 1, y = 1, z = hd - 1}, crafting)
  end
  local bed_bottom, bed_top = "mcl_beds:bed_red_bottom", "mcl_beds:bed_red_top"
  if minetest.registered_nodes[bed_bottom] then
    ctx.place_facing({x = 0, y = 1, z = -hd + 1}, bed_bottom, {x = 0, y = 0, z = 1})
    ctx.place_facing({x = 0, y = 1, z = -hd + 2}, bed_top, {x = 0, y = 0, z = 1})
  end
  local chest = perfectworld.compat.get_material("container", {required = false})
  if chest ~= "air" then
    ctx.place_facing({x = -hw + 1, y = 1, z = hd - 1}, chest, {x = 0, y = 0, z = 1})
  end
  local lantern = "mcl_lanterns:lantern_floor"
  local light = minetest.registered_nodes[lantern] and lantern
    or perfectworld.compat.get_material("light", {required = false})
  if light ~= "air" then
    ctx.place({x = 0, y = ctx.height, z = 0}, light)
  end
end

register_building("pw_farmstead_v1", {
  width = 7, depth = 7, wall_height = 4, door_offset_x = 0,
  categories = {"settlement", "farm", "hamlet"},
  interior = farm_interior,
})

register_building("pw_barn_v1", {
  width = 9, depth = 7, wall_height = 5, door_offset_x = 0,
  wide_door = true, windows = false,
  categories = {"settlement", "farmyard", "storage"},
  interior = barn_interior,
})

-- === pw_well_v1: a real well — the water is boxed in and cannot escape ===
local well_ok = perfectworld.structures.register("pw_well_v1", {
  version = 2,
  size = {x = 5, y = 6, z = 5},
  origin = {x = 2, y = 0, z = 2},
  categories = {"settlement", "public", "well"},
  weight = 1,
  allowed_settlement_types = {"village", "hamlet"},
  rotations = {0, 90, 180, 270},
  terrain = house_terrain({
    max_slope = 2, foundation_depth = 3, clearance_height = 6,
    building_footprint = {min_x = -2, max_x = 2, min_z = -2, max_z = 2},
  }),
  connectors = {
    {type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 2}},
  },
  placement = {
    type = "lua",
    generator = function(context, def)
      local pos = context.prepared_position or context.pos
      local rotation = context.rotation or 0
      local palette = context.palette
      local rim = pal(palette, "foundation", "cobble")
      local deck = pal(palette, "wall_secondary", "cobble")
      local slab = pal(palette, "roof_slab", "roof")
      local post = pal(palette, "wall_post", "tree")
      local water = perfectworld.compat.get_material("water", {required = false})

      -- Paved apron so the well sits in a small square, not in the mud.
      fill_box(pos, rotation, -2, 0, -2, 2, 0, 2, deck)
      -- Watertight shaft: solid floor and four solid sides around one source.
      fill_box(pos, rotation, -1, -1, -1, 1, -1, 1, rim)
      fill_box(pos, rotation, -1, 0, -1, 1, 1, 1, rim)
      fill_box(pos, rotation, -1, 2, -1, 1, 3, 1, "air")
      for y = 0, 1 do
        for _, side in ipairs({
          {x = -1, z = 0}, {x = 1, z = 0}, {x = 0, z = -1}, {x = 0, z = 1},
          {x = -1, z = -1}, {x = 1, z = -1}, {x = -1, z = 1}, {x = 1, z = 1},
        }) do
          place_node(pos, rotation, {x = side.x, y = y, z = side.z}, rim)
        end
      end
      if water ~= "air" then
        -- One source, one block, enclosed on all six sides but the top.
        place_node(pos, rotation, {x = 0, y = 0, z = 0}, water)
        place_node(pos, rotation, {x = 0, y = 1, z = 0}, water)
      end

      -- Four posts and a slab canopy.
      for y = 2, 3 do
        for _, corner in ipairs({
          {x = -1, z = -1}, {x = 1, z = -1}, {x = -1, z = 1}, {x = 1, z = 1},
        }) do
          place_node(pos, rotation, {x = corner.x, y = y, z = corner.z}, post)
        end
      end
      fill_box(pos, rotation, -1, 4, -1, 1, 4, 1, slab)
      return true
    end,
    preflight = function()
      perfectworld.compat.get_material("cobble")
      return true
    end,
  },
})
if not well_ok then
  minetest.log("error", "[pw_structures] failed to register pw_well_v1")
end

local register_specialized = dofile(
  minetest.get_modpath("pw_structures") .. "/village_specialized.lua")
register_specialized({register_building = register_building})

minetest.log("action", "[pw_structures] loaded")
