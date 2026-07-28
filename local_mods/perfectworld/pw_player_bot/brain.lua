-- pw_player_bot/brain.lua
--
-- One decision, start to finish.
--
--   observe -> remember -> believe -> feel -> propose -> score -> plan -> intend
--
-- The loop runs on a timer, never per server step, and every stage is bounded.
-- What comes out is an intent document; what does *not* come out is any change
-- to the world or to the player. This mod decides. Something else acts.
--
-- One rule is enforced here rather than merely documented: the brain only ever
-- asks the bridge for player-mode operations. If a bot happens to be registered
-- in oracle mode — because an administrator was diagnosing something — the brain
-- still refuses to think with oracle data. A bot that plans using facts it could
-- not have seen is not a bot, it is a puppet, and the whole point of the
-- exercise is lost.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = P.impl.memory
local beliefs = P.impl.beliefs
local needs = P.impl.needs
local goals = P.impl.goals
local utility = P.impl.utility
local intent = P.impl.intent
local brain = {}
P.impl.brain = brain

--- Operations the brain is allowed to ask for. Anything outside this list would
--- be knowledge a player could not have.
brain.ALLOWED_OPERATIONS = {
  observe = true,
  scan_forward = true,
  scan_left = true,
  scan_right = true,
  scan_up = true,
  scan_down = true,
  get_self_state = true,
  find_visible_entity = true,
  find_visible_feature = true,
  inspect_target = true,
  poll_events = true,
}

function brain.is_allowed_operation(name)
  return brain.ALLOWED_OPERATIONS[name] == true
end

-- player_name -> live brain state. Ephemeral except for the memory inside it.
local minds = {}

function brain.get(player_name)
  return minds[player_name]
end

function brain.list()
  local names = {}
  for name in pairs(minds) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function brain.start(player_name)
  local existing = minds[player_name]
  if existing then return existing end
  local memo, info = memory.load(player_name)
  local mind = {
    player_name = player_name,
    memory = memo,
    beliefs = nil,
    history = {stuck_ticks = 0, failed_routes = 0},
    last_intent = nil,
    intent_age = 0,
    ticks = 0,
    thinking = true,
    last_error = nil,
    stats = {
      ticks = 0,
      intents = 0,
      observation_failures = 0,
      route_failures = 0,
      skipped_fresh_intent = 0,
    },
  }
  minds[player_name] = mind
  -- A bot that has started thinking needs somewhere to publish to, whether or
  -- not the spool was running when the transport last swept its directories.
  if P.impl.transport and P.impl.transport.is_running() then
    P.impl.transport.ensure_bot(player_name)
  end
  minetest.log("action", "[pw_player_bot] thinking for " .. player_name
    .. " (memory " .. (info.loaded and "restored" or "fresh")
    .. ", " .. memo.cell_count .. " cells)")
  return mind
end

function brain.stop(player_name)
  local mind = minds[player_name]
  if not mind then return false end
  memory.save(mind.memory)
  minds[player_name] = nil
  minetest.log("action", "[pw_player_bot] stopped thinking for " .. player_name)
  return true
end

function brain.stop_all()
  for name in pairs(minds) do brain.stop(name) end
end

-- === One tick ===

--- Ask the bridge what the player can perceive. Player-mode operations only.
local function observe(mind)
  local operation = "observe"
  if not brain.is_allowed_operation(operation) then
    return nil, "operation_not_permitted_for_brain"
  end
  local envelope = bridge.observe(mind.player_name, {
    protocol = bridge.PROTOCOL,
    request_id = string.format("brain-%s-%d", mind.player_name, mind.ticks),
    operation = operation,
    parameters = {profile = settings.observation_profile},
  })
  if not envelope.ok then
    return nil, envelope.error.code
  end
  return envelope.data
end

brain.observe = observe

--- Run one decision. Returns the intent and the reasoning behind it.
function brain.tick(mind)
  local started = minetest.get_us_time()
  mind.ticks = mind.ticks + 1
  mind.stats.ticks = mind.stats.ticks + 1

  local observation, failure = observe(mind)
  if not observation then
    mind.stats.observation_failures = mind.stats.observation_failures + 1
    mind.last_error = failure
    -- No perception, no decision. Saying so is better than acting on a stale
    -- picture of the world.
    local document = intent.idle(mind.player_name, mind.ticks,
      "no observation: " .. tostring(failure))
    mind.last_intent = document
    return document, {failure = failure}
  end
  mind.last_error = nil

  memory.integrate(mind.memory, observation)
  local state = observation.self_state or {}
  mind.history = needs.update_history(mind.history, state, mind.memory)
  mind.beliefs = beliefs.rebuild(mind.memory)

  local drives, drive_reasons = needs.evaluate(state, mind.memory, mind.beliefs, mind.history)

  -- An intent that is still fresh is left alone. Re-deciding every tick would
  -- make the bot dither: it would pick a frontier cell, take one step, notice a
  -- slightly better one, and turn around forever. Danger overrides the hold —
  -- committing to a plan is not the same as ignoring a fire.
  if mind.last_intent and mind.intent_age < settings.intent_ttl_ticks
    and (mind.history.stuck_ticks or 0) < 2
    and (drives.safety or 0) <= 0.5 then
    mind.intent_age = mind.intent_age + 1
    mind.stats.skipped_fresh_intent = mind.stats.skipped_fresh_intent + 1
    mind.last_drives = drives
    return mind.last_intent, {reused = true, age = mind.intent_age}
  end

  local candidates = goals.propose(state, mind.memory, mind.beliefs, mind.history)
  local _, alternatives, scored = utility.choose(candidates, drives, mind.memory)

  -- Plan in score order. A goal that cannot be planned is a wish, so it is
  -- dropped and the next one gets its turn.
  local plan, chosen = nil, nil
  local rejected = {}
  for _, entry in ipairs(scored) do
    if entry.score <= utility.IDLE_SCORE and entry.kind ~= "stand_still" then
      -- Nothing left worth doing.
      break
    end
    local built, reason = goals.plan(entry.kind, entry.candidate, state, mind.memory, mind.beliefs)
    if built then
      plan, chosen = built, entry
      break
    end
    rejected[#rejected + 1] = entry.kind .. ":" .. tostring(reason)
    if reason and reason ~= "position_unknown" then
      mind.stats.route_failures = mind.stats.route_failures + 1
      mind.history = needs.note_route_failure(mind.history)
    end
    if minetest.get_us_time() - started > settings.HARD.tick_budget_us then
      break
    end
  end

  if not plan then
    local document = intent.idle(mind.player_name, mind.ticks,
      #rejected > 0 and ("no plan survived: " .. table.concat(rejected, ",")) or "nothing to do")
    mind.last_intent = document
    mind.intent_age = 0
    return document, {drives = drives, rejected = rejected}
  end

  mind.history = needs.note_route_success(mind.history)
  -- Only expect movement when the plan contains some *and* something is there
  -- to carry it out. A brain with no runtime attached is not a bot that failed
  -- to walk, it is a bot with no legs, and counting that as being stuck would
  -- have it forever abandoning perfectly good plans on the evidence that
  -- nobody executed them.
  mind.history.expected_movement = plan.kind == "route"
    and P.impl.transport ~= nil and P.impl.transport.is_running()

  local dominant, dominant_value = needs.dominant(drives)
  local rationale = {}
  for _, reason in ipairs(drive_reasons) do rationale[#rationale + 1] = reason end
  for _, reason in ipairs(chosen.reasons or {}) do rationale[#rationale + 1] = reason end
  rationale[#rationale + 1] = string.format("dominant_need=%s(%.2f)", dominant, dominant_value)
  if #rejected > 0 then
    rationale[#rationale + 1] = "unplannable=" .. table.concat(rejected, ",")
  end

  local document = intent.build(mind.player_name, mind.ticks, {
    goal = {
      kind = chosen.kind,
      score = chosen.score,
      target = chosen.candidate.target,
      feature = chosen.candidate.feature,
      note = chosen.candidate.note or goals.describe(chosen.kind),
    },
    alternatives = alternatives,
    ttl = settings.intent_ttl_ticks,
  }, plan, rationale)

  -- Walking to a feature counts as having looked at it, so the bot does not
  -- circle the same door forever.
  if chosen.kind == "approach_feature" and chosen.candidate.feature_key then
    memory.mark_feature_visited(mind.memory, chosen.candidate.feature_key)
  end

  mind.last_intent = document
  mind.intent_age = 0
  mind.stats.intents = mind.stats.intents + 1
  mind.last_drives = drives
  mind.last_elapsed_us = minetest.get_us_time() - started

  if settings.log_intents then
    P.impl.write_intent_artifact(document)
  end

  -- Hand the decision to whatever is going to carry it out. Publishing is not
  -- executing: the spool is an outbox, and the brain does not wait on it, does
  -- not care whether anything is listening, and does not change its mind
  -- because nothing claimed the last one.
  if P.impl.transport and P.impl.transport.is_running() then
    local published, why = P.impl.transport.publish_intent(mind.player_name, document)
    if not published then
      minetest.log("warning", "[pw_player_bot] could not publish intent for "
        .. mind.player_name .. ": " .. tostring(why))
    end
    P.impl.transport.publish_state(mind.player_name)
  end

  return document, {
    drives = drives,
    dominant = dominant,
    rejected = rejected,
    elapsed_us = mind.last_elapsed_us,
  }
end

function brain.status(player_name)
  local mind = minds[player_name]
  if not mind then return nil end
  return {
    player_name = player_name,
    thinking = mind.thinking,
    ticks = mind.ticks,
    intent_age = mind.intent_age,
    last_error = mind.last_error or canonical.NULL,
    last_elapsed_us = mind.last_elapsed_us or 0,
    memory = memory.summary(mind.memory),
    beliefs = mind.beliefs and beliefs.summary(mind.beliefs) or canonical.NULL,
    drives = mind.last_drives or canonical.NULL,
    history = {
      stuck_ticks = mind.history.stuck_ticks or 0,
      failed_routes = mind.history.failed_routes or 0,
    },
    stats = mind.stats,
    last_execution = mind.last_execution or canonical.NULL,
    last_intent = mind.last_intent and {
      intent_id = mind.last_intent.intent_id,
      goal = mind.last_intent.goal.kind,
      score = mind.last_intent.goal.score,
      route_length = mind.last_intent.plan.route_length,
    } or canonical.NULL,
  }
end

-- === The timer ===

local accumulator = 0

minetest.register_globalstep(function(dtime)
  if not settings.enabled then return end
  accumulator = accumulator + dtime
  if accumulator < settings.tick_interval then return end
  accumulator = 0
  for _, name in ipairs(brain.list()) do
    local mind = minds[name]
    if mind and mind.thinking then
      local ok, err = pcall(brain.tick, mind)
      if not ok then
        minetest.log("error", "[pw_player_bot] tick failed for " .. name .. ": " .. tostring(err))
        mind.last_error = "tick_failed"
      end
    end
  end
end)

--- Persist every mind on shutdown. A bot that forgot the village whenever the
--- server bounced would never build up anything worth calling knowledge.
minetest.register_on_shutdown(function()
  for name, mind in pairs(minds) do
    pcall(memory.save, mind.memory)
    minetest.log("action", "[pw_player_bot] saved memory for " .. name)
  end
end)

return brain
