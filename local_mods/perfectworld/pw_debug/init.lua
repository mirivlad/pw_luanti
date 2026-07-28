perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.debug = perfectworld.debug or {}

local function get_test_player()
  return minetest.settings:get("perfectworld.test_player") or "pwbot"
end

local function safe_string(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return tostring(v)
end

local function active_modules()
  local modules = {}
  for _, entry in ipairs({
    {"core", perfectworld.core},
    {"planner", perfectworld.planner},
    {"structures", perfectworld.structures},
    {"roads", perfectworld.roads},
    {"settlements", perfectworld.settlements},
    {"population", perfectworld.population},
    {"compat_mcl", perfectworld.compat},
    {"debug", perfectworld.debug},
  }) do
    if entry[2] then
      table.insert(modules, entry[1])
    end
  end
  table.sort(modules)
  return modules
end

minetest.register_chatcommand("pw_status", {
  params = "",
  description = "Show PerfectWorld version and configuration",
  privs = {interact = true},
  func = function(name)
    local structures = perfectworld.structures and perfectworld.structures.list() or {}
    local info = {
      "version=" .. safe_string(perfectworld.VERSION or "?"),
      "api=perfectworld",
      "planner_version=" .. safe_string(perfectworld.PLANNER_VERSION or "?"),
      "region_size=" .. safe_string(perfectworld.REGION_SIZE or "?"),
      "world_seed_masked=" .. (perfectworld.world_seed_string and (perfectworld.world_seed_string:sub(1, 8) .. "...") or "?"),
      "world_format_version=" .. safe_string(perfectworld.WORLD_FORMAT_VERSION or "?"),
      "materialization_enabled=" .. tostring(perfectworld.materialization_enabled ~= false),
      "materialization_error=" .. safe_string(perfectworld.world_format_error or ""),
      "structures=" .. #structures,
      "modules=" .. table.concat(active_modules(), ","),
    }
    return true, table.concat(info, "\n")
  end,
})

minetest.register_chatcommand("pw_region", {
  params = "",
  description = "Show the region the calling player is standing in",
  privs = {interact = true},
  func = function(name)
    local player = minetest.get_player_by_name(name)
    if not player then return false, "Player not found" end
    local pos = player:get_pos()
    if not pos then return false, "No position" end
    local rx, rz = perfectworld.get_region_coords(pos)
    local rid = perfectworld.get_region_id(rx, rz)
    local plan = perfectworld.planner and perfectworld.planner.plan_region(rx, rz)
    local info = {
      "region_id=" .. rid,
      "rx=" .. rx,
      "rz=" .. rz,
      "minp=" .. (plan and minetest.pos_to_string(plan.minp) or "?"),
      "maxp=" .. (plan and minetest.pos_to_string(plan.maxp) or "?"),
      "settlement_candidates=" .. (plan and #(plan.settlement_candidates or {}) or 0),
      "road_anchors=" .. (plan and #(plan.road_anchors or {}) or 0),
    }
    return true, table.concat(info, "\n")
  end,
})

minetest.register_chatcommand("pw_plan", {
  params = "[rx] [rz]",
  description = "Show the plan for current region or specified region",
  privs = {interact = true},
  func = function(name, params)
    local rx, rz
    if params and params ~= "" then
      local rx_str, rz_str = params:match("^(%-?%d+)%s+(%-?%d+)$")
      if not rx_str then return false, "Usage: /pw_plan <rx> <rz>" end
      rx, rz = tonumber(rx_str), tonumber(rz_str)
    else
      local player = minetest.get_player_by_name(name)
      if not player then return false, "Player not found" end
      local pos = player:get_pos()
      if not pos then return false, "No position" end
      rx, rz = perfectworld.get_region_coords(pos)
    end
    local plan = perfectworld.planner and perfectworld.planner.plan_region(rx, rz)
    if not plan then return false, "No plan available" end
    local lines = {"plan_id=" .. plan.id}
    table.insert(lines, "rx=" .. tostring(plan.rx))
    table.insert(lines, "rz=" .. tostring(plan.rz))
    table.insert(lines, "planner_version=" .. tostring(plan.planner_version))
    table.insert(lines, "settlement_candidates=" .. #(plan.settlement_candidates or {}))
    table.insert(lines, "road_anchors=" .. #(plan.road_anchors or {}))
    for _, sc in ipairs(plan.settlement_candidates or {}) do
      table.insert(lines, table.concat({
        "candidate_id=" .. sc.id,
        "type=" .. sc.type,
        "x=" .. sc.x,
        "z=" .. sc.z,
        "priority=" .. sc.priority,
        "structure_name=" .. tostring(sc.structure_name or ""),
        "structure_id=" .. tostring(sc.structure_id or ""),
        "rotation=" .. tostring(sc.rotation or 0),
        "connection_required=" .. tostring(sc.connection_required == true),
        "status=" .. sc.status,
      }, " "))
    end
    return true, table.concat(lines, "\n")
  end,
})

minetest.register_chatcommand("pw_structure", {
  params = "<structure_id>",
  description = "Show a materialized PerfectWorld structure record",
  privs = {interact = true},
  func = function(name, params)
    local structure_id = params and params:match("^(%S+)$")
    if not structure_id then
      return false, "Usage: /pw_structure <structure_id>"
    end
    local record = perfectworld.planner and perfectworld.planner.get_structure(structure_id)
    if not record then
      return false, "structure_not_found=" .. structure_id
    end
    local pos = record.position and minetest.pos_to_string(record.position) or "?"
    return true, table.concat({
      "structure_id=" .. tostring(record.structure_id),
      "structure_name=" .. tostring(record.structure_name),
      "definition_version=" .. tostring(record.definition_version),
      "status=" .. tostring(record.status),
      "position=" .. pos,
      "rotation=" .. tostring(record.rotation),
      "region_id=" .. tostring(record.region_id),
      "settlement_id=" .. tostring(record.settlement_id),
    }, "\n")
  end,
})

minetest.register_chatcommand("pw_prepare_shot", {
  params = "[player] <structure_id> [yaw] [pitch]",
  description = "Teleport a player near a PerfectWorld structure for development screenshots",
  privs = {server = true},
  func = function(name, params)
    local first, second, third, fourth = (params or ""):match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)$")
    if not first then
      return false, "Usage: /pw_prepare_shot [player] <structure_id>"
    end
    local player_name = second ~= "" and first or name
    local structure_id = second ~= "" and second or first
    local yaw = tonumber(third) or 3.9
    local pitch = tonumber(fourth) or 0.75
    if player_name == "" then
      return false, "Usage from console: /pw_prepare_shot <player> <structure_id>"
    end
    local player = minetest.get_player_by_name(player_name)
    if not player then
      return false, "player_not_found=" .. tostring(player_name)
    end
    local record = perfectworld.planner and perfectworld.planner.get_structure(structure_id)
    if not record or not record.position then
      return false, "structure_not_found=" .. tostring(structure_id)
    end
    local pos = record.position
    local camera = {x = pos.x + 14, y = pos.y + 12, z = pos.z + 14}
    player:set_hp(20)
    if player.set_armor_groups then
      player:set_armor_groups({immortal = 1})
    end
    if player.set_physics_override then
      player:set_physics_override({gravity = 0})
    end
    player:set_pos(camera)
    if player.set_look_horizontal then
      player:set_look_horizontal(yaw)
    end
    if player.set_look_vertical then
      player:set_look_vertical(pitch)
    end
    minetest.set_timeofday(0.35)
    return true, table.concat({
      "prepared=true",
      "player=" .. player_name,
      "structure_id=" .. tostring(record.structure_id),
      "camera=" .. minetest.pos_to_string(camera),
      "target=" .. minetest.pos_to_string(pos),
      "yaw=" .. tostring(yaw),
      "pitch=" .. tostring(pitch),
    }, "\n")
  end,
})

minetest.register_chatcommand("pw_materialize", {
  params = "<rx> <rz> <index> [force]",
  description = "Materialize a planned PerfectWorld structure for development checks",
  privs = {server = true},
  func = function(name, params)
    local rx_s, rz_s, index_s, force_s = (params or ""):match("^(%-?%d+)%s+(%-?%d+)%s+(%d+)%s*(%S*)$")
    if not rx_s then
      return false, "Usage: /pw_materialize <rx> <rz> <index> [force]"
    end
    local rx = tonumber(rx_s)
    local rz = tonumber(rz_s)
    local index = tonumber(index_s)
    local force = force_s == "force"
    if force then
      local plan = perfectworld.planner.plan_region(rx, rz)
      local candidate = (plan.settlement_candidates or {})[(index or 0) + 1]
      local def = candidate and perfectworld.structures.get(candidate.structure_name or "pw_farmstead_v1")
      if candidate and def then
        local minp, maxp = perfectworld.structures.get_footprint(def, {x = candidate.x, y = 0, z = candidate.z}, candidate.rotation or 0)
        minp = {x = minp.x - 2, y = -8, z = minp.z - 2}
        maxp = {x = maxp.x + 2, y = 256, z = maxp.z + 2}
        if minetest.load_area then
          pcall(minetest.load_area, minp, maxp)
        end
        local ground = perfectworld.compat.get_material("ground")
        for x = minp.x, maxp.x do
          for z = minp.z, maxp.z do
            minetest.set_node({x = x, y = -1, z = z}, {name = ground})
            for y = 0, 256 do
              minetest.set_node({x = x, y = y, z = z}, {name = "air"})
            end
          end
        end
      end
    end
    local ok, result = perfectworld.planner.materialize_region_candidate(
      rx,
      rz,
      index,
      {force = force}
    )
    if not ok then
      return false, "materialized=false reason=" .. tostring(result)
    end
    if result.settlement then
      return true, table.concat({
        "village_materialized=true",
        "settlement_id=" .. tostring(result.settlement.settlement_id),
        "archetype=" .. tostring(result.settlement.archetype),
        "fingerprint=" .. tostring(result.settlement.village_fingerprint),
        "lot_count=" .. tostring(result.settlement.lot_count),
        "structure_ids=" .. table.concat(result.settlement.structure_ids or {}, ","),
        "road_ids=" .. table.concat(result.settlement.road_ids or {}, ","),
      }, "\n")
    elseif result.structure_id then
      return true, table.concat({
        "materialized=true",
        "structure_id=" .. tostring(result.structure_id),
        "structure_name=" .. tostring(result.structure_name),
        "position=" .. (result.position and minetest.pos_to_string(result.position) or "nil"),
        "rotation=" .. tostring(result.rotation),
        "region_id=" .. tostring(result.region_id),
        "settlement_id=" .. tostring(result.settlement_id),
      }, "\n")
    end
    return true, "materialized=true"
  end,
})

minetest.register_chatcommand("pw_run_tests", {
	params = "",
	description = "Run all PerfectWorld tests via Luanti TestKit (admin only)",
	privs = {server = true},
	func = function(name)
		if not luanti_testkit or not luanti_testkit.run_all then
			return false, "luanti_testkit not available"
		end
		local ok, err = pcall(luanti_testkit.run_all, {player_name = name})
		if not ok then
			return false, "test run failed: " .. tostring(err)
		end
		return true, "Tests triggered. See server log and ltk_report_*.json for results."
	end,
})

minetest.register_chatcommand("pw_demo", {
	params = "",
	description = "Show coordinates of first village+farm demo slice",
	privs = {interact = true},
	func = function(name)
		local settlements = perfectworld.planner.list_settlements()
		local roads = perfectworld.planner.list_roads()

		if #settlements == 0 then
			return false, "No materialized settlements yet. Use /pw_materialize in a region with a village candidate."
		end

		local lines = {}
		table.insert(lines, "=== PerfectWorld Demo Slice ===")

		for _, sid in ipairs(settlements) do
			local plan = perfectworld.planner.get_settlement_plan(sid)
			if plan then
				table.insert(lines, "settlement_id=" .. tostring(sid))
				table.insert(lines, "  center=" .. minetest.pos_to_string({x = plan.center.x, y = 0, z = plan.center.z}))
				table.insert(lines, "  type=" .. tostring(plan.type or "village"))
				table.insert(lines, "  plots=" .. tostring(#(plan.plots or {})))
				if plan.external_connector then
					table.insert(lines, "  external_connector=" .. minetest.pos_to_string({x = plan.external_connector.x, y = 0, z = plan.external_connector.z}))
				end

				-- Find road from this settlement
				for _, road in ipairs(roads) do
					if road.from_settlement == sid then
						table.insert(lines, "  road_id=" .. tostring(road.id))
						table.insert(lines, "  road_length=" .. tostring(road.length or 0))
						if road.path and road.path[1] then
							table.insert(lines, "  road_start=" .. minetest.pos_to_string(road.path[1]))
						end
						if road.path and road.path[#road.path] then
							table.insert(lines, "  road_end=" .. minetest.pos_to_string(road.path[#road.path]))
						end
					end
				end

				-- Find farm structure
				local structures = perfectworld.planner.list_structures()
				for _, s in ipairs(structures) do
					if string.find(s.structure_id, "_farm") then
						table.insert(lines, "  farm_structure_id=" .. tostring(s.structure_id))
						table.insert(lines, "  farm_position=" .. minetest.pos_to_string(s.position))
					end
				end
			end
		end

		if #roads == 0 then
			table.insert(lines, "No roads yet.")
		end

		table.insert(lines, "Use /pw_prepare_shot <player> <structure_id> to teleport.")
		return true, table.concat(lines, "\n")
	end,
})

-- === Photo / Screenshot System ===
-- Бессмертие test player (watchdog)
local function test_player_immortal()
  local pname = get_test_player()
  local player = minetest.get_player_by_name(pname)
  if player then
    local hp = player:get_hp()
    if hp < 20 then
      player:set_hp(20)
    end
  end
end

local immortal_timer = 0
minetest.register_globalstep(function(dtime)
  immortal_timer = immortal_timer + dtime
  if immortal_timer >= 5 then -- каждые 5 секунд
    immortal_timer = 0
    test_player_immortal()
  end
end)

local function set_day()
  minetest.set_timeofday(7000 / 24000)
end

local function is_solid_node(pos)
  local node = minetest.get_node(pos)
  if node.name == "air" or node.name == "ignore" then return false end
  local def = minetest.registered_nodes[node.name]
  if not def then return true end
  if def.walkable == false then return false end
  if def.buildable_to then return false end
  return true
end

local function find_good_camera(center, radius)
  local distance = math.max(radius * 2.5, 16)
  -- берём фактическую высоту поверхности в центре, а не center.y
  local ground_y = center.y
  for y = 50, -10, -1 do
    local node = minetest.get_node({x = center.x, y = y, z = center.z})
    if node.name ~= "air" and node.name ~= "ignore" then
      ground_y = y
      break
    end
  end

  local angles = {
    {yaw = 0,         pitch = -0.3},
    {yaw = math.pi,   pitch = -0.3},
    {yaw = math.pi/2, pitch = -0.3},
    {yaw = -math.pi/2,pitch = -0.3},
    {yaw = math.pi/4, pitch = -0.4},
    {yaw = -math.pi/4,pitch = -0.4},
    {yaw = 3*math.pi/4,pitch = -0.4},
    {yaw = -3*math.pi/4,pitch = -0.4},
  }
  local best = nil
  local best_obstruction = math.huge

  for _, angle in ipairs(angles) do
    local cx = center.x + math.floor(math.cos(angle.yaw) * distance)
    local cz = center.z + math.floor(math.sin(angle.yaw) * distance)

    -- найти поверхность под camera pos
    local surface_y = ground_y
    for y = 50, -10, -1 do
      local node = minetest.get_node({x = cx, y = y, z = cz})
      if node.name ~= "air" and node.name ~= "ignore" then
        surface_y = y
        break
      end
    end
    local camera_pos = {x = cx, y = surface_y + 3, z = cz}

    -- raycast: camera -> центр на уровне земли
    local target = {x = center.x, y = ground_y + 1, z = center.z}
    local obstruction = 0
    local ray = minetest.raycast(camera_pos, target, false, false)
    for hit in ray do
      local dist = vector.distance(camera_pos, hit.under)
      if is_solid_node(hit.under) then
        -- блок ближе чем 80% пути до центра — препятствие
        if dist < distance * 0.8 then
          obstruction = obstruction + (1 - dist / distance)
        end
      end
    end

    if obstruction == 0 then
      -- идеально: нет препятствий
      local yaw = angle.yaw + math.pi -- развернуть лицом к центру
      return camera_pos, yaw, angle.pitch, true
    end

    if obstruction < best_obstruction then
      best_obstruction = obstruction
      best = {pos = camera_pos, yaw = angle.yaw + math.pi, pitch = angle.pitch}
    end
  end

  if best then
    return best.pos, best.yaw, best.pitch, false
  end
  return {x = center.x, y = ground_y + 20, z = center.z + 20}, 0, -0.5, false
end

local function get_structure_center_and_radius(struct_id)
  -- Поиск по materialized structures
  local records = perfectworld.planner and perfectworld.planner.list_structures()
  if records then
    for _, r in ipairs(records) do
      if r.structure_id == struct_id or struct_id == "" then
        local def = perfectworld.structures and perfectworld.structures.get(r.structure_name)
        local size = def and def.size or {x = 10, y = 5, z = 10}
        local radius = math.max(size.x, size.z) / 2
        return r.position, radius, r.structure_id
      end
    end
  end
  -- Поиск по settlement plans
  local settlements = perfectworld.planner and perfectworld.planner.list_settlements()
  if settlements then
    for _, sid in ipairs(settlements) do
      if sid == struct_id or struct_id == "" then
        local plan = perfectworld.planner.get_settlement_plan(sid)
        if plan and plan.center then
          local center = {x = plan.center.x, y = 0, z = plan.center.z}
          return center, 25, sid
        end
      end
    end
  end
  return nil, nil, nil
end



minetest.register_chatcommand("pw_photo_setup", {
  params = "",
  description = "Setup screenshot scene: time 7000, immortality, teleport safety",
  privs = {server = true},
  func = function(name)
    set_day()
    local player = minetest.get_player_by_name(get_test_player())
    if not player then
      return false, "test player not connected"
    end
    player:set_hp(20)
    if player.set_armor_groups then
      player:set_armor_groups({immortal = 1})
    end
    if player.set_physics_override then
      player:set_physics_override({gravity = 0})
    end
    -- Clouds sit at y=120 and turn any elevated overview shot into a white
    -- rectangle; even lighting keeps shots comparable between settlements.
    if player.set_clouds then
      player:set_clouds({density = 0})
    end
    if player.override_day_night_ratio then
      player:override_day_night_ratio(1)
    end
    -- убрать интерфейс
    player:hud_set_flags({
      hotbar = false,
      healthbar = false,
      breathbar = false,
      minimap = false,
      crosshair = false,
      wielditem = false,
    })
    -- закрыть любые открытые formspec (чат, help)
    minetest.close_formspec(get_test_player(), "")
    return true, "scene prepared"
  end,
})

minetest.register_chatcommand("pw_photo_village", {
  params = "",
  description = "Flatten terrain and force-materialize village in (-2,0)",
  privs = {server = true},
  func = function(name)
    if not perfectworld.materialization_enabled then
      return false, "materialization disabled"
    end
    local ok, mat_result = perfectworld.planner.materialize_region_candidate(-2, 0, 1, {
      force = true,
      skip_terrain_check = true,
    })
    if not ok then
      return false, "village materialization failed: " .. tostring(mat_result)
    end
    local sid = mat_result.settlement_id
    local plan = perfectworld.planner.get_settlement_plan(sid)
    if plan and plan.center then
      return true, table.concat({
        "settlement_id=" .. tostring(sid),
        "center=" .. minetest.pos_to_string({x = plan.center.x, y = 0, z = plan.center.z}),
        "plots=" .. tostring(#(plan.plots or {})),
        "external_connector=" .. (plan.external_connector and minetest.pos_to_string(plan.external_connector) or "none"),
      }, "\n")
    end
    return false, "village spawned but no plan found"
  end,
})

minetest.register_chatcommand("pw_photo_structure", {
  params = "<name> [rx] [rz] [index]",
  description = "Flatten terrain and force-materialize a structure",
  privs = {server = true},
  func = function(name, params)
    local struct_name, rx_s, rz_s, idx_s = (params or ""):match("^(%S+)%s*(%-?%d*)%s*(%-?%d*)%s*(%d*)$")
    if not struct_name or struct_name == "" then
      return false, "Usage: /pw_photo_structure <name> [rx] [rz] [index]"
    end
    if not perfectworld.materialization_enabled then
      return false, "materialization disabled"
    end
    local rx = tonumber(rx_s) or -2
    local rz = tonumber(rz_s) or -1
    local index = tonumber(idx_s) or 0
    local ok, result = perfectworld.planner.materialize_region_candidate(rx, rz, index, {
      force = true,
      skip_terrain_check = true,
    })
    if not ok then
      return false, "spawn failed: " .. tostring(result)
    end
    if result.structure_id then
      return true, table.concat({
        "structure_id=" .. tostring(result.structure_id),
        "structure_name=" .. tostring(struct_name),
        "position=" .. (result.position and minetest.pos_to_string(result.position) or "nil"),
      }, "\n")
    end
    return true, "village spawned settlement_id=" .. tostring(result.settlement_id or "?")
  end,
})

minetest.register_chatcommand("pw_photo_camera", {
  params = "<x> <y> <z> [radius]",
  description = "Position camera at a good angle looking at (x,y,z)",
  privs = {server = true},
  func = function(name, params)
    local x_s, y_s, z_s, rad_s = (params or ""):match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s*(%d*)$")
    if not x_s then
      return false, "Usage: /pw_photo_camera <x> <y> <z> [radius]"
    end
    local center = {x = tonumber(x_s), y = tonumber(y_s) or 0, z = tonumber(z_s)}
    local radius = tonumber(rad_s) or 15
    local player = minetest.get_player_by_name(get_test_player())
    if not player then
      return false, "test player not connected"
    end
    set_day()
    local cam_pos, yaw, pitch, no_obstruction = find_good_camera(center, radius)
    player:set_pos(cam_pos)
    if player.set_look_horizontal then
      player:set_look_horizontal(yaw)
    end
    if player.set_look_vertical then
      player:set_look_vertical(pitch)
    end
    return true, table.concat({
      "camera=" .. minetest.pos_to_string(cam_pos),
      "target=" .. minetest.pos_to_string(center),
      "yaw=" .. tostring(yaw),
      "pitch=" .. tostring(pitch),
      "no_obstruction=" .. tostring(no_obstruction),
      "radius=" .. tostring(radius),
    }, "\n")
  end,
})

minetest.register_chatcommand("pw_photo_shoot", {
	params = "<target_type>",
	description = "Validate, setup camera, and return machine-readable data for a screenshot target. target_type: farm, village, road",
	privs = {server = true},
	func = function(name, params)
		local target_type = (params or ""):match("^%s*(%S+)%s*$")
		if not target_type or (target_type ~= "farm" and target_type ~= "village" and target_type ~= "road") then
			return false, "Usage: /pw_photo_shoot <farm|village|road>"
		end

		local player = minetest.get_player_by_name(get_test_player())
		if not player then
			return false, table.concat({
				"target_type=" .. target_type,
				"status=FAIL",
				"reason=pwbot_not_connected",
			}, "\n")
		end

		-- Resolve target
		local center, bbox_min, bbox_max, radius, object_id, extra

		if target_type == "farm" then
			local structures = perfectworld.planner.list_structures()
			local farm_rec
			for _, s in ipairs(structures) do
				if string.find(s.structure_id or "", "_farm") then
					farm_rec = s
					break
				end
			end
			if not farm_rec or not farm_rec.position then
				return false, table.concat({
					"target_type=farm",
					"status=FAIL",
					"reason=farm_not_found",
					"hint=Run pw_materialize first to spawn village+farm+road",
				}, "\n")
			end
			object_id = farm_rec.structure_id
			center = farm_rec.position
			local def = perfectworld.structures and perfectworld.structures.get(farm_rec.structure_name or "pw_farmstead_v1")
			local size = def and def.size or {x = 10, y = 7, z = 10}
			radius = math.max(size.x, size.z) / 2 + 1
			bbox_min = {x = center.x - radius, y = center.y, z = center.z - radius}
			bbox_max = {x = center.x + radius, y = center.y + size.y, z = center.z + radius}
			extra = {
				structure_name = farm_rec.structure_name,
				rotation = farm_rec.rotation,
			}
		elseif target_type == "village" then
			local settlements = perfectworld.planner.list_settlements()
			if #settlements == 0 then
				return false, table.concat({
					"target_type=village",
					"status=FAIL",
					"reason=no_settlements_found",
					"hint=Run pw_materialize first to spawn village+farm+road",
				}, "\n")
			end
			local sid = settlements[1]
			object_id = sid
			local plan = perfectworld.planner.get_settlement_plan(sid)
			if not plan or not plan.center then
				return false, table.concat({
					"target_type=village",
					"status=FAIL",
					"reason=settlement_plan_incomplete",
					"object_id=" .. tostring(sid),
				}, "\n")
			end
			center = {x = plan.center.x, y = 0, z = plan.center.z}
			radius = 25
			local half = radius
			bbox_min = {x = center.x - half, y = 30, z = center.z - half}
			bbox_max = {x = center.x + half, y = 50, z = center.z + half}
			extra = {
				settlement_type = plan.type,
				plots = #(plan.plots or {}),
			}
		elseif target_type == "road" then
			local roads = perfectworld.planner.list_roads()
			if #roads == 0 then
				return false, table.concat({
					"target_type=road",
					"status=FAIL",
					"reason=no_roads_found",
					"hint=Run pw_materialize first to spawn village+farm+road",
				}, "\n")
			end
			local road = roads[1]
			object_id = road.id
			if not road.path or #road.path < 2 then
				return false, table.concat({
					"target_type=road",
					"status=FAIL",
					"reason=road_path_empty",
					"object_id=" .. tostring(road.id),
				}, "\n")
			end
			local path = road.path
			local mid_idx = math.floor(#path / 2)
			center = path[mid_idx]
			local min_x, min_z, max_x, max_z = center.x, center.z, center.x, center.z
			for _, p in ipairs(path) do
				if p.x < min_x then min_x = p.x end
				if p.z < min_z then min_z = p.z end
				if p.x > max_x then max_x = p.x end
				if p.z > max_z then max_z = p.z end
			end
			local width = math.max(max_x - min_x, max_z - min_z)
			radius = math.ceil(width / 2) + 5
			bbox_min = {x = min_x - 3, y = 30, z = min_z - 3}
			bbox_max = {x = max_x + 3, y = 40, z = max_z + 3}
			extra = {
				road_length = road.length or #path,
				path_nodes = #path,
				road_start = path[1],
				road_end = path[#path],
			}
		end

		-- Load chunks around target + camera area
		local load_min = {x = bbox_min.x - 20, y = -10, z = bbox_min.z - 20}
		local load_max = {x = bbox_max.x + 20, y = 60, z = bbox_max.z + 20}
		pcall(minetest.load_area, load_min, load_max)

		-- Check player not inside solid
		local pos = player:get_pos()
		if pos and is_solid_node(pos) then
			player:set_pos({x = center.x, y = center.y + 15, z = center.z})
		end

		-- Set time and HUD
		set_day()
		player:set_hp(20)
		if player.set_armor_groups then
			player:set_armor_groups({immortal = 1})
		end
		if player.set_physics_override then
			player:set_physics_override({gravity = 0})
		end
		player:hud_set_flags({
			hotbar = false, healthbar = false, breathbar = false,
			minimap = false, crosshair = false, wielditem = false,
		})
		minetest.close_formspec(get_test_player(), "")

		-- Find camera position
		local cam_pos, yaw, pitch, no_obstruction = find_good_camera(center, radius)

		-- Teleport player to camera
		player:set_pos(cam_pos)
		if player.set_look_horizontal then
			player:set_look_horizontal(yaw)
		end
		if player.set_look_vertical then
			player:set_look_vertical(pitch)
		end

		-- Build machine-readable response
		local lines = {
			"target_type=" .. target_type,
			"object_id=" .. tostring(object_id),
			"status=READY",
			"center=" .. minetest.pos_to_string(center),
			"bbox_min=" .. minetest.pos_to_string(bbox_min),
			"bbox_max=" .. minetest.pos_to_string(bbox_max),
			"radius=" .. tostring(radius),
			"camera=" .. minetest.pos_to_string(cam_pos),
			"yaw=" .. tostring(yaw),
			"pitch=" .. tostring(pitch),
			"no_obstruction=" .. tostring(no_obstruction),
			"time_of_day=7000",
		}
		if extra then
			for k, v in pairs(extra) do
				if type(v) == "table" then
					table.insert(lines, k .. "=" .. minetest.pos_to_string(v))
				else
					table.insert(lines, k .. "=" .. tostring(v))
				end
			end
		end

		-- Verify target nodes exist in world (sample check)
		local sample = minetest.get_node_or_nil(center)
		if sample then
			table.insert(lines, "center_node=" .. tostring(sample.name))
		end

		return true, table.concat(lines, "\n")
	end,
})

-- === Village Settlement Commands ===

minetest.register_chatcommand("pw_village_list", {
  params = "",
  description = "List all materialized village settlements",
  privs = {interact = true},
  func = function(name)
    local ids = perfectworld.settlements.list_ids()
    local lines = {"settlement_count=" .. #ids}
    for _, id in ipairs(ids) do
      local s = perfectworld.settlements.get(id)
      if s then
        table.insert(lines, "  " .. id .. " archetype=" .. (s.archetype or "?") .. " status=" .. (s.status or "?") .. " lots=" .. (s.lot_count or "?"))
      end
    end
    return true, table.concat(lines, "\n")
  end,
})

minetest.register_chatcommand("pw_village_info", {
  params = "<settlement_id>",
  description = "Show detailed info about a specific village settlement",
  privs = {interact = true},
  func = function(name, param)
    if not param or param == "" then
      local player = minetest.get_player_by_name(name)
      if not player then return false, "Player not found" end
      local pos = player:get_pos()
      if not pos then return false, "No position" end
      local best_id, best_dist = nil, math.huge
      for _, id in ipairs(perfectworld.settlements.list_ids()) do
        local s = perfectworld.settlements.get(id)
        if s and s.center_pos then
          local dx = pos.x - s.center_pos.x
          local dz = pos.z - s.center_pos.z
          local d = math.sqrt(dx*dx + dz*dz)
          if d < best_dist then
            best_dist = d
            best_id = id
          end
        end
      end
      if not best_id then return false, "No settlements found" end
      param = best_id
    end
    local s = perfectworld.settlements.get(param)
    if not s then return false, "Settlement not found: " .. param end
    local env = s.environment_profile or {}
    local lines = {
      "settlement_id=" .. tostring(s.settlement_id),
      "candidate_id=" .. tostring(s.candidate_id),
      "region_id=" .. tostring(s.region_id),
      "status=" .. tostring(s.status),
      "center=" .. minetest.pos_to_string(s.center_pos or {}),
      "bounds=" .. string.format("(%s,%s)..(%s,%s)",
        tostring(s.bounds and s.bounds.min_x), tostring(s.bounds and s.bounds.min_z),
        tostring(s.bounds and s.bounds.max_x), tostring(s.bounds and s.bounds.max_z)),
      "biome_name=" .. tostring(env.biome_name),
      "biome_family=" .. tostring(s.biome_family or env.biome_family),
      "elevation=" .. tostring(env.elevation),
      "roughness=" .. tostring(env.roughness),
      "water_proximity=" .. tostring(env.water_proximity),
      "vegetation_density=" .. tostring(env.vegetation_density),
      "palette=" .. tostring(s.palette_id),
      "archetype=" .. tostring(s.archetype),
      "size_class=" .. tostring(s.size_class),
      "lot_count=" .. tostring(s.lot_count),
      "planned_lot_count=" .. tostring(s.planned_lot_count),
      "required_roles=" .. table.concat(s.required_roles or {}, ","),
      "optional_roles=" .. table.concat(s.optional_roles or {}, ","),
      "missing_required_roles=" .. table.concat(s.missing_required_roles or {}, ","),
      "structure_ids=" .. table.concat(s.structure_ids or {}, ","),
      "structure_variants=" .. table.concat(s.structure_variants or {}, ","),
      "road_ids=" .. table.concat(s.road_ids or {}, ","),
      "road_segment_count=" .. tostring(s.road_segment_count),
      "exact_plan_fingerprint=" .. tostring(s.exact_plan_fingerprint),
      "structural_fingerprint=" .. tostring(s.structural_fingerprint),
      "road_graph_fingerprint=" .. tostring(s.road_graph_fingerprint),
      "seed_key=" .. tostring(s.seed_key),
      "generator=" .. tostring(s.generator_version),
    }
    return true, table.concat(lines, "\n")
  end,
})

minetest.register_chatcommand("pw_village_tp", {
  params = "<settlement_id>",
  description = "Teleport to a village settlement center",
  privs = {teleport = true},
  func = function(name, param)
    if not param or param == "" then return false, "Usage: /pw_village_tp <id>" end
    local s = perfectworld.settlements.get(param)
    if not s then return false, "Settlement not found: " .. param end
    local player = minetest.get_player_by_name(name)
    if not player then return false, "Player not found" end
    local cp = s.center_pos or {x = 0, y = 0, z = 0}
    player:set_pos({x = cp.x, y = cp.y + 5, z = cp.z})
    return true, "Teleported to " .. param
  end,
})

local function format_validation(report)
  local lines = {
    "valid=" .. tostring(report.ok),
    "settlement_id=" .. tostring(report.settlement_id),
    "status=" .. tostring(report.status),
    "archetype=" .. tostring(report.archetype),
    "lot_count=" .. tostring(report.lot_count),
    "structures=" .. tostring(report.structure_count),
    "roads=" .. tostring(report.road_count),
  }
  local names = {}
  for check_name in pairs(report.checks or {}) do table.insert(names, check_name) end
  table.sort(names)
  for _, check_name in ipairs(names) do
    table.insert(lines, "  " .. check_name .. "=" .. report.checks[check_name])
  end
  if #(report.issues or {}) > 0 then
    table.insert(lines, "issues=" .. table.concat(report.issues, " "))
  end
  return table.concat(lines, "\n")
end

minetest.register_chatcommand("pw_village_validate", {
  params = "[settlement_id]",
  description = "Validate a settlement against its record and the real world",
  privs = {interact = true},
  func = function(name, param)
    param = (param or ""):match("^%s*(.-)%s*$")
    if param == "" then
      local player = minetest.get_player_by_name(name)
      local pos = player and player:get_pos()
      if not pos then return false, "Usage: /pw_village_validate <id>" end
      local best_id, best_dist = nil, math.huge
      for _, id in ipairs(perfectworld.settlements.list_ids()) do
        local s = perfectworld.settlements.get(id)
        if s and s.center_pos then
          local dx, dz = pos.x - s.center_pos.x, pos.z - s.center_pos.z
          local d = dx * dx + dz * dz
          if d < best_dist then best_dist, best_id = d, id end
        end
      end
      if not best_id then return false, "No settlements found" end
      param = best_id
    end
    local report = perfectworld.planner.validate_settlement(param)
    return true, format_validation(report)
  end,
})

minetest.register_chatcommand("pw_village_validate_all", {
  params = "",
  description = "Validate every persisted settlement and summarise the failures",
  privs = {interact = true},
  func = function()
    local ids = perfectworld.settlements.list_ids()
    local lines = {}
    local ok_count, bad_count = 0, 0
    for _, id in ipairs(ids) do
      local report = perfectworld.planner.validate_settlement(id)
      if report.ok then
        ok_count = ok_count + 1
      else
        bad_count = bad_count + 1
        table.insert(lines, id .. " status=" .. tostring(report.status)
          .. " issues=" .. table.concat(report.issues, ","))
      end
    end
    table.insert(lines, 1, string.format("settlements=%d valid=%d invalid=%d",
      #ids, ok_count, bad_count))
    return true, table.concat(lines, "\n")
  end,
})

-- === Deferred player placement ===
--
-- A player who is offline when they are assigned a village cannot simply be
-- moved: on the next login the engine restores their saved position. Remember
-- the assignment and apply it when they join.

local PLACEMENT_KEY = "pw_pending_placements"
local debug_storage = minetest.get_mod_storage()

function perfectworld.debug.pending_placements()
  local raw = debug_storage:get_string(PLACEMENT_KEY)
  if raw and raw ~= "" then
    local ok, data = pcall(minetest.parse_json, raw)
    if ok and type(data) == "table" then return data end
  end
  return {}
end

function perfectworld.debug.save_pending_placements(pending)
  debug_storage:set_string(PLACEMENT_KEY, minetest.write_json(pending))
end

minetest.register_on_joinplayer(function(player)
  local name = player:get_player_name()
  local pending = perfectworld.debug.pending_placements()
  local spot = pending[name]
  if not spot then return end
  -- One tick later: the client has to have received the mapblocks first.
  minetest.after(0.5, function()
    local online = minetest.get_player_by_name(name)
    if not online then return end
    online:set_pos({x = spot.x, y = spot.y, z = spot.z})
    online:set_hp(20)
    pending[name] = nil
    perfectworld.debug.save_pending_placements(pending)
    minetest.log("action", string.format("[pw_debug] placed %s at %s on join",
      name, minetest.pos_to_string(spot)))
  end)
end)

--- Put a real player into a finished village, with privileges and a spawn
-- point there, so the world can be handed over ready to inspect.
minetest.register_chatcommand("pw_setup_player", {
  params = "<player> [settlement_id]",
  description = "Grant privileges and place a player in a finished village",
  privs = {server = true},
  func = function(name, param)
    local player_name, settlement_id = (param or ""):match("^%s*(%S+)%s*(%S*)%s*$")
    if not player_name or player_name == "" then
      return false, "Usage: /pw_setup_player <player> [settlement_id]"
    end

    -- Pick the largest fully valid settlement when none is named.
    if settlement_id == "" then
      local best, best_score = nil, -1
      for _, id in ipairs(perfectworld.settlements.list_ids()) do
        local stored = perfectworld.planner.get_settlement_plan(id)
        local settlement = stored and stored.settlement
        if settlement and (settlement.lot_count or 0) > 0 then
          local report = perfectworld.planner.validate_settlement(id)
          local score = (settlement.lot_count or 0) + (report.ok and 100 or 0)
          if score > best_score then best_score, best = score, id end
        end
      end
      settlement_id = best
    end
    if not settlement_id then return false, "no built settlement to place the player in" end

    local stored = perfectworld.planner.get_settlement_plan(settlement_id)
    local settlement = stored and stored.settlement
    if not settlement then return false, "Settlement not found: " .. settlement_id end

    local bounds = settlement.bounds or {}
    if minetest.load_area then
      pcall(minetest.load_area,
        {x = (bounds.min_x or 0) - 8, y = -32, z = (bounds.min_z or 0) - 8},
        {x = (bounds.max_x or 0) + 8, y = 200, z = (bounds.max_z or 0) + 8})
    end

    local anchor = settlement.street_anchor or settlement.center_pos
    local ground = anchor.y
    for probe = 4, -4, -1 do
      local node = minetest.get_node({x = anchor.x, y = anchor.y + probe, z = anchor.z})
      if node.name ~= "air" and node.name ~= "ignore" then
        ground = anchor.y + probe
        break
      end
    end
    local spot = {x = anchor.x, y = ground + 1, z = anchor.z}

    local all_privs = {}
    for priv in pairs(minetest.registered_privileges) do all_privs[priv] = true end
    minetest.set_player_privs(player_name, all_privs)

    local player = minetest.get_player_by_name(player_name)
    if player then
      player:set_pos(spot)
      player:set_hp(20)
      if player.set_physics_override then
        player:set_physics_override({gravity = 1, speed = 1})
      end
    else
      -- Offline players load their last saved position on login, so record
      -- the placement and apply it when they next join.
      local pending = perfectworld.debug.pending_placements()
      pending[player_name] = spot
      perfectworld.debug.save_pending_placements(pending)
    end
    minetest.settings:set("static_spawnpoint",
      string.format("%d,%d,%d", spot.x, spot.y, spot.z))

    minetest.log("action", string.format(
      "[pw_debug] player %s placed in %s at %s", player_name, settlement_id,
      minetest.pos_to_string(spot)))
    return true, table.concat({
      "player=" .. player_name,
      "settlement_id=" .. settlement_id,
      "archetype=" .. tostring(settlement.archetype),
      "biome_family=" .. tostring(settlement.biome_family),
      "lots=" .. tostring(settlement.lot_count),
      "spawn=" .. minetest.pos_to_string(spot),
      "online=" .. tostring(player ~= nil),
    }, "\n")
  end,
})

--- Walk the test player through a settlement on foot, along a real path.
--
-- No teleporting between viewpoints: the bot is put on the ground at the
-- village centre and then moved along the engine's own pathfinder route to
-- each door, one waypoint at a time. If the route does not exist, neither
-- does the house, as far as anyone living there is concerned.
minetest.register_chatcommand("pw_village_walk", {
  params = "<settlement_id> [door_index]",
  description = "Walk the test player from the village centre to a door on foot",
  privs = {server = true},
  func = function(name, param)
    local settlement_id, index = (param or ""):match("^%s*(%S+)%s*(%d*)%s*$")
    if not settlement_id then return false, "Usage: /pw_village_walk <id> [door_index]" end
    index = tonumber(index) or 1

    local stored = perfectworld.planner.get_settlement_plan(settlement_id)
    local settlement = stored and stored.settlement
    if not settlement then return false, "Settlement not found: " .. settlement_id end
    local player = minetest.get_player_by_name(get_test_player())
    if not player then return false, "test player not connected" end

    local bounds = settlement.bounds or {}
    if minetest.load_area then
      pcall(minetest.load_area,
        {x = (bounds.min_x or settlement.center_pos.x) - 8, y = -32,
         z = (bounds.min_z or settlement.center_pos.z) - 8},
        {x = (bounds.max_x or settlement.center_pos.x) + 8, y = 200,
         z = (bounds.max_z or settlement.center_pos.z) + 8})
    end

    local centre = settlement.street_anchor or settlement.center_pos
    local origin = perfectworld.planner._standing_spot(centre.x, centre.z, centre.y)
      or {x = centre.x, y = centre.y + 1, z = centre.z}

    local structure_id = (settlement.structure_ids or {})[index]
    if not structure_id then
      return false, "no structure " .. index .. " in " .. settlement_id
    end
    local record = perfectworld.planner.get_structure(structure_id)
    if not record then return false, "structure record missing: " .. structure_id end
    local def = perfectworld.structures.get(record.structure_name)
    local target = record.position
    for _, c in ipairs((def and def.connectors) or {}) do
      if c.type == "road" and c.offset_pos then
        local rotated = perfectworld.structures.rotate_point(c.offset_pos, record.rotation or 0)
        local tx = record.position.x + rotated.x
        local tz = record.position.z + rotated.z
        target = perfectworld.planner._standing_spot(tx, tz, record.position.y)
          or {x = tx, y = record.position.y + 1, z = tz}
        break
      end
    end

    local function describe(label, pos)
      minetest.log("action", string.format(
        "[pw_debug] walk %s %s at=%s below=%s above=%s", label,
        minetest.pos_to_string(pos),
        minetest.get_node(pos).name,
        minetest.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name,
        minetest.get_node({x = pos.x, y = pos.y + 1, z = pos.z}).name))
    end
    describe("origin", origin)
    describe("target", target)

    local path = minetest.find_path(origin, target, 96, 1, 2, "A*_noprefetch")
    if not path then
      minetest.log("action", string.format(
        "[pw_debug] walk no path %s -> %s (structure %s)",
        minetest.pos_to_string(origin), minetest.pos_to_string(target), structure_id))
      player:set_pos(origin)
      return true, table.concat({
        "walk=FAILED",
        "settlement_id=" .. settlement_id,
        "structure_id=" .. structure_id,
        "from=" .. minetest.pos_to_string(origin),
        "to=" .. minetest.pos_to_string(target),
        "reason=no_walkable_path",
      }, "\n")
    end

    -- Follow the route: one waypoint per server step, feet on the ground.
    player:set_pos(origin)
    player:set_physics_override({gravity = 1, speed = 1})
    local step = 0
    local function advance()
      step = step + 1
      local point = path[step]
      if not point then
        minetest.log("action", "[pw_debug] walk finished at door of " .. structure_id)
        return
      end
      player:set_pos({x = point.x, y = point.y + 0.5, z = point.z})
      if step < #path then minetest.after(0.18, advance) end
    end
    minetest.after(0.1, advance)

    return true, table.concat({
      "walk=OK",
      "settlement_id=" .. settlement_id,
      "structure_id=" .. structure_id,
      "structure_name=" .. tostring(record.structure_name),
      "from=" .. minetest.pos_to_string(origin),
      "to=" .. minetest.pos_to_string(target),
      "path_length=" .. #path,
    }, "\n")
  end,
})

--- List registered nodes matching a pattern. Building against node names that
-- do not exist in this game is the fastest way to produce invisible houses.
minetest.register_chatcommand("pw_nodes", {
  params = "<lua pattern> [limit]",
  description = "List registered node names matching a pattern",
  privs = {server = true},
  func = function(name, param)
    local pattern, limit = (param or ""):match("^%s*(%S+)%s*(%d*)%s*$")
    if not pattern then return false, "Usage: /pw_nodes <pattern> [limit]" end
    limit = tonumber(limit) or 60
    local matches = {}
    for node_name in pairs(minetest.registered_nodes) do
      if node_name:find(pattern) then table.insert(matches, node_name) end
    end
    table.sort(matches)
    local shown = {}
    for i = 1, math.min(#matches, limit) do table.insert(shown, matches[i]) end
    minetest.log("action", "[pw_debug] pw_nodes " .. pattern .. " -> " ..
      #matches .. " matches: " .. table.concat(shown, " "))
    return true, #matches .. " matches (see server log)"
  end,
})

--- Show what every abstract material and every palette entry actually resolves
-- to in this game. Aliases are not in minetest.registered_nodes, so a name that
-- works with set_node can still look "missing" to the resolver and be silently
-- downgraded to air.
minetest.register_chatcommand("pw_materials", {
  params = "",
  description = "Report resolved materials and palette entries",
  privs = {server = true},
  func = function()
    local lines = {}
    for _, role in ipairs({"foundation", "wall", "roof", "floor", "road", "fence",
      "door", "door_top", "window", "light", "container", "garden_soil", "crop",
      "ground", "cobble", "stone", "sandstone", "sand", "gravel", "tree", "water"}) do
      local resolved = perfectworld.compat.get_material(role, {required = false})
      lines[#lines + 1] = string.format("%-13s -> %-34s registered=%s",
        role, tostring(resolved), tostring(minetest.registered_nodes[resolved] ~= nil))
    end
    for _, family in ipairs(perfectworld.compat.list_families()) do
      local palette = perfectworld.compat.get_family_palette(family)
      local keys = {}
      for key in pairs(palette) do keys[#keys + 1] = key end
      table.sort(keys)
      for _, key in ipairs(keys) do
        lines[#lines + 1] = string.format("palette %-9s %-14s -> %-34s registered=%s",
          family, key, tostring(palette[key]),
          tostring(palette[key] == "air" or minetest.registered_nodes[palette[key]] ~= nil))
      end
    end
    for _, line in ipairs(lines) do
      minetest.log("action", "[pw_debug] material " .. line)
    end
    return true, #lines .. " entries (see server log)"
  end,
})

-- === Diversity Analysis ===

local analysis_running = false

local function write_world_file(filename, text)
  local path = minetest.get_worldpath() .. "/" .. filename
  local handle = io.open(path, "w")
  if not handle then return nil, "cannot open " .. path end
  handle:write(text)
  handle:close()
  return path
end

local function summarise_analysis(rows)
  local function counter() return {} end
  local metrics = {
    total_inputs = #rows,
    valid_plans = 0,
    rejected_plans = 0,
    failed_plans = 0,
    empty_plans = 0,
    archetype_distribution = counter(),
    biome_family_distribution = counter(),
    palette_distribution = counter(),
    size_class_distribution = counter(),
    lot_count_distribution = counter(),
    rejection_reasons = counter(),
  }
  local exact, structural, road_graph = {}, {}, {}
  local layouts, roles, structures = {}, {}, {}

  local function bump(tbl, key)
    if key == nil then key = "nil" end
    key = tostring(key)
    tbl[key] = (tbl[key] or 0) + 1
  end

  for _, row in ipairs(rows) do
    if row.status == "valid" then
      metrics.valid_plans = metrics.valid_plans + 1
    elseif row.status == "rejected" then
      metrics.rejected_plans = metrics.rejected_plans + 1
    elseif row.status == "empty" then
      metrics.empty_plans = metrics.empty_plans + 1
      metrics.rejected_plans = metrics.rejected_plans + 1
    else
      metrics.failed_plans = metrics.failed_plans + 1
    end

    if row.status ~= "error" then
      bump(metrics.archetype_distribution, row.archetype)
      bump(metrics.biome_family_distribution, row.biome_family)
      bump(metrics.palette_distribution, row.palette)
      bump(metrics.size_class_distribution, row.size_class)
      bump(metrics.lot_count_distribution, row.lot_count)
      for reason in tostring(row.rejections or ""):gmatch("(%a+)=") do
        bump(metrics.rejection_reasons, reason)
      end
    end

    if row.status == "valid" then
      bump(exact, row.exact_plan_fingerprint)
      bump(structural, row.structural_fingerprint)
      bump(road_graph, row.road_graph_fingerprint)
      bump(layouts, row.lot_layout_key)
      bump(roles, row.role_composition)
      bump(structures, row.structure_composition)
    end
  end

  local function count_keys(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
  end
  local function duplicate_groups(tbl)
    local groups = {}
    for key, count in pairs(tbl) do
      if count > 1 then groups[key] = count end
    end
    return groups
  end

  metrics.unique_exact_plan_fingerprints = count_keys(exact)
  metrics.unique_structural_fingerprints = count_keys(structural)
  metrics.unique_road_graph_fingerprints = count_keys(road_graph)
  metrics.unique_lot_layouts = count_keys(layouts)
  metrics.unique_role_compositions = count_keys(roles)
  metrics.unique_structure_compositions = count_keys(structures)
  metrics.duplicate_exact_groups = duplicate_groups(exact)
  metrics.duplicate_structural_groups = duplicate_groups(structural)
  return metrics
end

minetest.register_chatcommand("pw_village_analyze", {
  params = "[synthetic|world] [count]",
  description = "Plan N villages and write a diversity report to the world directory",
  privs = {server = true},
  func = function(name, param)
    if analysis_running then return false, "analysis already running" end
    param = param or ""
    local mode = param:match("world") and "world" or "synthetic"
    local count = tonumber(param:match("%d+")) or 120
    local inputs = perfectworld.planner.build_analysis_sample({mode = mode, count = count})
    analysis_running = true
    minetest.log("action", string.format(
      "[pw_debug] diversity analysis started: mode=%s inputs=%d", mode, #inputs))

    local rows = {}
    local index = 0
    local finish, run_one

    function finish()
      local report = {
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        mode = mode,
        world_seed = perfectworld.world_seed_string,
        planner_version = perfectworld.PLANNER_VERSION,
        region_size = perfectworld.REGION_SIZE,
        metrics = summarise_analysis(rows),
        rows = rows,
      }
      local stamp = os.date("!%Y%m%d_%H%M%S")
      local path = write_world_file("pw_diversity_" .. mode .. "_" .. stamp .. ".json",
        minetest.write_json(report, true))
      analysis_running = false
      minetest.log("action", "[pw_debug] diversity analysis finished: " .. tostring(path))
    end

    local function record(input)
      local ok, row = pcall(perfectworld.planner.analyze_input, input)
      if ok then
        table.insert(rows, row)
      else
        table.insert(rows, {
          input_id = input.input_id,
          status = "error",
          error = tostring(row):sub(1, 200),
        })
      end
      if #rows % 10 == 0 then
        minetest.log("action", "[pw_debug] analysis progress " .. #rows .. "/" .. #inputs)
      end
    end

    function run_one()
      if index >= #inputs then
        finish()
        return
      end
      if mode == "world" then
        -- One site at a time: the map area has to be generated before it can
        -- be planned on, and emerging is asynchronous.
        index = index + 1
        local input = inputs[index]
        perfectworld.planner.emerge_village_area({x = input.x, z = input.z}, function()
          record(input)
          minetest.after(0, run_one)
        end)
      else
        local deadline = minetest.get_us_time() + 150000
        while index < #inputs and minetest.get_us_time() < deadline do
          index = index + 1
          record(inputs[index])
        end
        minetest.after(0.05, run_one)
      end
    end

    minetest.after(0.1, run_one)
    return true, string.format("analysis started: mode=%s inputs=%d; watch the server log",
      mode, #inputs)
  end,
})

-- === Batch village materialization ===
--
-- Walks the real region plans, picks the composite (village) candidates and
-- materializes them through the normal pipeline, emerging each site first.

local batch_running = false

minetest.register_chatcommand("pw_village_batch", {
  params = "[count] [region_radius]",
  description = "Materialize the next N planned villages from the region plans",
  privs = {server = true},
  func = function(name, param)
    if batch_running then return false, "batch already running" end
    local count, radius = (param or ""):match("^%s*(%d*)%s*(%d*)%s*$")
    count = tonumber(count) or 12
    radius = tonumber(radius) or 6

    -- Collect village candidates, nearest regions first.
    local cells = {}
    for rx = -radius, radius do
      for rz = -radius, radius do
        table.insert(cells, {rx = rx, rz = rz})
      end
    end
    table.sort(cells, function(a, b)
      local da, db = a.rx * a.rx + a.rz * a.rz, b.rx * b.rx + b.rz * b.rz
      if da ~= db then return da < db end
      if a.rx ~= b.rx then return a.rx < b.rx end
      return a.rz < b.rz
    end)

    local found = {}
    for _, cell in ipairs(cells) do
      local plan = perfectworld.planner.plan_region(cell.rx, cell.rz)
      for _, candidate in ipairs(plan.settlement_candidates or {}) do
        if perfectworld.planner.is_composite_candidate(candidate)
          and not perfectworld.planner.is_placed(candidate.id) then
          candidate.region_id = plan.id
          -- get_spawn_level and get_biome_data are both noise-based, so the
          -- surface height and biome of a site are known before the site is
          -- generated. Use them to spread the batch across families instead of
          -- taking whatever happens to be nearest to spawn.
          local probe_y = (minetest.get_spawn_level
            and minetest.get_spawn_level(candidate.x, candidate.z)) or 8
          local biome = minetest.get_biome_data({x = candidate.x, y = probe_y, z = candidate.z})
          candidate.expected_family = perfectworld.compat.get_biome_family(
            biome and biome.biome or "unknown")
          table.insert(found, candidate)
        end
      end
    end

    if #found == 0 then
      return false, "no unplaced village candidates found within region radius " .. radius
    end

    -- Round-robin over families so the batch covers as many as the map offers.
    local by_family, family_order = {}, {}
    for _, candidate in ipairs(found) do
      local family = candidate.expected_family or "unknown"
      if not by_family[family] then
        by_family[family] = {}
        table.insert(family_order, family)
      end
      table.insert(by_family[family], candidate)
    end
    table.sort(family_order)
    local queue = {}
    local round = 0
    while #queue < #found do
      round = round + 1
      local added = false
      for _, family in ipairs(family_order) do
        local candidate = by_family[family][round]
        if candidate then
          table.insert(queue, candidate)
          added = true
        end
      end
      if not added then break end
    end
    minetest.log("action", "[pw_debug] batch candidate families: " ..
      minetest.write_json((function()
        local counts = {}
        for family, list in pairs(by_family) do counts[family] = #list end
        return counts
      end)()))

    batch_running = true
    local results = {}
    local index = 0
    minetest.log("action", string.format(
      "[pw_debug] village batch started: %d candidates available, target %d", #queue, count))

    local function step()
      if index >= #queue or #results >= count then
        batch_running = false
        local built = 0
        for _, r in ipairs(results) do
          if r.status == "complete" or r.status == "partial" then built = built + 1 end
        end
        minetest.log("action", string.format(
          "[pw_debug] village batch finished: attempted=%d materialized=%d", #results, built))
        for _, r in ipairs(results) do
          minetest.log("action", string.format(
            "[pw_debug] batch result id=%s status=%s archetype=%s family=%s lots=%s",
            tostring(r.id), tostring(r.status), tostring(r.archetype),
            tostring(r.family), tostring(r.lots)))
        end
        return
      end
      index = index + 1
      local candidate = queue[index]
      perfectworld.planner.emerge_village_area(candidate, function()
        local ok, result = perfectworld.planner.materialize_village_new(candidate)
        local settlement = type(result) == "table" and result.settlement or nil
        table.insert(results, {
          id = candidate.id,
          ok = ok,
          status = settlement and settlement.status or tostring(result),
          archetype = settlement and settlement.archetype,
          family = settlement and settlement.biome_family,
          lots = settlement and settlement.lot_count,
        })
        minetest.after(0, step)
      end)
    end

    minetest.after(0.1, step)
    return true, string.format("batch started: %d candidates queued, target %d", #queue, count)
  end,
})

--- Re-run materialization for every settlement that already exists and report
-- whether anything changed. This is the idempotency check a restart needs.
minetest.register_chatcommand("pw_village_rematerialize", {
  params = "",
  description = "Re-attempt materialization of every existing settlement and diff the result",
  privs = {server = true},
  func = function()
    local before_structures = #perfectworld.planner.list_structures()
    local before_roads = #perfectworld.planner.list_roads()
    local before_placed = #perfectworld.planner.list_placed()

    local rows = {}
    for _, id in ipairs(perfectworld.settlements.list_ids()) do
      local stored = perfectworld.planner.get_settlement_plan(id)
      local settlement = stored and stored.settlement
      if settlement then
        -- Rebuild the candidate from the region plan, exactly as the mapgen
        -- hook would.
        local candidate
        local rx, rz = perfectworld.get_region_coords(settlement.center_pos)
        local plan = perfectworld.planner.plan_region(rx, rz)
        for _, c in ipairs(plan.settlement_candidates or {}) do
          if c.id == id then
            candidate = c
            candidate.region_id = plan.id
          end
        end
        local row = {
          settlement_id = id,
          before = {
            status = settlement.status,
            lot_count = settlement.lot_count,
            exact_plan_fingerprint = settlement.exact_plan_fingerprint,
            structural_fingerprint = settlement.structural_fingerprint,
            road_graph_fingerprint = settlement.road_graph_fingerprint,
            archetype = settlement.archetype,
            palette_id = settlement.palette_id,
            structure_ids = settlement.structure_ids,
            road_ids = settlement.road_ids,
          },
          candidate_found = candidate ~= nil,
        }
        if candidate then
          local ok, result = perfectworld.planner.materialize_village_new(candidate)
          local after = type(result) == "table" and result.settlement or nil
          row.ok = ok
          row.from_cache = type(result) == "table" and result.from_cache or false
          if after then
            row.after = {
              status = after.status,
              lot_count = after.lot_count,
              exact_plan_fingerprint = after.exact_plan_fingerprint,
              structural_fingerprint = after.structural_fingerprint,
              road_graph_fingerprint = after.road_graph_fingerprint,
              archetype = after.archetype,
              palette_id = after.palette_id,
              structure_ids = after.structure_ids,
              road_ids = after.road_ids,
            }
          end
        end
        table.insert(rows, row)
      end
    end

    local report = {
      generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      before = {
        structures = before_structures,
        roads = before_roads,
        placed = before_placed,
      },
      after = {
        structures = #perfectworld.planner.list_structures(),
        roads = #perfectworld.planner.list_roads(),
        placed = #perfectworld.planner.list_placed(),
      },
      rows = rows,
    }
    local stamp = os.date("!%Y%m%d_%H%M%S")
    local path = write_world_file("pw_rematerialize_" .. stamp .. ".json",
      minetest.write_json(report, true))
    return true, string.format(
      "written: %s settlements=%d structures %d->%d roads %d->%d placed %d->%d",
      tostring(path), #rows,
      report.before.structures, report.after.structures,
      report.before.roads, report.after.roads,
      report.before.placed, report.after.placed)
  end,
})

-- === Screenshot support ===

--- Place the test player exactly and aim at a target. Screenshots need a
-- reproducible camera, which /pw_photo_camera (which picks its own angle)
-- cannot give.
minetest.register_chatcommand("pw_photo_at", {
  params = "<x> <y> <z> <target_x> <target_y> <target_z>",
  description = "Put the camera at a point and look at another point",
  privs = {server = true},
  func = function(name, param)
    local nums = {}
    for token in (param or ""):gmatch("[-%d%.]+") do
      table.insert(nums, tonumber(token))
    end
    if #nums < 6 then
      return false, "Usage: /pw_photo_at <x> <y> <z> <tx> <ty> <tz>"
    end
    local player = minetest.get_player_by_name(get_test_player())
    if not player then return false, "test player not connected" end

    local from = {x = nums[1], y = nums[2], z = nums[3]}
    local to = {x = nums[4], y = nums[5], z = nums[6]}
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local horizontal = math.sqrt(dx * dx + dz * dz)

    set_day()
    player:set_pos(from)
    player:set_look_horizontal(math.atan2(-dx, dz) % (2 * math.pi))
    -- set_look_vertical takes positive as downwards.
    player:set_look_vertical(-math.atan2(dy, math.max(horizontal, 0.001)))
    return true, string.format("camera=%s target=%s", minetest.pos_to_string(from),
      minetest.pos_to_string(to))
  end,
})

--- Compute three reproducible camera setups per settlement and write them,
-- with the full settlement metadata, to a JSON file the host script drives.
minetest.register_chatcommand("pw_village_shotlist", {
  params = "",
  description = "Write camera setups and metadata for every built settlement",
  privs = {server = true},
  func = function()
    local function ground(x, z, fallback)
      for y = 200, -32, -1 do
        local node = minetest.get_node({x = x, y = y, z = z})
        if node.name ~= "air" and node.name ~= "ignore" then return y end
      end
      return fallback or 0
    end

    local out = {
      generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      world_seed = perfectworld.world_seed_string,
      settlements = {},
    }

    for _, id in ipairs(perfectworld.settlements.list_ids()) do
      local stored = perfectworld.planner.get_settlement_plan(id)
      local settlement = stored and stored.settlement
      local plan = stored and stored.plan
      if settlement and (settlement.lot_count or 0) > 0 and plan then
        local center = settlement.center_pos
        local bounds = settlement.bounds or {}
        -- Mapblocks are unloaded once nobody is nearby and get_node then
        -- reports "ignore", which would put every camera at sea level.
        if minetest.load_area then
          pcall(minetest.load_area,
            {x = (bounds.min_x or center.x) - 8, y = -32, z = (bounds.min_z or center.z) - 8},
            {x = (bounds.max_x or center.x) + 8, y = 200, z = (bounds.max_z or center.z) + 8})
        end
        -- Frame on the built extent (the lots), not on the plan bounds: the
        -- street can run well past the last building and would push the whole
        -- village into a corner of the shot.
        local lot_min_x, lot_max_x, lot_min_z, lot_max_z
        for _, lot in ipairs(plan.lots or {}) do
          if lot.status == "materialized" then
            lot_min_x = math.min(lot_min_x or lot.center.x, lot.center.x)
            lot_max_x = math.max(lot_max_x or lot.center.x, lot.center.x)
            lot_min_z = math.min(lot_min_z or lot.center.z, lot.center.z)
            lot_max_z = math.max(lot_max_z or lot.center.z, lot.center.z)
          end
        end
        if lot_min_x then
          center = {
            x = math.floor((lot_min_x + lot_max_x) / 2),
            y = center.y,
            z = math.floor((lot_min_z + lot_max_z) / 2),
          }
        end
        local extent = math.max(
          (lot_max_x or bounds.max_x or center.x) - (lot_min_x or bounds.min_x or center.x),
          (lot_max_z or bounds.max_z or center.z) - (lot_min_z or bounds.min_z or center.z),
          28)
        local center_y = ground(center.x, center.z, center.y)
        local shots = {}

        -- 1. Overview from an elevated corner.
        local d = extent * 0.75 + 12
        local overview_from = {
          x = center.x - d, y = center_y + extent * 0.65 + 22, z = center.z - d,
        }
        table.insert(shots, {
          name = "overview",
          from = overview_from,
          target = {x = center.x, y = center_y, z = center.z},
        })

        -- 2. Along the main street, at eye height.
        local main = plan.roads and plan.roads[1]
        if main and #main.points >= 2 then
          local a = main.points[math.max(1, math.floor(#main.points * 0.15))]
          local b = main.points[math.min(#main.points, math.floor(#main.points * 0.85))]
          table.insert(shots, {
            name = "street",
            from = {x = a.x, y = ground(a.x, a.z, center_y) + 2, z = a.z},
            target = {x = b.x, y = ground(b.x, b.z, center_y) + 2, z = b.z},
          })
        end

        -- 3. Player-level view of the first dwelling from the street side.
        local lot
        for _, candidate_lot in ipairs(plan.lots or {}) do
          if candidate_lot.status == "materialized" then
            lot = candidate_lot
            if candidate_lot.role == "dwelling" then break end
          end
        end
        if lot then
          local rx, rz = lot.road_point.x, lot.road_point.z
          local dx, dz = rx - lot.center.x, rz - lot.center.z
          local length = math.max(math.sqrt(dx * dx + dz * dz), 0.001)
          local from = {
            x = math.floor(rx + dx / length * 7),
            z = math.floor(rz + dz / length * 7),
          }
          local target_y = ground(lot.center.x, lot.center.z, center_y) + 3
          -- On a slope the street can sit well below the lot; clamping keeps
          -- the shot at eye level instead of staring at the sky.
          local from_y = math.max(ground(from.x, from.z, center_y) + 2, target_y - 3)
          table.insert(shots, {
            name = "ground",
            from = {x = from.x, y = from_y, z = from.z},
            target = {x = lot.center.x, y = target_y, z = lot.center.z},
          })
        end

        table.insert(out.settlements, {
          settlement_id = settlement.settlement_id,
          candidate_id = settlement.candidate_id,
          region_id = settlement.region_id,
          status = settlement.status,
          center = center,
          bounds = bounds,
          biome_name = settlement.biome_name,
          biome_family = settlement.biome_family,
          palette = settlement.palette_id,
          archetype = settlement.archetype,
          size_class = settlement.size_class,
          lot_count = settlement.lot_count,
          structure_variants = settlement.structure_variants,
          road_ids = settlement.road_ids,
          road_segment_count = settlement.road_segment_count,
          exact_plan_fingerprint = settlement.exact_plan_fingerprint,
          structural_fingerprint = settlement.structural_fingerprint,
          road_graph_fingerprint = settlement.road_graph_fingerprint,
          teleport_command = string.format("/teleport %d %d %d",
            center.x, center_y + 2, center.z),
          shots = shots,
        })
      end
    end

    local stamp = os.date("!%Y%m%d_%H%M%S")
    local path = write_world_file("pw_shotlist_" .. stamp .. ".json",
      minetest.write_json(out, true))
    return true, "written: " .. tostring(path) .. " settlements=" .. #out.settlements
  end,
})

--- Dump every settlement record plus its validation report to the world dir.
minetest.register_chatcommand("pw_village_export", {
  params = "",
  description = "Write all settlement records and validation reports to JSON",
  privs = {server = true},
  func = function()
    local out = {
      generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      world_seed = perfectworld.world_seed_string,
      planner_version = perfectworld.PLANNER_VERSION,
      settlements = {},
    }
    for _, id in ipairs(perfectworld.settlements.list_ids()) do
      local stored = perfectworld.planner.get_settlement_plan(id)
      local settlement = stored and stored.settlement
      if settlement then
        local entry = perfectworld.core.deep_copy(settlement)
        entry.validation = perfectworld.planner.validate_settlement(id)
        entry.plan_roads = {}
        for _, road in ipairs((stored.plan or {}).roads or {}) do
          table.insert(entry.plan_roads, {
            id = road.id, kind = road.kind, width = road.width,
            point_count = #road.points,
          })
        end
        table.insert(out.settlements, entry)
      end
    end
    local stamp = os.date("!%Y%m%d_%H%M%S")
    local path = write_world_file("pw_settlements_" .. stamp .. ".json",
      minetest.write_json(out, true))
    return true, "written: " .. tostring(path) .. " settlements=" .. #out.settlements
  end,
})

-- The PW Bot obstacle course lives here rather than in pw_player_bot because
-- it writes nodes, and the bot mods are forbidden from doing that.
local ok, err = pcall(dofile, minetest.get_modpath("pw_debug") .. "/bot_course.lua")
if not ok then
  minetest.log("error", "[pw_debug] could not load bot_course.lua: " .. tostring(err))
end

minetest.log("action", "[pw_debug] loaded")
