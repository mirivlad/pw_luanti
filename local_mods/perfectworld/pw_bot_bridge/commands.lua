-- pw_bot_bridge/commands.lua
--
-- Development and administration commands.
--
-- Two rules apply to all of them: every command checks the `pw_bot_admin`
-- privilege (being able to type a command proves nothing), and no command
-- prints a large document into chat. Full observations go to a runtime artifact
-- in the world directory and chat gets a one-screen summary.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local permissions = B.impl.permissions
local protocol = B.impl.protocol
local registry = B.impl.registry
local settings = B.impl.settings
local capabilities = B.impl.capabilities
local transport = B.impl.transport
local semantics = B.impl.semantics

local ADMIN = {[permissions.PRIV] = true}

local function test_player_name()
  return minetest.settings:get("perfectworld.test_player") or "pwbot"
end

--- Write a development report next to the test kit's own reports.
-- Returns the file name only; the full path stays out of chat and out of any
-- protocol response, because a server filesystem layout is not a bot's business.
local function write_report(kind, value)
  local stamp = os.date("!%Y%m%d_%H%M%S")
  local file_name = string.format("pw_bot_bridge_%s_%s.json", kind, stamp)
  local path = minetest.get_worldpath() .. "/" .. file_name
  local ok = pcall(minetest.safe_file_write, path, canonical.encode(value))
  if not ok then return nil end
  return file_name
end

B.impl.write_report = write_report

local function lines(rows)
  return table.concat(rows, "\n")
end

minetest.register_chatcommand("pw_bot_bridge_status", {
  params = "",
  description = "Show bridge status, registered bots and their sessions",
  privs = ADMIN,
  func = function()
    local rows = {
      string.format("capability=%s impl=%s enabled=%s",
        protocol.ID, protocol.IMPLEMENTATION_VERSION, tostring(settings.enabled)),
      string.format("default_mode=%s view=%d fov=%dx%d profile=%s",
        settings.default_mode, settings.player_view_distance,
        settings.player_horizontal_fov, settings.player_vertical_fov,
        settings.player_ray_profile),
      string.format("oracle_max_radius=%d oracle_max_nodes=%d rate=%.1f/s burst=%d",
        settings.oracle_max_radius, settings.oracle_max_nodes,
        settings.max_requests_per_second, settings.max_request_burst),
      string.format("transport setting=%s running=%s",
        tostring(settings.external_transport), tostring(transport.is_running())),
      string.format("bots=%d", registry.count()),
    }
    for _, name in ipairs(registry.list_names()) do
      local bot = registry.get(name)
      local info = B.get_session_info(name)
      rows[#rows + 1] = string.format(
        "  %s mode=%s enabled=%s connected=%s seq=%d events=%d dropped=%d served=%d",
        name, bot.mode, tostring(bot.enabled),
        tostring(info and info.connected), info and info.sequence or 0,
        info and info.events_queued or 0, info and info.events_dropped or 0,
        info and info.requests_served or 0)
    end
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_bot_bridge_register", {
  params = "<player> [player|oracle]",
  description = "Register a bot and assign its perception mode",
  privs = ADMIN,
  func = function(name, param)
    local target, mode = param:match("^(%S+)%s+(%S+)$")
    if not target then
      target = param:match("^(%S+)$")
      mode = settings.default_mode
    end
    if not target then
      return false, "Usage: /pw_bot_bridge_register <player> [player|oracle]"
    end
    local bot, code, detail = B.register_bot(target, {mode = mode}, name)
    if not bot then
      return false, string.format("refused: %s (%s)", tostring(code), tostring(detail))
    end
    transport.ensure_bot(target)
    return true, string.format("registered %s mode=%s by=%s", bot.player_name, bot.mode, name)
  end,
})

minetest.register_chatcommand("pw_bot_bridge_unregister", {
  params = "<player>",
  description = "Remove a bot registration",
  privs = ADMIN,
  func = function(name, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_bot_bridge_unregister <player>" end
    local ok, code, detail = B.unregister_bot(target, name)
    if not ok then
      return false, string.format("refused: %s (%s)", tostring(code), tostring(detail))
    end
    return true, "unregistered " .. target
  end,
})

minetest.register_chatcommand("pw_bot_bridge_mode", {
  params = "<player> <player|oracle>",
  description = "Change a bot's perception mode",
  privs = ADMIN,
  func = function(name, param)
    local target, mode = param:match("^(%S+)%s+(%S+)$")
    if not target then return false, "Usage: /pw_bot_bridge_mode <player> <player|oracle>" end
    local ok, result, detail = B.set_mode(target, mode, name)
    if not ok then
      return false, string.format("refused: %s (%s)", tostring(result), tostring(detail))
    end
    return true, string.format("%s is now in %s mode", target, result.mode)
  end,
})

minetest.register_chatcommand("pw_bot_bridge_capabilities", {
  params = "",
  description = "Summarise the capability document and save the full one",
  privs = ADMIN,
  func = function()
    local summary = capabilities.summary()
    local file_name = write_report("capabilities", B.get_capabilities())
    local rows = {
      string.format("capability=%s impl=%s enabled=%s",
        summary.capability, summary.implementation_version, tostring(summary.enabled)),
      string.format("modes=%s profiles=%s", summary.modes, summary.ray_profiles),
      string.format("operations player=%d oracle=%d event_types=%d",
        summary.player_operations, summary.oracle_operations, summary.event_types),
      string.format("external_transport=%s", tostring(summary.external_transport)),
      file_name and ("full document: " .. file_name) or "full document could not be written",
    }
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_bot_bridge_limits", {
  params = "<player>",
  description = "Show the limits and allowed operations of a bot",
  privs = ADMIN,
  func = function(_, param)
    local target = param:match("^(%S+)$")
    if not target then return false, "Usage: /pw_bot_bridge_limits <player>" end
    local limits = B.get_limits(target)
    if not limits then return false, "not registered: " .. target end
    local rows = {
      string.format("%s mode=%s", target, limits.mode),
      string.format("view=%d fov=%dx%d entities=%d",
        limits.limits.view_distance, limits.limits.horizontal_fov,
        limits.limits.vertical_fov, limits.limits.max_entities),
      string.format("oracle radius=%d nodes=%d",
        limits.limits.oracle_max_radius, limits.limits.oracle_max_nodes),
      string.format("rate=%.1f/s burst=%d events=%d response=%d bytes",
        limits.limits.max_requests_per_second, limits.limits.max_request_burst,
        limits.limits.event_queue_size, limits.limits.max_response_bytes),
      "operations: " .. table.concat(limits.allowed_operations, ","),
    }
    return true, lines(rows)
  end,
})

--- Summarise an observation without dumping it into chat.
local function summarise_envelope(envelope)
  if not envelope.ok then
    return string.format("error=%s %s", envelope.error.code, envelope.error.message)
  end
  local data = envelope.data or {}
  local rows = {string.format("ok mode=%s seq=%d", envelope.mode, envelope.sequence)}
  if data.self_state then
    local state = data.self_state
    rows[#rows + 1] = string.format("pos=%.1f,%.1f,%.1f yaw=%.2f pitch=%.2f ground=%s liquid=%s",
      state.position.x, state.position.y, state.position.z,
      state.yaw, state.pitch, tostring(state.on_ground), tostring(state.in_liquid))
    rows[#rows + 1] = string.format("under=%s feet=%s head=%s",
      state.node_under.name or "?", state.node_at_feet.name or "?", state.node_at_head.name or "?")
  end
  local function count(value)
    if type(value) ~= "table" then return 0 end
    if value == canonical.EMPTY_ARRAY then return 0 end
    return #value
  end
  if data.rays then
    local hits = 0
    for _, ray in ipairs(data.rays == canonical.EMPTY_ARRAY and {} or data.rays) do
      if ray.hit_type == "node" then hits = hits + 1 end
    end
    rows[#rows + 1] = string.format("rays=%d hits=%d skipped=%d",
      count(data.rays), hits, data.rays_skipped_outside_sector or 0)
  end
  if data.visible_entities then
    rows[#rows + 1] = "visible_entities=" .. count(data.visible_entities)
  end
  if data.visible_features then
    rows[#rows + 1] = "visible_features=" .. count(data.visible_features)
  end
  if data.nodes then rows[#rows + 1] = "nodes=" .. count(data.nodes) end
  if data.findings then
    rows[#rows + 1] = string.format("findings=%d", data.finding_count or count(data.findings))
  end
  if data.budget then
    rows[#rows + 1] = string.format("budget nodes=%d us=%d truncated=%s",
      data.budget.nodes_examined, data.budget.elapsed_us, tostring(data.budget.truncated))
  end
  return lines(rows)
end

B.impl.summarise_envelope = summarise_envelope

local function run_observation(target, operation, params)
  local request = {
    protocol = protocol.ID,
    request_id = "cmd-" .. tostring(minetest.get_us_time()),
    operation = operation,
    parameters = params or {},
  }
  local started = minetest.get_us_time()
  local envelope = B.observe(target, request)
  local elapsed = minetest.get_us_time() - started
  local text = canonical.encode(envelope)
  local file_name = write_report(operation, envelope)
  local rows = {summarise_envelope(envelope)}
  rows[#rows + 1] = string.format("response=%d bytes in %d us", #text, elapsed)
  rows[#rows + 1] = file_name and ("report: " .. file_name) or "report could not be written"
  return true, lines(rows)
end

minetest.register_chatcommand("pw_bot_bridge_observe", {
  params = "<player> [minimal|navigation|detailed]",
  description = "Run one observation for a bot and save the full report",
  privs = ADMIN,
  func = function(name, param)
    local target, profile = param:match("^(%S+)%s+(%S+)$")
    if not target then
      target = param:match("^(%S+)$")
    end
    if not target then return false, "Usage: /pw_bot_bridge_observe <player> [profile]" end
    return run_observation(target, "observe", profile and {profile = profile} or {})
  end,
})

minetest.register_chatcommand("pw_bot_bridge_events", {
  params = "<player> [max]",
  description = "Poll a bot's event queue and summarise it",
  privs = ADMIN,
  func = function(_, param)
    local target, max = param:match("^(%S+)%s+(%d+)$")
    if not target then target = param:match("^(%S+)$") end
    if not target then return false, "Usage: /pw_bot_bridge_events <player> [max]" end
    local envelope = B.poll_events(target, {max = tonumber(max) or 16})
    if not envelope.ok then
      return false, string.format("error=%s %s", envelope.error.code, envelope.error.message)
    end
    local data = envelope.data
    local rows = {string.format("queue=%d/%d dropped=%d cursor=%d remaining=%d",
      data.queue_size, data.queue_capacity, data.dropped, data.cursor, data.remaining)}
    for _, event in ipairs(data.events == canonical.EMPTY_ARRAY and {} or data.events) do
      rows[#rows + 1] = string.format("  #%d %s", event.sequence, event.type)
    end
    return true, lines(rows)
  end,
})

minetest.register_chatcommand("pw_bot_bridge_transport", {
  params = "<status|start|stop>",
  description = "Inspect or toggle the external file transport for this session",
  privs = ADMIN,
  func = function(name, param)
    local action = param:match("^(%S+)$") or "status"
    if action == "start" then
      local ok, code, detail = transport.start(name)
      if not ok then
        return false, string.format("refused: %s (%s)", tostring(code),
          type(detail) == "table" and table.concat(detail, ",") or tostring(detail))
      end
      settings.external_transport = true
    elseif action == "stop" then
      local ok, code = transport.stop(name)
      if not ok then return false, "refused: " .. tostring(code) end
      settings.external_transport = false
    elseif action ~= "status" then
      return false, "Usage: /pw_bot_bridge_transport <status|start|stop>"
    end
    local status = transport.status()
    local rows = {
      string.format("setting=%s running=%s available=%s insecure_env_required=%s",
        tostring(status.enabled_by_setting), tostring(status.running),
        tostring(status.available), tostring(status.requires_insecure_environment)),
      string.format("root=<worldpath>/%s poll=%.2fs max_request=%d bytes",
        status.root, status.poll_interval, status.max_request_bytes),
    }
    if status.missing_primitives ~= canonical.EMPTY_ARRAY then
      rows[#rows + 1] = "missing: " .. table.concat(status.missing_primitives, ",")
    end
    rows[#rows + 1] = "note: the toggle applies to this server session; "
      .. "set pw_bot_bridge.external_transport to make it persist"
    return true, lines(rows)
  end,
})

--- Convenience: everything about the project's own test player in one call.
minetest.register_chatcommand("pwbot_bridge", {
  params = "[observe|status|events]",
  description = "Bridge shortcut for the configured PerfectWorld test player",
  privs = ADMIN,
  func = function(name, param)
    local target = test_player_name()
    local action = param:match("^(%S+)$") or "status"
    if not registry.raw(target) then
      local bot = B.register_bot(target, {mode = "player"}, name)
      if not bot then return false, "could not register " .. target end
      transport.ensure_bot(target)
    end
    if action == "observe" then
      return run_observation(target, "observe", {})
    elseif action == "events" then
      return minetest.registered_chatcommands["pw_bot_bridge_events"].func(name, target)
    end
    local info = B.get_session_info(target)
    local bot = B.get_bot(target)
    return true, lines({
      string.format("%s mode=%s enabled=%s connected=%s",
        target, bot.mode, tostring(bot.enabled), tostring(info and info.connected)),
      string.format("session=%s seq=%d events=%d dropped=%d",
        info and info.session_id or "?", info and info.sequence or 0,
        info and info.events_queued or 0, info and info.events_dropped or 0),
    })
  end,
})

--- A cheap internal consistency check. It is not a substitute for the TestKit
--- suite; it is what an operator runs to see the bridge is wired up at all.
minetest.register_chatcommand("pw_bot_bridge_selftest", {
  params = "",
  description = "Run the bridge's internal consistency checks",
  privs = ADMIN,
  func = function(name)
    local checks, failures = {}, 0
    local function check(label, ok, detail)
      checks[#checks + 1] = {name = label, ok = ok and true or false, detail = detail or ""}
      if not ok then failures = failures + 1 end
    end

    check("capability_id", B.get_version() == protocol.ID, B.get_version())

    local doc = B.get_capabilities()
    check("capability_document", type(doc) == "table" and #doc.protocols == 1)
    check("modes_are_player_and_oracle",
      table.concat(doc.modes, ",") == "oracle,player", table.concat(doc.modes, ","))

    local first = canonical.encode(doc)
    local second = canonical.encode(B.get_capabilities())
    check("canonical_encoding_is_stable", first == second)

    local sample = {b = 1, a = {2, 1}, c = canonical.EMPTY_ARRAY, d = canonical.NULL}
    check("canonical_key_order",
      canonical.encode(sample) == '{"a":[2,1],"b":1,"c":[],"d":null}',
      canonical.encode(sample))

    check("error_codes_closed", protocol.is_error_code("operation_not_allowed")
      and not protocol.is_error_code("nonsense"))

    local denied = protocol.error("x", "permission_denied")
    check("error_envelope_shape",
      denied.protocol == protocol.ID and denied.ok == false
      and denied.error.code == "permission_denied")

    check("player_mode_refuses_get_area",
      not B.impl.validation.is_allowed("player", "get_area"))
    check("oracle_mode_allows_get_area",
      B.impl.validation.is_allowed("oracle", "get_area"))

    check("semantics_loaded", #semantics.registered_group_names() > 0,
      tostring(#semantics.registered_group_names()))

    local air = B.describe_node("air", 0)
    check("air_is_passable", air.properties.blocks_sight == false)

    local transport_status = transport.status()
    check("transport_needs_no_insecure_env",
      transport_status.requires_insecure_environment == false)

    local file_name = write_report("selftest", {
      generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      actor = name,
      failures = failures,
      checks = checks,
    })

    local rows = {string.format("selftest: %d checks, %d failed", #checks, failures)}
    for _, entry in ipairs(checks) do
      if not entry.ok then
        rows[#rows + 1] = "  FAIL " .. entry.name .. " " .. tostring(entry.detail)
      end
    end
    rows[#rows + 1] = file_name and ("report: " .. file_name) or "report could not be written"
    return failures == 0, lines(rows)
  end,
})

minetest.log("action", "[pw_bot_bridge] commands loaded")
