local worldpath = minetest.get_worldpath()
local rc_file = worldpath .. "/rc_cmd.json"
local last_content = ""

minetest.register_globalstep(function(dtime)
  local f = io.open(rc_file, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if content == last_content or #content == 0 then return end
  last_content = content
  local ok, data = pcall(minetest.parse_json, content)
  if not ok or not data then
    minetest.log("warning", "[pw_rc] invalid JSON")
    return
  end
  local cmd = data.command
  local player = data.player
  if not player then
    minetest.log("warning", "[pw_rc] no player specified")
    return
  end
  if cmd == "runchat" and data.chatcmd then
    local cdef = minetest.registered_chatcommands[data.chatcmd]
    if cdef then
      local ok, result = cdef.func(player, data.params or "")
      minetest.log("action", "[pw_rc] /" .. data.chatcmd .. " " .. (data.params or "") .. " as " .. player .. " => " .. tostring(ok) .. ": " .. tostring(result))
    else
      minetest.log("warning", "[pw_rc] unknown cmd /" .. data.chatcmd)
    end
  elseif cmd == "teleport" and data.pos then
    local pobj = minetest.get_player_by_name(player)
    if pobj then pobj:set_pos(data.pos) end
  elseif cmd == "whereami" then
    local pobj = minetest.get_player_by_name(player)
    if pobj then
      local pos = pobj:get_pos()
      minetest.log("action", "[pw_rc] " .. player .. " at " .. minetest.pos_to_string(pos))
    end
  elseif cmd == "runall" then
    if luanti_testkit and luanti_testkit.run_all then
      luanti_testkit.run_all({player_name = player})
    end
  else
    minetest.log("warning", "[pw_rc] unknown command " .. tostring(cmd))
  end
  os.remove(rc_file)
end)

minetest.log("action", "[pw_remote_control] loaded")
