-- pw_bot_bridge/tests/unit_core.lua
--
-- Registry, permissions, capability discovery, request validation, canonical
-- serialisation and the error envelope. None of this needs a world.

local B = pw_bot_bridge
local support = B.impl.test_support
local canonical = B.impl.canonical
local protocol = B.impl.protocol
local permissions = B.impl.permissions
local registry = B.impl.registry
local validation = B.impl.validation

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

-- === Capability discovery ===

test("capability_is_versioned", function(ctx)
  ctx.assert.equal(B.get_version(), "pw_bot_bridge/v1", "capability id")
  local doc = B.get_capabilities()
  ctx.assert.equal(doc.capability, "pw_bot_bridge/v1", "document capability")
  ctx.assert.equal(#doc.protocols, 1, "one protocol advertised")
  ctx.assert.equal(doc.protocols[1], "pw_bot_bridge/v1", "advertised protocol")
  ctx.assert.equal(table.concat(doc.modes, ","), "oracle,player", "modes")
  ctx.assert.is_true(#doc.reserved_modes >= 3, "future mode names are reserved")
  ctx.assert.equal(doc.transport.requires_insecure_environment, false,
    "the bridge must not need an insecure environment")
end)

test("capability_lists_every_operation_and_error_code", function(ctx)
  local doc = B.get_capabilities()
  local function has(list, wanted)
    for _, item in ipairs(list) do if item == wanted then return true end end
    return false
  end
  for _, operation in ipairs({"observe", "scan_forward", "scan_left", "scan_right",
    "scan_up", "scan_down", "inspect_target", "find_visible_entity",
    "find_visible_feature", "get_self_state", "poll_events"}) do
    ctx.assert.is_true(has(doc.operations.player, operation),
      "player mode advertises " .. operation)
  end
  for _, operation in ipairs({"get_nodes", "get_area", "get_entities", "get_collision",
    "get_surface", "get_structure", "get_structure_entrances", "get_road",
    "get_road_topology", "get_settlement", "get_lots", "inspect_position",
    "validate_access_point", "validate_area", "poll_events"}) do
    ctx.assert.is_true(has(doc.operations.oracle, operation),
      "oracle mode advertises " .. operation)
  end
  for _, code in ipairs({"invalid_request", "unsupported_protocol", "bot_not_registered",
    "player_not_connected", "permission_denied", "operation_not_allowed", "rate_limited",
    "area_too_large", "out_of_range", "map_not_loaded", "unknown_node",
    "unsupported_operation", "internal_error"}) do
    ctx.assert.is_true(protocol.is_error_code(code), "error code " .. code .. " exists")
    ctx.assert.is_true(has(doc.error_codes, code), "capability lists " .. code)
  end
end)

-- === Canonical serialisation ===

test("canonical_json_is_key_sorted_and_stable", function(ctx)
  local value = {zebra = 1, alpha = {3, 1, 2}, mid = "x"}
  local first = canonical.encode(value)
  ctx.assert.equal(first, '{"alpha":[3,1,2],"mid":"x","zebra":1}', "sorted keys, array order kept")
  for _ = 1, 20 do
    ctx.assert.equal(canonical.encode(value), first, "encoding is stable across calls")
  end
end)

test("canonical_distinguishes_empty_array_from_empty_object", function(ctx)
  ctx.assert.equal(canonical.encode({a = canonical.EMPTY_ARRAY, b = {}}),
    '{"a":[],"b":{}}', "empty array and empty object differ")
  ctx.assert.equal(canonical.encode({v = canonical.NULL}), '{"v":null}', "explicit null")
end)

test("canonical_numbers_are_rounded_and_formatted_deterministically", function(ctx)
  ctx.assert.equal(canonical.round(1.23456), 1.235, "round half away from zero")
  ctx.assert.equal(canonical.round(-1.23456), -1.235, "negative rounds symmetrically")
  ctx.assert.equal(canonical.encode({n = 1.5}), '{"n":1.5}', "no trailing zeros")
  ctx.assert.equal(canonical.encode({n = 3}), '{"n":3}', "integers stay integral")
  ctx.assert.equal(canonical.encode({n = canonical.round(2.0004)}), '{"n":2}',
    "rounding to an integer prints as an integer")
end)

test("canonical_never_emits_a_lua_reference", function(ctx)
  local text = canonical.encode({fn = function() end, ref = coroutine.create(function() end)})
  ctx.assert.is_true(text:find("__unencodable_", 1, true) ~= nil,
    "functions and userdata are replaced by a marker")
  ctx.assert.is_true(text:find("function: ", 1, true) == nil, "no raw Lua reference")
end)

test("canonical_sorts_tags_and_groups", function(ctx)
  local tags = canonical.sorted_unique({"road", "door", "road", "air"})
  ctx.assert.equal(table.concat(tags, ","), "air,door,road", "sorted and de-duplicated")
  local groups = canonical.groups({stair = 1, door_bottom = 1, a = 2})
  ctx.assert.equal(groups[1].name, "a", "groups sorted by name")
  ctx.assert.equal(groups[2].name, "door_bottom", "groups sorted by name")
end)

test("oracle_road_cells_match_the_shared_world_raster", function(ctx)
  local oracle = B.impl.oracle_perception
  local roads = perfectworld and perfectworld.roads
  ctx.assert.not_nil(roads and roads.rasterize_record,
    "shared road raster must be available to the oracle")
  if not roads or not roads.rasterize_record then return end

  local record = {
    id = "oracle_raster_contract",
    path = {{x = 0, z = 0}, {x = 4, z = 4}},
    width = 2,
  }
  local expected = {}
  for _, cell in ipairs(roads.rasterize_record(record)) do
    expected[cell.x .. ":" .. cell.z] = true
  end
  local actual = oracle.road_cells(record)
  local actual_count = 0
  for key in pairs(actual) do
    actual_count = actual_count + 1
    ctx.assert.is_true(expected[key] == true,
      "oracle emitted a cell outside the shared raster: " .. key)
  end
  local expected_count = 0
  for _ in pairs(expected) do expected_count = expected_count + 1 end
  ctx.assert.equal(actual_count, expected_count,
    "oracle and world must report the same road cells")
end)

test("oracle_prefers_persisted_actual_structure_entrances", function(ctx)
  local entrances = B.impl.oracle_perception.structure_entrances({
    structure_id = "oracle_persisted_entrance",
    structure_name = "pw_house_small_v1",
    position = {x = 10, y = 20, z = 30},
    rotation = 0,
    road_point = {x = 8, z = 30},
    entrances = {{
      position = {x = 14, y = 22, z = 35},
      road_point = {x = 13, z = 35},
    }},
  })
  ctx.assert.equal(#entrances, 1,
    "a persisted actual entrance must replace definition-derived guesses")
  ctx.assert.equal(entrances[1].source, "structure_record",
    "oracle must identify the persisted source")
  ctx.assert.equal(entrances[1].position.x, 14,
    "oracle must report the actual persisted threshold")
  ctx.assert.equal(entrances[1].position.y, 22,
    "actual threshold height must survive")
  ctx.assert.equal(entrances[1].road_point.x, 13,
    "actual entrance road point must survive")
end)

-- === Registry ===

test("registry_stores_and_returns_a_bot_record", function(ctx)
  local bot = support.scratch_bot("player")
  ctx.assert.not_nil(bot, "registration returns the record")
  ctx.assert.equal(bot.player_name, support.SCRATCH_BOT, "player name")
  ctx.assert.equal(bot.mode, "player", "mode")
  ctx.assert.equal(bot.enabled, true, "enabled by default")
  ctx.assert.equal(bot.registered_by, B.SERVER_ACTOR, "registered_by is recorded")
  ctx.assert.is_true(bot.created_at > 0, "created_at is set")
  ctx.assert.not_nil(bot.limits, "limits are present")
  ctx.assert.is_true(bot.limits.view_distance > 0, "limits are populated")

  local listed = B.list_bots()
  local found = false
  for _, entry in ipairs(listed) do
    if entry.player_name == support.SCRATCH_BOT then found = true end
  end
  ctx.assert.is_true(found, "the bot appears in list_bots")
  support.drop_scratch_bot()
  ctx.assert.is_nil(B.get_bot(support.SCRATCH_BOT), "unregister removes the record")
end)

test("registry_rejects_illegal_player_names", function(ctx)
  for _, name in ipairs({"", "has space", "../escape", "slash/name", B.SERVER_ACTOR,
    string.rep("x", 40)}) do
    local bot, code = B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    ctx.assert.is_nil(bot, "refused: " .. name)
    ctx.assert.equal(code, "invalid_request", "code for " .. name)
  end
end)

test("registry_limits_can_only_narrow_the_server_ceiling", function(ctx)
  local defaults = registry.default_limits()
  local bot = support.scratch_bot("oracle", {
    view_distance = defaults.view_distance + 1000,
    oracle_max_nodes = 512,
  })
  ctx.assert.equal(bot.limits.view_distance, defaults.view_distance,
    "a wider view distance is clamped back to the server value")
  ctx.assert.equal(bot.limits.oracle_max_nodes, 512, "a narrower limit is honoured")
  support.drop_scratch_bot()
end)

test("registry_persists_across_a_reload_but_sessions_do_not", function(ctx)
  local bot = support.scratch_bot("oracle")
  local created_at = bot.created_at
  local session_before = B.get_session_info(support.SCRATCH_BOT)
  ctx.assert.not_nil(session_before, "the bot has a session")

  -- Exactly what a restart does to the module: save, forget, load.
  registry.save()
  registry.load()

  local after = B.get_bot(support.SCRATCH_BOT)
  ctx.assert.not_nil(after, "the registration survived")
  ctx.assert.equal(after.mode, "oracle", "the mode survived")
  ctx.assert.equal(after.created_at, created_at, "created_at survived")

  local storage_dump = registry.storage_string()
  ctx.assert.is_true(#storage_dump > 0, "the registry was written to mod storage")
  -- Quoted keys, not bare substrings: `event_queue_size` is a persisted limit
  -- and must not be confused with the runtime queue it bounds.
  for _, forbidden in ipairs({'"events"', '"event_cursor"', '"event_sequence"',
    '"session_id"', '"sequence"', '"rate_tokens"', '"entity_ids"',
    '"entity_counter"', '"last_sample"'}) do
    ctx.assert.is_true(storage_dump:find(forbidden, 1, true) == nil,
      forbidden .. " is not persisted")
  end
  ctx.assert.is_true(storage_dump:find('"event_queue_size"', 1, true) ~= nil,
    "the event queue *limit* is persisted, because it is configuration")
  support.drop_scratch_bot()
end)

test("session_sequence_starts_at_one_and_increases", function(ctx)
  support.scratch_bot("player")
  local info = B.get_session_info(support.SCRATCH_BOT)
  ctx.assert.equal(info.sequence, 0, "a fresh session has issued no sequence yet")
  ctx.assert.equal(registry.next_sequence(support.SCRATCH_BOT), 1, "first sequence is 1")
  ctx.assert.equal(registry.next_sequence(support.SCRATCH_BOT), 2, "sequence increases")
  support.drop_scratch_bot()
end)

-- === Permissions ===

test("permissions_privilege_is_registered", function(ctx)
  ctx.assert.not_nil(minetest.registered_privileges[permissions.PRIV],
    "pw_bot_admin is a real privilege")
  ctx.assert.equal(B.ADMIN_PRIV, "pw_bot_admin", "the API exposes the privilege name")
end)

test("permissions_refuse_registration_without_an_actor", function(ctx)
  local bot, code = B.register_bot("pw_bridge_nobody", {mode = "player"}, nil)
  ctx.assert.is_nil(bot, "no actor, no registration")
  ctx.assert.equal(code, "permission_denied", "code")

  local bot2, code2 = B.register_bot("pw_bridge_nobody", {mode = "player"}, "")
  ctx.assert.is_nil(bot2, "empty actor is not the server actor")
  ctx.assert.equal(code2, "permission_denied", "code")
end)

test("permissions_reject_an_unknown_mode", function(ctx)
  local bot, code = B.register_bot(support.SCRATCH_BOT, {mode = "oracle_world"},
    B.SERVER_ACTOR)
  ctx.assert.is_nil(bot, "a reserved-but-unimplemented mode is not accepted in v1")
  ctx.assert.equal(code, "invalid_request", "code")
  ctx.assert.is_false(permissions.is_valid_mode("oracle_world"), "not a v1 mode")
  ctx.assert.is_true(permissions.is_valid_mode("player"), "player is a v1 mode")
  ctx.assert.is_true(permissions.is_valid_mode("oracle"), "oracle is a v1 mode")
end)

test("protocol_has_no_operation_that_changes_a_mode", function(ctx)
  -- The strongest guarantee against self escalation is structural: there is no
  -- request a bot could send that would change its own mode, in either mode.
  for _, mode in ipairs({"player", "oracle"}) do
    for _, operation in ipairs(validation.operations_for(mode)) do
      ctx.assert.is_true(operation:find("mode") == nil,
        mode .. " mode exposes no mode-changing operation (" .. operation .. ")")
      ctx.assert.is_true(operation:find("register") == nil,
        mode .. " mode exposes no registration operation (" .. operation .. ")")
      ctx.assert.is_true(operation:find("priv") == nil,
        mode .. " mode exposes no privilege operation (" .. operation .. ")")
    end
  end
end)

-- === Request validation and error envelopes ===

test("validation_rejects_a_foreign_protocol", function(ctx)
  support.scratch_bot("player")
  local envelope = B.observe(support.SCRATCH_BOT, {
    protocol = "pw_bot_bridge/v9",
    request_id = "p1",
    operation = "get_self_state",
  })
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "unsupported_protocol", "code")
  ctx.assert.equal(envelope.protocol, "pw_bot_bridge/v1", "the answer still names our protocol")
  support.drop_scratch_bot()
end)

test("validation_rejects_malformed_requests", function(ctx)
  support.scratch_bot("player")
  local cases = {
    {request = "not a table", code = "invalid_request"},
    {request = {}, code = "invalid_request"},
    {request = {operation = 42}, code = "invalid_request"},
    {request = {operation = "Get Area"}, code = "invalid_request"},
    {request = {operation = "get_self_state", request_id = {1}}, code = "invalid_request"},
    {request = {operation = "get_self_state", request_id = string.rep("x", 200)}, code = "invalid_request"},
    {request = {operation = "get_self_state", request_id = "../../etc/passwd"}, code = "invalid_request"},
    {request = {operation = "get_self_state", parameters = "nope"}, code = "invalid_request"},
    {request = {operation = "no_such_operation"}, code = "unsupported_operation"},
  }
  for index, case in ipairs(cases) do
    local envelope = B.observe(support.SCRATCH_BOT, case.request)
    ctx.assert.is_false(envelope.ok, "case " .. index .. " refused")
    ctx.assert.equal(envelope.error.code, case.code, "case " .. index .. " code")
  end
  support.drop_scratch_bot()
end)

test("validation_refuses_to_answer_about_another_player", function(ctx)
  support.scratch_bot("oracle")
  local envelope = B.observe(support.SCRATCH_BOT, {
    operation = "get_self_state",
    player_name = "someone_else",
  })
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "permission_denied", "code")
  support.drop_scratch_bot()
end)

test("unregistered_bot_cannot_observe", function(ctx)
  B.unregister_bot(support.SCRATCH_BOT, B.SERVER_ACTOR)
  local envelope = B.observe(support.SCRATCH_BOT, support.request("get_self_state"))
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "bot_not_registered", "code")
end)

test("registered_but_disconnected_bot_reports_player_not_connected", function(ctx)
  support.scratch_bot("player")
  local envelope = B.observe(support.SCRATCH_BOT, support.request("get_self_state"))
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "player_not_connected", "code")
  support.drop_scratch_bot()
end)

test("player_mode_refuses_arbitrary_area_queries", function(ctx)
  support.scratch_bot("player")
  local envelope = B.observe(support.SCRATCH_BOT, {
    operation = "get_nodes",
    min = {x = -100, y = 0, z = -100},
    max = {x = 100, y = 100, z = 100},
  })
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "operation_not_allowed", "code")
  ctx.assert.is_true(envelope.error.message:find("player mode", 1, true) ~= nil,
    "the message says which mode refused: " .. envelope.error.message)
  support.drop_scratch_bot()
end)

test("oracle_mode_enforces_area_limits", function(ctx)
  local bot = support.scratch_bot("oracle")
  local radius = bot.limits.oracle_max_radius
  local envelope = B.observe(support.SCRATCH_BOT, {
    operation = "get_nodes",
    min = {x = 0, y = 0, z = 0},
    max = {x = radius * 4, y = 4, z = 4},
  })
  ctx.assert.is_false(envelope.ok, "an over-wide box is refused")
  ctx.assert.equal(envelope.error.code, "area_too_large", "code")
  ctx.assert.is_true(envelope.error.details.max_extent ~= nil
    or envelope.error.details.max_nodes ~= nil, "the limit is reported back")

  local volume = B.observe(support.SCRATCH_BOT, {
    operation = "get_nodes",
    min = {x = 0, y = 0, z = 0},
    max = {x = 60, y = 60, z = 60},
  })
  ctx.assert.is_false(volume.ok, "an over-large volume is refused")
  ctx.assert.equal(volume.error.code, "area_too_large", "code")
  support.drop_scratch_bot()
end)

test("out_of_world_coordinates_are_refused", function(ctx)
  support.scratch_bot("oracle")
  local envelope = B.observe(support.SCRATCH_BOT, {
    operation = "inspect_position",
    position = {x = 999999, y = 0, z = 0},
  })
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "invalid_request", "code")
  support.drop_scratch_bot()
end)

test("validate_request_is_a_dry_run", function(ctx)
  support.scratch_bot("oracle")
  local ok, envelope = B.validate_request(support.SCRATCH_BOT, {
    operation = "get_nodes",
    min = {x = 0, y = 0, z = 0},
    max = {x = 4, y = 4, z = 4},
  })
  ctx.assert.is_true(ok, "a legal request validates")
  ctx.assert.is_true(envelope.ok, "envelope says ok")
  ctx.assert.is_true(envelope.data.estimated_cost >= 1, "a cost is estimated")

  local bad_ok, bad = B.validate_request(support.SCRATCH_BOT, {operation = "nope"})
  ctx.assert.is_false(bad_ok, "an illegal request does not validate")
  ctx.assert.equal(bad.error.code, "unsupported_operation", "code")
  support.drop_scratch_bot()
end)

test("rate_limit_refuses_a_burst_and_says_when_to_retry", function(ctx)
  support.scratch_bot("player", {max_requests_per_second = 1, max_request_burst = 2})
  local codes = {}
  for _ = 1, 8 do
    local envelope = B.observe(support.SCRATCH_BOT, support.request("get_self_state"))
    codes[#codes + 1] = envelope.ok and "ok" or envelope.error.code
  end
  local limited = 0
  for _, code in ipairs(codes) do
    if code == "rate_limited" then limited = limited + 1 end
  end
  ctx.assert.is_true(limited > 0, "the burst is cut off: " .. table.concat(codes, ","))

  local last = B.observe(support.SCRATCH_BOT, support.request("get_self_state"))
  ctx.assert.equal(last.error.code, "rate_limited", "still limited")
  ctx.assert.is_true(last.error.details.retry_after_seconds >= 0, "retry hint present")
  support.drop_scratch_bot()
end)

test("error_envelope_never_carries_a_lua_traceback_or_a_path", function(ctx)
  support.scratch_bot("player")
  local envelope = B.observe(support.SCRATCH_BOT, {operation = "get_area"})
  local text = B.encode_canonical(envelope)
  for _, needle in ipairs({"stack traceback", ".lua:", "/config/", minetest.get_worldpath()}) do
    ctx.assert.is_true(text:find(needle, 1, true) == nil,
      "the envelope does not leak '" .. needle .. "'")
  end
  support.drop_scratch_bot()
end)

test("disabled_bot_is_refused", function(ctx)
  support.scratch_bot("player")
  B.set_enabled(support.SCRATCH_BOT, false, B.SERVER_ACTOR)
  local envelope = B.observe(support.SCRATCH_BOT, support.request("get_self_state"))
  ctx.assert.is_false(envelope.ok, "refused")
  ctx.assert.equal(envelope.error.code, "operation_not_allowed", "code")
  support.drop_scratch_bot()
end)

test("limits_are_discoverable_without_running_anything", function(ctx)
  support.scratch_bot("oracle")
  local limits = B.get_limits(support.SCRATCH_BOT)
  ctx.assert.equal(limits.mode, "oracle", "mode")
  ctx.assert.is_true(#limits.allowed_operations > 10, "operations are listed")
  ctx.assert.is_true(#limits.ray_profiles == 3, "three ray profiles")
  ctx.assert.is_true(limits.hard_limits.request_budget_us > 0, "a time budget exists")
  support.drop_scratch_bot()
end)
