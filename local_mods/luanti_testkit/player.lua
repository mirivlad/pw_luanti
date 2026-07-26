-- luanti_testkit/player.lua
-- Player helpers injected into test ctx

local function make_helpers(report_callback)
	local H = {}

	--- Get player object if online
	function H.get_player(name)
		if not name then return nil end
		return minetest.get_player_by_name(name)
	end

	--- Get player object, fail if offline
	function H.require_player(name)
		local player = H.get_player(name)
		if not player then
			report_callback("FAIL", "player '" .. (name or "?") .. "' is not online")
			return nil
		end
		return player
	end

	--- Get player position as {x, y, z}
	function H.get_pos(player_or_name)
		local player = player_or_name
		if type(player_or_name) == "string" then
			player = H.get_player(player_or_name)
		end
		if not player then
			report_callback("FAIL", "cannot get pos: player not found")
			return nil
		end
		local pos = player:get_pos()
		if not pos then
			report_callback("FAIL", "cannot get player position")
		end
		return pos
	end

	--- Teleport player to a position
	function H.set_pos(player_or_name, pos)
		local player = player_or_name
		if type(player_or_name) == "string" then
			player = H.get_player(player_or_name)
		end
		if not player then
			report_callback("FAIL", "cannot set pos: player not found")
			return
		end
		if not pos or not pos.x or not pos.y or not pos.z then
			report_callback("FAIL", "invalid position for set_pos")
			return
		end
		player:set_pos(pos)
	end

	H.teleport = H.set_pos

	--- 2D distance on XZ plane
	function H.distance2d(pos1, pos2)
		if not pos1 or not pos2 then return nil end
		local dx = pos1.x - pos2.x
		local dz = pos1.z - pos2.z
		return math.floor(math.sqrt(dx * dx + dz * dz) + 0.5)
	end

	--- 3D distance
	function H.distance3d(pos1, pos2)
		if not pos1 or not pos2 then return nil end
		local dx = pos1.x - pos2.x
		local dy = pos1.y - pos2.y
		local dz = pos1.z - pos2.z
		return math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5)
	end

	--- Execute a registered chat command as a player
	-- @param player_name string  Name of player to execute as
	-- @param command_line string e.g. "aw_status" or "aw_settlement birch_ford"
	-- @return bool, string|nil   true on success, false + error on failure
	function H.run_chatcommand(player_name, command_line)
		if not command_line or command_line == "" then
			report_callback("FAIL", "empty chat command")
			return false, "empty command"
		end

		-- Parse "cmd param1 param2..."
		local cmd, params_str = command_line:match("^(%S+)%s*(.-)$")
		if not cmd then
			cmd = command_line
			params_str = ""
		end

		local def = minetest.registered_chatcommands[cmd]
		if not def then
			local msg = "chat command not found: /" .. cmd
			report_callback("FAIL", msg)
			return false, msg
		end

		local ok, msg = def.func(player_name, params_str)
		if not ok then
			report_callback("FAIL", "/" .. cmd .. " returned false: " .. tostring(msg))
			return false, msg
		end
		return true, msg
	end

	--- Grant privileges to a player
	function H.grant(player_name, privs)
		if type(privs) == "table" then
			for _, p in ipairs(privs) do
				minetest.set_player_privs(player_name, {[p] = true})
			end
		else
			minetest.set_player_privs(player_name, {[privs] = true})
		end
	end

	--- Check if player has a privilege
	function H.has_priv(player_name, priv)
		local privs = minetest.get_player_privs(player_name)
		return privs[priv] == true
	end

	--- Wait/sleep (blocks server thread — use sparingly for small waits)
	-- For real async, would need a different approach, but this works
	-- for short delays in test context.
	-- @param seconds number  Seconds to wait (up to 5)
	-- @param callback function|nil  Optional callback after wait
	function H.wait(seconds, callback)
		seconds = math.min(seconds or 0.5, 5)
		local deadline = minetest.get_us_time() + seconds * 1000000
		while minetest.get_us_time() < deadline do
			-- busy-wait, but in Luanti this blocks the server
			-- recommend: use only for very short waits (<0.5s)
		end
		if callback then
			callback()
		end
	end

	return H
end

luanti_testkit._make_helpers = make_helpers
