-- luanti_testkit/tests/player_basic.lua
-- Basic player connectivity tests

local T = luanti_testkit

T.register_suite("player", {
	description = "Basic player connectivity tests",
})

T.register_test("player", "player_online", function(ctx)
	ctx.assert.not_nil(ctx.player_name, "player_name must be provided for this test")
	local player = ctx.helpers.get_player(ctx.player_name)
	if not player then
		ctx.skip("Player '" .. ctx.player_name .. "' is not online. Start a test client first.")
		return
	end
	ctx.assert.is_true(player:is_player(), "player object must be valid")
end)

T.register_test("player", "player_position", function(ctx)
	local player = ctx.helpers.get_player(ctx.player_name)
	if not player then
		ctx.skip("Player '" .. ctx.player_name .. "' is not online.")
		return
	end
	local pos = ctx.helpers.get_pos(ctx.player_name)
	ctx.assert.not_nil(pos, "player position must be non-nil")
	ctx.assert.not_nil(pos.x, "pos.x must exist")
	ctx.assert.not_nil(pos.y, "pos.y must exist")
	ctx.assert.not_nil(pos.z, "pos.z must exist")
end)

T.register_test("player", "player_teleport", function(ctx)
	local player = ctx.helpers.get_player(ctx.player_name)
	if not player then
		ctx.skip("Player '" .. ctx.player_name .. "' is not online.")
		return
	end
	local original = ctx.helpers.get_pos(ctx.player_name)
	local test_pos = {x = original.x, y = original.y, z = original.z + 5}
	ctx.helpers.set_pos(ctx.player_name, test_pos)
	ctx.helpers.wait(0.1)  -- short wait for position update
	local new_pos = ctx.helpers.get_pos(ctx.player_name)
	ctx.assert.near(new_pos.z, test_pos.z, 2, "player should teleport to test position Z")
	-- Restore
	ctx.helpers.set_pos(ctx.player_name, original)
end)

T.register_test("player", "chat_command_execution", function(ctx)
	if not minetest.registered_chatcommands["help"] then
		ctx.skip("no /help command to test with")
		return
	end
	local ok, msg = ctx.helpers.run_chatcommand(ctx.player_name, "help")
	ctx.assert.is_true(ok, "/help should succeed")
end)
