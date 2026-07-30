-- pw_bot_bridge/tests/unit_transport.lua
--
-- The optional file spool: path safety, the off-by-default rule, and the
-- promise that a malformed request from outside cannot take the server down.

local B = pw_bot_bridge
local support = B.impl.test_support
local canonical = B.impl.canonical
local transport = B.impl.transport

local SUITE = "pw_bot_bridge"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function read(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write(path, content)
  return pcall(minetest.safe_file_write, path, content)
end

test("transport_is_off_by_default_and_needs_no_insecure_environment", function(ctx)
  local status = transport.status()
  ctx.assert.equal(status.requires_insecure_environment, false,
    "the spool works inside the normal mod sandbox")
  ctx.assert.equal(B.get_capabilities().transport.kind, "file_spool", "transport kind")

  -- The default, not the deployment.
  --
  -- This used to read the live setting and assert it was off, which made it a
  -- test of whoever wrote the config file rather than of this mod. On a machine
  -- where the operator had turned the spool on — which is every machine running
  -- `pw_bot_runtime` — it failed permanently and said nothing. Take the setting
  -- away, re-read, and put it back: that asks the question the name promises.
  local key = "pw_bot_bridge.external_transport"
  local before = minetest.settings:get(key)
  minetest.settings:remove(key)
  local default_value = B.impl.settings.reload().external_transport
  if before ~= nil then minetest.settings:set(key, before) end
  B.impl.settings.reload()

  ctx.assert.equal(default_value, false,
    "with nothing in the configuration the spool stays off")
  ctx.assert.equal(B.impl.settings.external_transport,
    minetest.settings:get_bool(key, false),
    "and the configuration is put back exactly as it was found")
end)

test("transport_reports_which_filesystem_primitives_it_has", function(ctx)
  local available, missing, caps = transport.available()
  ctx.assert.not_nil(caps, "the probe returns what it found")
  if not available then
    return ctx.skip("sandbox lacks: " .. table.concat(missing, ","))
  end
  for _, name in ipairs({"mkdir", "dir_list", "safe_file_write", "io_open", "os_remove"}) do
    ctx.assert.is_true(caps[name], name .. " is available")
  end
  ctx.assert.is_true(available, "the spool can run here")
end)

test("transport_rejects_path_traversal_in_every_component", function(ctx)
  for _, bad in ipairs({"../escape", "a/b", "a\\b", "..", "x/../y", ""}) do
    ctx.assert.is_nil(transport.safe_component(bad), "component refused: " .. bad)
    ctx.assert.is_nil(transport.path("requests", bad), "path refused: " .. bad)
  end
  ctx.assert.not_nil(transport.path("requests", "pwbot"), "a legal path is built")
  ctx.assert.is_true(transport.path("requests", "pwbot"):find(minetest.get_worldpath(), 1, true) == 1,
    "every spool path stays under the world directory")

  for _, bad in ipairs({"../x.json", "a/b.json", "no_extension", "req.json.exe", ".json"}) do
    ctx.assert.is_false(transport.is_valid_file_name(bad), "file name refused: " .. bad)
  end
  ctx.assert.is_true(transport.is_valid_file_name("req-0001.json"), "a legal file name")
end)

test("transport_round_trips_a_request_and_refuses_a_malformed_one", function(ctx)
  local available, missing = transport.available()
  if not available then
    return ctx.skip("sandbox lacks: " .. table.concat(missing, ","))
  end

  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    B.register_bot(name, {mode = "player"}, B.SERVER_ACTOR)
    local started = transport.start(B.SERVER_ACTOR)
    ctx.assert.is_true(started, "the transport starts on demand")
    transport.ensure_bot(name)

    local request_dir = transport.path("requests", name)
    local response_dir = transport.path("responses", name)

    -- A well-formed request comes back as a well-formed response.
    local ok = write(request_dir .. "/tr-good.json", canonical.encode({
      protocol = B.PROTOCOL,
      request_id = "tr-good",
      operation = "get_self_state",
    }))
    ctx.assert.is_true(ok, "the request file was written")
    transport.tick()
    ctx.assert.is_nil(read(request_dir .. "/tr-good.json"), "the request file was consumed")

    local answer = read(response_dir .. "/tr-good.json")
    ctx.assert.not_nil(answer, "a response file appeared")
    local decoded = minetest.parse_json(answer)
    ctx.assert.equal(decoded.protocol, "pw_bot_bridge/v1", "the response is versioned")
    ctx.assert.equal(decoded.request_id, "tr-good", "the request id came back")
    ctx.assert.is_true(decoded.ok, "the observation succeeded")
    ctx.assert.equal(decoded.mode, "player", "the response states the mode")
    ctx.assert.not_nil(decoded.data.self_state, "self state is present")

    -- Malformed JSON must not raise, must not answer, and must be recorded.
    write(request_dir .. "/tr-bad.json", "{ this is not json ")
    local survived = pcall(transport.tick)
    ctx.assert.is_true(survived, "a malformed request does not raise")
    ctx.assert.is_nil(read(request_dir .. "/tr-bad.json"), "the bad request was removed")
    local rejected = read(transport.path("rejected", name .. ".tr-bad.json"))
    ctx.assert.not_nil(rejected, "the rejection was recorded")
    ctx.assert.is_true(rejected:find("malformed_json", 1, true) ~= nil,
      "the reason is stated: " .. tostring(rejected))

    -- A request claiming to be somebody else is refused, whatever it says.
    write(request_dir .. "/tr-spoof.json", canonical.encode({
      protocol = B.PROTOCOL,
      request_id = "tr-spoof",
      player_name = "somebody_else",
      operation = "get_self_state",
    }))
    transport.tick()
    local spoof = read(transport.path("rejected", name .. ".tr-spoof.json"))
    ctx.assert.not_nil(spoof, "the spoofed name was rejected")
    ctx.assert.is_true(spoof:find("player_name_mismatch", 1, true) ~= nil, "reason stated")

    -- The same request id twice is a replay, not a second question.
    write(request_dir .. "/tr-dup.json", canonical.encode({
      protocol = B.PROTOCOL, request_id = "tr-dup", operation = "get_self_state",
    }))
    transport.tick()
    write(request_dir .. "/tr-dup.json", canonical.encode({
      protocol = B.PROTOCOL, request_id = "tr-dup", operation = "get_self_state",
    }))
    transport.tick()
    local duplicate = minetest.parse_json(read(response_dir .. "/tr-dup.json") or "{}")
    ctx.assert.is_false(duplicate.ok, "the replay was refused")
    ctx.assert.equal(duplicate.error.code, "invalid_request", "code")
    ctx.assert.equal(duplicate.error.details.reason, "duplicate_request_id", "reason")

    -- An oversized request never reaches the parser.
    write(request_dir .. "/tr-big.json", string.rep("x", 200000))
    transport.tick()
    local big = read(transport.path("rejected", name .. ".tr-big.json"))
    ctx.assert.not_nil(big, "the oversized request was rejected")
    ctx.assert.is_true(big:find("too_large", 1, true) ~= nil, "reason stated")

    -- No protocol operation can administer the bridge.
    write(request_dir .. "/tr-escalate.json", canonical.encode({
      protocol = B.PROTOCOL, request_id = "tr-escalate",
      operation = "set_mode", parameters = {mode = "oracle"},
    }))
    transport.tick()
    local escalate = minetest.parse_json(read(response_dir .. "/tr-escalate.json") or "{}")
    ctx.assert.is_false(escalate.ok, "set_mode is not an operation")
    ctx.assert.equal(escalate.error.code, "unsupported_operation", "code")
    ctx.assert.equal(B.get_mode(name), "player", "the mode did not change")

    -- The event mirror is written and says it is read only.
    local mirror = read(transport.path("events", name, "pending.json"))
    ctx.assert.not_nil(mirror, "the event mirror exists")
    ctx.assert.is_true(mirror:find("read-only mirror", 1, true) ~= nil,
      "the mirror declares that it does not advance the cursor")

    for _, file in ipairs({"tr-good.json", "tr-dup.json", "tr-escalate.json"}) do
      pcall(os.remove, response_dir .. "/" .. file)
    end
    for _, file in ipairs({"tr-bad.json", "tr-spoof.json", "tr-big.json"}) do
      pcall(os.remove, transport.path("rejected", name .. "." .. file))
    end
    transport.stop(B.SERVER_ACTOR)
  end)

  ctx.assert.is_false(transport.is_running(), "the transport stops again")
end)

test("transport_start_and_stop_require_authorisation", function(ctx)
  local ok, code = transport.start("pw_bridge_no_such_admin")
  ctx.assert.is_false(ok, "an unprivileged actor cannot start the spool")
  ctx.assert.equal(code, "permission_denied", "code")
  local stop_ok, stop_code = transport.stop("pw_bridge_no_such_admin")
  ctx.assert.is_false(stop_ok, "an unprivileged actor cannot stop it either")
  ctx.assert.equal(stop_code, "permission_denied", "code")
end)

test("transport_spool_is_not_tracked_by_git", function(ctx)
  -- The spool lives in the world directory, which the repository ignores in
  -- full. This test states the requirement where a future change would notice.
  ctx.assert.is_true(transport.root_path():find(minetest.get_worldpath(), 1, true) == 1,
    "the spool root is inside the world directory, which is gitignored")
  ctx.assert.equal(transport.ROOT_NAME, "pw_bot_bridge", "documented spool directory name")
end)
