-- pw_bot_bridge/tests/integration.lua
--
-- End-to-end checks against a real running server and the connected test
-- player. These are deliberately not mock tests: the point is that the bridge
-- behaves on a live server, with a live player, through the public API.

local B = pw_bot_bridge
local support = B.impl.test_support
local canonical = B.impl.canonical
local registry = B.impl.registry
local transport = B.impl.transport
local settings = B.impl.settings

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

test("integration_registers_the_test_player_in_player_mode", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    local bot = B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    ctx.assert.not_nil(bot, "the test player was registered")
    ctx.assert.equal(bot.mode, "player", "in player mode")
    ctx.assert.equal(B.get_mode(name), "player", "and get_mode agrees")

    local info = B.get_session_info(name)
    ctx.assert.is_true(info.connected, "the bridge sees the player as connected")
    ctx.assert.is_true(#info.session_id > 0, "the session has an id")
  end)
end)

test("integration_self_state_is_complete_and_honest", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    local envelope = support.observe(name, "get_self_state", {})
    ctx.assert.is_true(envelope.ok, "get_self_state answered")

    local state = envelope.data.self_state
    for _, field in ipairs({"player_name", "position", "velocity", "yaw", "pitch",
      "on_ground", "in_liquid", "liquid_type", "hp", "breath", "wielded_item",
      "attached", "attached_entity", "node_under", "node_at_feet", "node_at_body",
      "node_at_head", "connected"}) do
      ctx.assert.not_nil(state[field], "self state carries " .. field)
    end
    ctx.assert.equal(state.player_name, name, "the right player")
    ctx.assert.is_true(state.connected, "connected")

    -- Derived values must say they are derived rather than pose as engine facts.
    ctx.assert.equal(state.on_ground_source, "derived_from_node_under_and_velocity",
      "on_ground declares that it is inferred")

    local real = player:get_pos()
    ctx.assert.near(state.position.x, real.x, 0.01, "position x matches the engine")
    ctx.assert.near(state.position.z, real.z, 0.01, "position z matches the engine")
    ctx.assert.near(state.yaw, player:get_look_horizontal(), 0.01, "yaw matches the engine")
  end)
end)

test("integration_player_observation_has_every_perception_channel", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    local envelope = support.observe(name, "observe", {profile = "navigation"})
    ctx.assert.is_true(envelope.ok, "observe answered")
    ctx.assert.equal(envelope.protocol, "pw_bot_bridge/v1", "versioned envelope")
    ctx.assert.equal(envelope.mode, "player", "the mode is stated")
    ctx.assert.is_true(envelope.sequence >= 1, "a sequence number is issued")

    local data = envelope.data
    ctx.assert.equal(data.contract, "server_side_approximation",
      "the response says what kind of perception it is")
    for _, channel in ipairs({"self_state", "tactile", "rays", "visible_entities",
      "visible_features", "surface_profile", "limits"}) do
      ctx.assert.not_nil(data[channel], "the observation carries " .. channel)
    end

    local rays = data.rays == canonical.EMPTY_ARRAY and {} or data.rays
    ctx.assert.is_true(#rays > 0, "the navigation profile casts rays")
    local previous = ""
    for _, ray in ipairs(rays) do
      ctx.assert.is_true(ray.ray_id > previous, "rays come back in a stable sorted order")
      previous = ray.ray_id
      ctx.assert.not_nil(ray.hit_type, "each ray reports a hit type")
      ctx.assert.not_nil(ray.distance, "each ray reports a distance")
    end
  end)
end)

test("integration_scan_narrows_the_sector_without_turning_the_player", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    local yaw_before = player:get_look_horizontal()
    local pitch_before = player:get_look_vertical()
    local pos_before = player:get_pos()

    for _, operation in ipairs({"scan_forward", "scan_left", "scan_right",
      "scan_up", "scan_down"}) do
      local envelope = support.observe(name, operation, {profile = "navigation"})
      ctx.assert.is_true(envelope.ok, operation .. " answered")
      ctx.assert.equal(envelope.data.operation, operation, "the operation is echoed")
      ctx.assert.not_nil(envelope.data.sector_deg, operation .. " states its sector")
      ctx.assert.is_true(envelope.data.rays_skipped_outside_sector >= 0,
        "rays outside the sector are counted, not silently dropped")
    end

    ctx.assert.near(player:get_look_horizontal(), yaw_before, 0.0001,
      "no scan changed the player's yaw")
    ctx.assert.near(player:get_look_vertical(), pitch_before, 0.0001,
      "no scan changed the player's pitch")
    ctx.assert.near(player:get_pos().x, pos_before.x, 0.0001, "no scan moved the player")
    ctx.assert.near(player:get_pos().y, pos_before.y, 0.0001, "no scan moved the player")
    ctx.assert.near(player:get_pos().z, pos_before.z, 0.0001, "no scan moved the player")
  end)
end)

test("integration_oracle_operations_are_refused_in_player_mode", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    local pos = player:get_pos()
    for _, operation in ipairs({"get_nodes", "get_area", "get_entities", "get_collision",
      "get_surface", "get_structure", "get_road", "get_road_topology",
      "get_settlement", "get_lots", "inspect_position", "validate_area"}) do
      local envelope = support.observe(name, operation, {
        min = {x = math.floor(pos.x) - 2, y = math.floor(pos.y) - 2, z = math.floor(pos.z) - 2},
        max = {x = math.floor(pos.x) + 2, y = math.floor(pos.y) + 2, z = math.floor(pos.z) + 2},
        position = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)},
        settlement_id = "whatever",
      })
      ctx.assert.is_false(envelope.ok, operation .. " is refused in player mode")
      ctx.assert.equal(envelope.error.code, "operation_not_allowed", operation .. " code")
    end
  end)
end)

test("integration_admin_switches_mode_and_oracle_returns_exact_data", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    ctx.assert.equal(B.get_mode(name), "player", "starts in player mode")

    local ok, record = B.set_mode(name, "oracle", B.SERVER_ACTOR)
    ctx.assert.is_true(ok, "an authorised actor may switch the mode")
    ctx.assert.equal(record.mode, "oracle", "the record shows the new mode")
    ctx.assert.equal(B.get_mode(name), "oracle", "and so does get_mode")

    local pos = player:get_pos()
    local base = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)}
    local envelope = support.observe(name, "get_nodes", {
      min = {x = base.x - 1, y = base.y - 2, z = base.z - 1},
      max = {x = base.x + 1, y = base.y + 1, z = base.z + 1},
      include_air = true,
    })
    ctx.assert.is_true(envelope.ok, "the oracle answered: "
      .. (envelope.ok and "" or envelope.error.code))
    ctx.assert.equal(envelope.mode, "oracle", "the response states oracle mode")
    ctx.assert.equal(envelope.data.volume, 3 * 4 * 3, "the whole box was considered")

    local nodes = envelope.data.nodes == canonical.EMPTY_ARRAY and {} or envelope.data.nodes
    ctx.assert.is_true(#nodes > 0, "nodes came back")
    -- The oracle must agree with the engine, node for node.
    local mismatches = 0
    for _, node in ipairs(nodes) do
      local truth = minetest.get_node_or_nil(node.position)
      if truth and node.name and truth.name ~= node.name then
        mismatches = mismatches + 1
      end
    end
    ctx.assert.equal(mismatches, 0, "every reported node matches the map")

    local back, restored = B.set_mode(name, "player", B.SERVER_ACTOR)
    ctx.assert.is_true(back, "the mode can be switched back")
    ctx.assert.equal(restored.mode, "player", "back in player mode")

    local refused = support.observe(name, "get_nodes", {
      min = {x = base.x, y = base.y, z = base.z},
      max = {x = base.x, y = base.y, z = base.z},
    })
    ctx.assert.is_false(refused.ok, "and oracle data is withheld again")
    ctx.assert.equal(refused.error.code, "operation_not_allowed", "code")
  end)
end)

test("integration_bot_cannot_raise_its_own_mode", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  -- get_player_privs hands back the live auth table, so both the working copy
  -- and the copy used to restore have to be ours.
  local original_privs = {}
  local stripped = {}
  for priv, value in pairs(minetest.get_player_privs(name)) do
    original_privs[priv] = value
    stripped[priv] = value
  end
  original_privs[B.ADMIN_PRIV] = true
  stripped[B.ADMIN_PRIV] = nil

  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    -- The test player normally holds every privilege; take the bridge one away
    -- so this asks the real question: can a bot without authorisation promote
    -- itself?
    minetest.set_player_privs(name, stripped)
    ctx.assert.is_false(minetest.get_player_privs(name)[B.ADMIN_PRIV] == true,
      "the privilege really is gone")

    local ok, code, detail = B.set_mode(name, "oracle", name)
    ctx.assert.is_false(ok, "the bot cannot promote itself")
    ctx.assert.equal(code, "permission_denied", "code")
    ctx.assert.equal(detail, "self_escalation_denied", "the reason names the attempt")
    ctx.assert.equal(B.get_mode(name), "player", "the mode did not move")

    local reg_ok, reg_code = B.register_bot(name, {mode = "oracle"}, name)
    ctx.assert.is_nil(reg_ok, "nor re-register itself into oracle mode")
    ctx.assert.equal(reg_code, "permission_denied", "code")
    ctx.assert.equal(B.get_mode(name), "player", "still player mode")

    -- And no request it could send would do it either.
    local envelope = B.observe(name, {operation = "set_mode", parameters = {mode = "oracle"}})
    ctx.assert.is_false(envelope.ok, "there is no set_mode operation")
    ctx.assert.equal(envelope.error.code, "unsupported_operation", "code")

    minetest.set_player_privs(name, original_privs)
    ctx.assert.is_true(minetest.get_player_privs(name)[B.ADMIN_PRIV] == true,
      "the privilege was restored")
  end)
end)

test("integration_event_polling_works_end_to_end", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    B.emit_event(name, "bridge_warning", {note = "integration"}, B.SERVER_ACTOR)

    local envelope = B.poll_events(name, {max = 16})
    ctx.assert.is_true(envelope.ok, "poll_events answered")
    ctx.assert.equal(envelope.mode, "player", "the mode is stated")
    local data = envelope.data
    local events = data.events == canonical.EMPTY_ARRAY and {} or data.events
    ctx.assert.is_true(#events >= 1, "the event arrived")
    local found = false
    for _, event in ipairs(events) do
      if event.type == "bridge_warning" and event.payload.note == "integration" then
        found = true
      end
    end
    ctx.assert.is_true(found, "the emitted event is in the queue")

    local again = B.poll_events(name, {max = 16})
    local again_events = again.data.events == canonical.EMPTY_ARRAY and {} or again.data.events
    for _, event in ipairs(again_events) do
      ctx.assert.is_true(event.type ~= "bridge_warning" or event.payload.note ~= "integration",
        "the cursor advanced, the event is not repeated")
    end
  end)
end)

test("integration_registry_survives_a_reload_and_the_session_does_not", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "oracle", limits = {oracle_max_nodes = 2048}}, B.SERVER_ACTOR)
    B.emit_event(name, "bridge_warning", {note = "before restart"}, B.SERVER_ACTOR)
    local before = B.get_bot(name)
    local session_before = B.get_session_info(name).session_id

    -- The restart contract, exercised the only way a running server can:
    -- persist, forget, load — exactly the steps a real restart performs.
    registry.save()
    registry.load()
    registry.new_session(name)

    local after = B.get_bot(name)
    ctx.assert.not_nil(after, "the registration survived")
    ctx.assert.equal(after.mode, before.mode, "the mode survived")
    ctx.assert.equal(after.created_at, before.created_at, "created_at survived")
    ctx.assert.equal(after.limits.oracle_max_nodes, 2048, "the per-bot limit survived")

    local session_after = B.get_session_info(name)
    ctx.assert.is_true(session_after.session_id ~= session_before,
      "the session is new after a restart")
    ctx.assert.equal(session_after.sequence, 0, "the sequence starts over")
    ctx.assert.equal(session_after.events_queued, 0, "the event queue does not survive")
    ctx.assert.equal(session_after.events_dropped, 0, "nor the dropped counter")
  end)
end)

test("integration_transport_follows_its_setting", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  local available, missing = transport.available()
  if not available then
    return ctx.skip("sandbox lacks: " .. table.concat(missing, ","))
  end

  -- Establish the precondition rather than inherit it.
  --
  -- This test used to open by asserting the transport was not running "while
  -- the setting is off", and then depend on the deployment for the setting
  -- being off. On a machine running `pw_bot_runtime` it is on, the first
  -- assertion failed, and everything below it — the administrator lifecycle,
  -- which is the thing the test is named for — was never reached. A test that
  -- needs the spool stopped stops it.
  local before = settings.external_transport
  settings.external_transport = false
  transport.stop(B.SERVER_ACTOR)
  ctx.assert.is_false(transport.is_running(),
    "the transport is not running while the setting is off")

  local started = transport.start(B.SERVER_ACTOR)
  ctx.assert.is_true(started, "an administrator can start it")
  ctx.assert.is_true(transport.is_running(), "it reports itself running")
  ctx.assert.is_true(transport.status().running, "and so does the status")

  transport.stop(B.SERVER_ACTOR)
  ctx.assert.is_false(transport.is_running(), "and stop it again")

  -- Put the deployment back. The globalstep reconciles setting and state, so
  -- restoring the setting restarts the spool on the next step if it was on;
  -- leaving it off here would silently take the runtime's channel away for the
  -- rest of the session.
  settings.external_transport = before
end)

test("integration_observation_stays_inside_its_performance_budget", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player", limits = {max_requests_per_second = 100,
      max_request_burst = 200}}, B.SERVER_ACTOR)

    local sizes, times = {}, {}
    for _ = 1, 5 do
      local started = minetest.get_us_time()
      local envelope = support.observe(name, "observe", {profile = "navigation"})
      times[#times + 1] = minetest.get_us_time() - started
      ctx.assert.is_true(envelope.ok, "the observation succeeded")
      sizes[#sizes + 1] = #B.encode_canonical(envelope)
      ctx.assert.is_true(envelope.data.budget.elapsed_us <= 200000,
        "the observation did not run away with the server step")
    end

    local total_time, total_size = 0, 0
    for index = 1, #times do
      total_time = total_time + times[index]
      total_size = total_size + sizes[index]
    end
    local mean_time = math.floor(total_time / #times)
    local mean_size = math.floor(total_size / #sizes)
    ctx.log(string.format("navigation observation: %d bytes mean, %d us mean", mean_size, mean_time))
    ctx.assert.is_true(mean_size < 262144, "a navigation observation fits the response limit")
    ctx.assert.is_true(mean_time < 200000, "and is fast enough to serve on demand")
  end)
end)

test("integration_oracle_respects_its_node_budget_and_says_so", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "oracle", limits = {oracle_max_nodes = 600}}, B.SERVER_ACTOR)
    local pos = player:get_pos()
    local base = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)}

    local within = support.observe(name, "get_nodes", {
      min = {x = base.x - 2, y = base.y - 2, z = base.z - 2},
      max = {x = base.x + 2, y = base.y + 2, z = base.z + 2},
    })
    ctx.assert.is_true(within.ok, "a small box is answered")
    ctx.assert.is_false(within.data.truncated, "and is not truncated")

    local beyond = support.observe(name, "get_nodes", {
      min = {x = base.x - 8, y = base.y - 8, z = base.z - 8},
      max = {x = base.x + 8, y = base.y + 8, z = base.z + 8},
    })
    ctx.assert.is_false(beyond.ok, "a box past the per-bot node limit is refused")
    ctx.assert.equal(beyond.error.code, "area_too_large", "code")
    ctx.assert.is_true(beyond.error.details.volume ~= nil or beyond.error.details.extent ~= nil,
      "the refusal says what was too big")
  end)
end)

test("integration_oracle_distinguishes_loaded_unloaded_and_ignore", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "oracle"}, B.SERVER_ACTOR)
    local pos = player:get_pos()

    local near = support.observe(name, "get_nodes", {
      min = {x = math.floor(pos.x), y = math.floor(pos.y) - 1, z = math.floor(pos.z)},
      max = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)},
      include_air = true,
    })
    ctx.assert.is_true(near.ok, "the loaded area answered")
    ctx.assert.equal(near.data.counts.not_loaded, 0, "nothing near the player is unloaded")

    -- Far from any player nothing is loaded, and the bridge must say so rather
    -- than generate the area to find out.
    local far_y = 3000
    local far = support.observe(name, "get_nodes", {
      min = {x = 30000, y = far_y, z = 30000},
      max = {x = 30001, y = far_y + 1, z = 30001},
      include_unloaded = true,
    })
    ctx.assert.is_true(far.ok, "the far area answered")
    ctx.assert.is_true(far.data.counts.not_loaded + far.data.counts.ignore > 0,
      "an unvisited area is reported as not loaded rather than generated")
  end)
end)

test("integration_oracle_uses_actual_normalized_settlement_geometry", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  local fixture_ids = {
    "pw_bot_bridge_normalized_legacy",
    "pw_bot_bridge_normalized_v3",
  }
  local function clear_fixtures()
    for _, id in ipairs(fixture_ids) do
      perfectworld.planner._test_clear_settlement(id)
      perfectworld.planner._test_unmark_placed(id)
    end
  end
  clear_fixtures()

  for index, id in ipairs(fixture_ids) do
    local actual_x = 7100 + index * 100
    local actual_z = 8100 + index * 100
    perfectworld.planner.save_settlement_plan(id, {
      plan = {
        settlement_grammar_version = index == 2 and 3 or nil,
        archetype = "linear",
        size_class = "small",
        center = {x = -actual_x, z = -actual_z},
        bounds = {
          min_x = -actual_x - 2, max_x = -actual_x + 2,
          min_z = -actual_z - 2, max_z = -actual_z + 2,
        },
        lots = {},
      },
      profile = {},
      settlement = {
        settlement_id = id,
        settlement_grammar_version = index == 2 and 3 or nil,
        archetype = "linear",
        size_class = "small",
        center_pos = {x = actual_x, y = 24, z = actual_z},
        bounds = {
          min_x = actual_x - 12, max_x = actual_x + 15,
          min_z = actual_z - 14, max_z = actual_z + 17,
        },
        structure_ids = {},
        road_ids = {},
        errors = {},
        lot_count = 0,
      },
    })
  end

  local ok, err = pcall(function()
    support.with_bot_state(name, function()
      B.register_bot(name, {mode = "oracle", limits = {
        max_requests_per_second = 100, max_request_burst = 200,
      }}, B.SERVER_ACTOR)

      for index, id in ipairs(fixture_ids) do
        local envelope = support.observe(name, "get_settlement", {
          settlement_id = id,
        })
        ctx.assert.is_true(envelope.ok, "get_settlement answered for " .. id)
        ctx.assert.equal(envelope.data.settlement_count, 1,
          "the seeded settlement is returned")
        local record = envelope.data.settlements[1]
        local actual_x = 7100 + index * 100
        local actual_z = 8100 + index * 100
        ctx.assert.equal(record.center.x, actual_x,
          "oracle center must come from the materialized settlement")
        ctx.assert.equal(record.center.z, actual_z,
          "oracle center z must come from the materialized settlement")
        ctx.assert.equal(record.bounds.min_x, actual_x - 12,
          "oracle bounds must come from the materialized settlement")
        ctx.assert.equal(record.bounds.max_z, actual_z + 17,
          "oracle bounds max z must come from the materialized settlement")

        local keys = {}
        for key in pairs(record) do keys[#keys + 1] = key end
        table.sort(keys)
        ctx.assert.equal(table.concat(keys, ","),
          "archetype,biome_family,bounds,center,errors,lot_count,palette_id,"
            .. "road_ids,settlement_id,size_class,structure_ids",
          "pw_bot_bridge/v1 settlement response schema must not change")
      end
    end)
  end)
  clear_fixtures()
  if not ok then error(err) end
end)

test("integration_oracle_reads_perfectworld_records_when_there_are_any", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  local settlements = perfectworld.planner.list_settlements()
  if #settlements == 0 then
    return ctx.skip("no settlement has been materialised in this world yet")
  end

  support.with_bot_state(name, function()
    -- Searching a world with dozens of settlements costs more requests than the
    -- default bucket allows, and the rate limit is not what this test is about.
    B.register_bot(name, {mode = "oracle", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, B.SERVER_ACTOR)

    -- Not every persisted settlement was built: some are plan-only records.
    -- Pick one that actually has lots, so the assertions below examine a real
    -- village rather than an empty shell.
    local settlement_id, lots
    for _, candidate in ipairs(settlements) do
      local probe = support.observe(name, "get_lots", {settlement_id = candidate})
      if probe.ok and probe.data.lot_count > 0 then
        settlement_id, lots = candidate, probe
        break
      end
    end
    if not settlement_id then
      return ctx.skip("no persisted settlement has lots in this world")
    end
    ctx.log("examining settlement " .. settlement_id
      .. " with " .. lots.data.lot_count .. " lots")

    local settlement = support.observe(name, "get_settlement", {settlement_id = settlement_id})
    ctx.assert.is_true(settlement.ok, "get_settlement answered")
    ctx.assert.is_true(settlement.data.settlement_count >= 1, "the settlement was found")
    ctx.assert.not_nil(settlement.data.settlements[1].bounds, "it knows its own extent")

    local first = lots.data.lots[1]
    ctx.assert.not_nil(first.footprint_min, "a lot knows where its plot starts")
    ctx.assert.not_nil(first.road_point, "and which street it belongs to")
    ctx.assert.not_nil(first.role, "and what it is for")
    ctx.assert.not_nil(first.door, "and where its doorway is")

    local structures = support.observe(name, "get_structure", {settlement_id = settlement_id})
    ctx.assert.is_true(structures.ok, "get_structure answered")
    if structures.data.structure_count > 0 then
      local entrances = support.observe(name, "get_structure_entrances",
        {settlement_id = settlement_id})
      ctx.assert.is_true(entrances.ok, "get_structure_entrances answered")
      ctx.assert.is_true(entrances.data.entrance_count >= 1,
        "a materialised settlement has doorways")
      local entrance = entrances.data.entrances[1]
      ctx.assert.not_nil(entrance.position, "an entrance has a position")
      ctx.assert.not_nil(entrance.access, "and a verdict on whether it can be stood in")
      ctx.assert.not_nil(entrance.access.reasons, "with reasons when it cannot")
    end

    local roads = support.observe(name, "get_road", {settlement_id = settlement_id})
    ctx.assert.is_true(roads.ok, "get_road answered")
    if roads.data.road_count > 0 then
      local topology = support.observe(name, "get_road_topology", {settlement_id = settlement_id})
      ctx.assert.is_true(topology.ok, "get_road_topology answered")
      ctx.assert.not_nil(topology.data.junctions, "junctions are reported")
      ctx.assert.not_nil(topology.data.edges, "and which roads meet at them")
    end
  end)
end)

test("integration_oracle_validate_area_reports_physical_defects", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "oracle"}, B.SERVER_ACTOR)
    local pos = player:get_pos()
    local base = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)}
    local envelope = support.observe(name, "validate_area", {
      min = {x = base.x - 16, y = base.y - 8, z = base.z - 16},
      max = {x = base.x + 16, y = base.y + 8, z = base.z + 16},
    })
    ctx.assert.is_true(envelope.ok, "validate_area answered")
    ctx.assert.not_nil(envelope.data.findings, "a finding list is present")
    ctx.assert.not_nil(envelope.data.findings_by_code, "with a summary by code")
    ctx.assert.is_true(envelope.data.checked_road_cells >= 0, "road cells were counted")
    ctx.assert.is_true(envelope.data.finding_count >= 0, "findings were counted")
  end)
end)

test("integration_bridge_never_moved_or_turned_the_player", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "oracle"}, B.SERVER_ACTOR)
    local pos = player:get_pos()
    local yaw = player:get_look_horizontal()
    local pitch = player:get_look_vertical()
    local hp = player:get_hp()
    local base = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)}

    -- Every operation the protocol offers, in the most permissive mode.
    local operations = {
      {"observe", {}},
      {"scan_forward", {}}, {"scan_left", {}}, {"scan_right", {}},
      {"scan_up", {}}, {"scan_down", {}},
      {"inspect_target", {}},
      {"find_visible_entity", {}},
      {"find_visible_feature", {feature = "door"}},
      {"get_self_state", {}},
      {"poll_events", {}},
      {"get_nodes", {min = base, max = base}},
      {"get_area", {min = base, max = base, include = {"nodes", "semantics", "records"}}},
      {"get_entities", {min = base, max = base}},
      {"get_collision", {position = base}},
      {"get_surface", {min = base, max = base}},
      {"inspect_position", {position = base}},
      {"validate_access_point", {position = base}},
      {"validate_area", {min = base, max = base}},
      {"get_structure", {position = base}},
      {"get_structure_entrances", {position = base}},
      {"get_road", {min = base, max = base}},
      {"get_road_topology", {min = base, max = base}},
      {"get_settlement", {}},
      {"get_lots", {settlement_id = "pw_bot_bridge_no_such_settlement"}},
    }
    for _, entry in ipairs(operations) do
      local envelope = support.observe(name, entry[1], entry[2])
      ctx.assert.not_nil(envelope.protocol, entry[1] .. " returned an envelope")
    end

    local after = player:get_pos()
    ctx.assert.near(after.x, pos.x, 0.0001, "x unchanged")
    ctx.assert.near(after.y, pos.y, 0.0001, "y unchanged")
    ctx.assert.near(after.z, pos.z, 0.0001, "z unchanged")
    ctx.assert.near(player:get_look_horizontal(), yaw, 0.0001, "yaw unchanged")
    ctx.assert.near(player:get_look_vertical(), pitch, 0.0001, "pitch unchanged")
    ctx.assert.equal(player:get_hp(), hp, "hp unchanged")
    ctx.assert.is_nil(player:get_attach(), "the player was not attached to anything")
  end)
end)

test("integration_response_size_limit_is_enforced", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end
  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player", limits = {max_response_bytes = 4096}},
      B.SERVER_ACTOR)
    local text, envelope = B.observe_json(name, support.request("observe",
      {profile = "detailed"}))
    ctx.assert.is_true(#text <= 8192, "the emitted document respects the limit")
    if not envelope.ok then
      ctx.assert.equal(envelope.error.code, "response_too_large",
        "an oversized answer is replaced by a stated error, not truncated silently")
    end
  end)
end)
