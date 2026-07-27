-- pw_player_bot/tests/unit_transport.lua
--
-- The channel between the brain and the runtime that drives a real client.
--
-- What matters here is not that files move. It is that the brain cannot be
-- lied to by whatever is on the other end: an unknown status, a replayed
-- result, a malformed document and a result for a bot nobody is thinking for
-- must each be refused in a way that leaves the brain exactly as it was.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local support = P.impl.test_support
local transport = P.impl.transport
local intent = P.impl.intent
local brain = P.impl.brain

local SUITE = "pw_player_bot"
local function test(name, fn, opts)
  luanti_testkit.register_test(SUITE, name, fn, opts)
end

local function result(intent_id, fields)
  local out = {
    protocol = intent.PROTOCOL,
    intent_id = intent_id,
    ok = false,
    status = "no_progress",
  }
  for key, value in pairs(fields or {}) do out[key] = value end
  return out
end

test("transport_paths_cannot_escape_the_spool", function(ctx)
  ctx.assert.not_nil(transport.path("intents", "pwbot"), "an ordinary path is built")
  for _, bad in ipairs({"../etc", "a/b", "a\\b", "..", ""}) do
    ctx.assert.is_nil(transport.path("intents", bad),
      "a path component that could escape is refused: '" .. bad .. "'")
  end
  ctx.assert.is_false(transport.is_valid_file_name("../x.json"), "traversal is not a file name")
  ctx.assert.is_false(transport.is_valid_file_name("x.txt"), "only .json is accepted")
  ctx.assert.is_true(transport.is_valid_file_name("intent-pwbot-3.json"), "a real intent name passes")
end)

test("transport_declares_a_closed_set_of_execution_statuses", function(ctx)
  local status = transport.status()
  ctx.assert.equal(status.protocol, "pw_player_bot/v1", "the spool is versioned")
  ctx.assert.is_true(#status.statuses >= 10, "every outcome is named")
  for _, name in ipairs({"reached", "blocked", "timeout", "no_progress",
                         "operator_stopped", "client_disconnected", "unknown"}) do
    ctx.assert.is_true(transport.is_known_status(name), name .. " is a known outcome")
  end
  ctx.assert.is_false(transport.is_known_status("probably_fine"),
    "a word the brain does not know is not an outcome")
end)

test("transport_refuses_a_result_it_cannot_trust", function(ctx)
  local cases = {
    {doc = "not a table", reason = "not_a_table"},
    {doc = {protocol = "other/v1", intent_id = "i", ok = true, status = "reached"},
     reason = "wrong_protocol"},
    {doc = {protocol = intent.PROTOCOL, ok = true, status = "reached"},
     reason = "missing_intent_id"},
    {doc = {protocol = intent.PROTOCOL, intent_id = "i", ok = true},
     reason = "missing_status"},
    {doc = {protocol = intent.PROTOCOL, intent_id = "i", ok = true, status = "vibes"},
     reason = "unknown_status:vibes"},
    {doc = {protocol = intent.PROTOCOL, intent_id = "i", status = "reached"},
     reason = "missing_ok"},
  }
  for _, case in ipairs(cases) do
    local ok, reason = transport.validate_result(case.doc)
    ctx.assert.is_false(ok, "refused: " .. case.reason)
    ctx.assert.equal(reason, case.reason, "and says exactly why")
  end
end)

test("transport_ingests_a_result_and_the_brain_reacts_to_it", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    transport._test_reset_ingested()

    local mind = brain.get(name)
    mind.history.failed_routes = 0
    mind.history.stuck_ticks = 0

    local ok, info = P.report_execution(name, result("intent-probe-1"))
    ctx.assert.is_true(ok, "a well-formed result is accepted")
    ctx.assert.equal(info.status, "no_progress", "and recorded as what it was")
    ctx.assert.is_true(mind.history.failed_routes > 0,
      "a body that did not get there is a route that did not work")
    ctx.assert.is_true(mind.history.stuck_ticks > 0,
      "and it counts towards being stuck, which is what promotes unstick")

    -- Success clears the failure history: the plan worked, and holding the
    -- failures against it afterwards would make the bot permanently timid.
    local ok2 = P.report_execution(name, result("intent-probe-2",
      {ok = true, status = "reached"}))
    ctx.assert.is_true(ok2, "a success is accepted too")
    ctx.assert.equal(mind.history.failed_routes, 0, "arriving clears the failures")
  end)
end)

test("transport_never_counts_the_same_result_twice", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    transport._test_reset_ingested()

    local mind = brain.get(name)
    mind.history.failed_routes = 0

    ctx.assert.is_true(P.report_execution(name, result("intent-dup-1")),
      "the first report is taken")
    local before = mind.history.failed_routes

    -- A runtime that crashed after writing a result and rewrites it on restart
    -- must not be able to make the brain count the same failure again.
    local ok, why = P.report_execution(name, result("intent-dup-1"))
    ctx.assert.is_false(ok, "the replay is refused")
    ctx.assert.equal(why, "already_ingested", "and named as a replay")
    ctx.assert.equal(mind.history.failed_routes, before,
      "the failure history did not move")
  end)
end)

test("transport_expires_the_intent_the_result_answered", function(ctx)
  local player, name, reason = support.require_player(ctx)
  if not player then return ctx.skip(reason) end

  support.with_bot_state(name, function()
    bridge.register_bot(name, {mode = "player", limits = {
      max_requests_per_second = 100, max_request_burst = 200,
    }}, support.ACTOR)
    P.forget(name, support.ACTOR)
    P.start(name, support.ACTOR)
    transport._test_reset_ingested()

    local document = P.think(name, support.ACTOR)
    ctx.assert.not_nil(document, "the brain decided something")
    local mind = brain.get(name)
    mind.intent_age = 0

    P.report_execution(name, result(document.intent_id, {status = "blocked"}))
    ctx.assert.is_true(mind.intent_age >= P.impl.settings.intent_ttl_ticks,
      "an answered intent is stale, whatever its age says; the world already replied")
  end)
end)

test("transport_result_for_an_unknown_bot_changes_nothing", function(ctx)
  transport._test_reset_ingested()
  local ok, why = P.report_execution("pw_brain_nobody_here", result("intent-ghost-1"))
  ctx.assert.is_false(ok, "there is no brain to tell")
  ctx.assert.equal(why, "not_started", "and it says so rather than inventing one")
end)

test("transport_publishes_only_valid_intents", function(ctx)
  local running = transport.is_running()
  if not running then
    local started = transport.start()
    if not started then return ctx.skip("the spool cannot run in this sandbox") end
  end

  local ok, why = transport.publish_intent(support.SCRATCH_BOT,
    {protocol = "something/else", intent_id = "x"})
  ctx.assert.is_false(ok, "a document that is not an intent is not published")
  ctx.assert.equal(why, "wrong_protocol", "and the reason is the validator's")

  local document = intent.idle(support.SCRATCH_BOT, 1, "transport probe")
  ctx.assert.is_true(transport.publish_intent(support.SCRATCH_BOT, document),
    "a real intent is published")

  local dir = transport.path("intents", support.SCRATCH_BOT)
  local found = false
  for _, file in ipairs(transport.list_files(dir)) do
    if file == document.intent_id .. ".json" then found = true end
  end
  ctx.assert.is_true(found, "and lands under its own id, so the runtime can claim it")

  -- Leave the spool as it was found.
  os.remove(dir .. "/" .. document.intent_id .. ".json")
  if not running then transport.stop() end
end)
