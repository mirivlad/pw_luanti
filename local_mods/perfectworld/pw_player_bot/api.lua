-- pw_player_bot/api.lua
--
-- The public API. A future controller reads intents through this; a future
-- extension registers goals through it.
--
-- Everything under pw_player_bot.impl is private and may change without notice.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = P.impl.memory
local beliefs = P.impl.beliefs
local navigation = P.impl.navigation
local goals = P.impl.goals
local needs = P.impl.needs
local utility = P.impl.utility
local intent = P.impl.intent
local brain = P.impl.brain

P.PROTOCOL = intent.PROTOCOL
P.VERSION = intent.IMPLEMENTATION_VERSION

-- === Discovery ===

function P.get_version()
  return intent.PROTOCOL
end

function P.get_implementation_version()
  return intent.IMPLEMENTATION_VERSION
end

--- What this build can do, in a form a controller can read instead of assume.
function P.get_capabilities()
  return {
    capability = intent.PROTOCOL,
    protocols = {intent.PROTOCOL},
    implementation_version = intent.IMPLEMENTATION_VERSION,
    requires = {
      bridge = bridge.get_version(),
      bridge_mode = "player",
    },
    goal_kinds = goals.list_kinds(),
    needs = needs.NAMES,
    actions = intent.list_actions(),
    features_of_interest = (function()
      local out = {}
      for feature in pairs(goals.FEATURE_INTEREST) do out[#out + 1] = feature end
      table.sort(out)
      return out
    end)(),
    contract = {
      principle = "the bridge perceives, this mod decides, a real client acts",
      decides = {
        "what is worth doing, from bounded memory of what was observed",
        "a route over remembered cells only",
        "an intent describing the actions a controller should take",
      },
      never = {
        "move the player",
        "turn the head",
        "press a key",
        "place or remove a node",
        "read the map directly",
        "use oracle-mode data to decide",
      },
      not_provided = {
        "client control",
        "screenshot or image based perception",
        "LLM integration",
        "building or crafting",
      },
    },
    determinism = {
      rule = "the same memory and the same observation produce the same intent",
      tie_break = "hash of candidate label and memory tick via perfectworld.core.choice",
      randomness = "none: math.random is never called",
    },
    persistence = {
      persisted = {"remembered cells", "remembered features", "visited columns", "memory statistics"},
      not_persisted = {"beliefs", "drives", "current intent", "bridge observation ids", "stuck counters"},
    },
    limits = settings.snapshot(),
  }
end

function P.get_settings()
  return settings.snapshot()
end

function P.reload_settings(actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  settings.reload()
  return true, settings.snapshot()
end

-- === Lifecycle ===

--- Start thinking for a bot.
--
-- The bot must already be registered with pw_bot_bridge: perception is granted
-- by the server, and this mod is a consumer of that grant, not a second way to
-- obtain one.
function P.start(player_name, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return nil, "permission_denied", reason end
  local bot = bridge.get_bot(player_name)
  if not bot then
    return nil, "bot_not_registered", "register the player with pw_bot_bridge first"
  end
  return brain.start(player_name)
end

function P.stop(player_name, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  return brain.stop(player_name)
end

function P.list()
  return brain.list()
end

function P.is_thinking(player_name)
  local mind = brain.get(player_name)
  return mind ~= nil and mind.thinking == true
end

--- Pause or resume without discarding memory.
function P.set_thinking(player_name, thinking, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  local mind = brain.get(player_name)
  if not mind then return false, "not_started" end
  mind.thinking = thinking and true or false
  return true, mind.thinking
end

-- === Thinking ===

--- Run one decision now, outside the timer. Used by the tests and by the
--- chatcommands so a human can watch a single step.
function P.think(player_name, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return nil, "permission_denied", reason end
  local mind = brain.get(player_name)
  if not mind then return nil, "not_started" end
  return brain.tick(mind)
end

--- The current intent, or nil. This is what a controller polls.
function P.get_intent(player_name)
  local mind = brain.get(player_name)
  if not mind then return nil end
  return mind.last_intent
end

function P.get_intent_json(player_name)
  local document = P.get_intent(player_name)
  if not document then return nil end
  return canonical.encode(document)
end

function P.validate_intent(document)
  return intent.validate(document)
end

function P.get_status(player_name)
  return brain.status(player_name)
end

-- === Memory ===

function P.get_memory_summary(player_name)
  local mind = brain.get(player_name)
  if not mind then return nil end
  return memory.summary(mind.memory)
end

function P.get_beliefs_summary(player_name)
  local mind = brain.get(player_name)
  if not mind or not mind.beliefs then return nil end
  return beliefs.summary(mind.beliefs)
end

function P.save_memory(player_name, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  local mind = brain.get(player_name)
  if not mind then return false, "not_started" end
  return memory.save(mind.memory)
end

--- Wipe what a bot has learned. Destructive and deliberate: an administrator
--- asking for this is asking for a bot that has never been here before.
function P.forget(player_name, actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  local mind = brain.get(player_name)
  local fresh = memory.forget(player_name)
  if mind then
    mind.memory = fresh
    mind.beliefs = nil
    mind.last_intent = nil
    mind.history = {stuck_ticks = 0, failed_routes = 0}
  end
  return true
end

--- Route between two positions using only what the bot remembers.
-- Exposed because "why did it not go there" is the question a developer asks
-- most, and the answer is usually that the bot has never seen the way.
function P.plan_route(player_name, from, to)
  local mind = brain.get(player_name)
  if not mind then return nil, "not_started" end
  return navigation.plan(mind.memory, from, to)
end

--- The full scoring table for the current state, without deciding anything.
function P.explain(player_name)
  local mind = brain.get(player_name)
  if not mind or not mind.beliefs then return nil, "no_beliefs_yet" end
  local state = {
    hp = mind.memory.last_hp,
    in_liquid = mind.memory.last_in_liquid,
    on_ground = mind.memory.last_on_ground,
  }
  local drives = needs.evaluate(state, mind.memory, mind.beliefs, mind.history)
  local candidates = goals.propose(state, mind.memory, mind.beliefs, mind.history)
  return {
    drives = drives,
    dominant = select(1, needs.dominant(drives)),
    candidates = utility.explain(candidates, drives, mind.memory),
  }
end

-- === Extension ===

--- Teach the bot that a feature is worth walking to, and how much.
-- A future ports module registers its docks here rather than editing goals.lua.
function P.set_feature_interest(feature, weight)
  if type(feature) ~= "string" or type(weight) ~= "number" then return false end
  goals.FEATURE_INTEREST[feature] = math.max(0, math.min(1, weight))
  return true
end

function P.get_feature_interest()
  local out = {}
  for feature, weight in pairs(goals.FEATURE_INTEREST) do
    out[#out + 1] = {feature = feature, weight = canonical.round(weight, 2)}
  end
  table.sort(out, function(a, b) return a.feature < b.feature end)
  return out
end

-- === The runtime channel ===
--
-- The brain publishes intents into a spool and reads back what a real client
-- managed to do with them. It is the only place anything outside the server can
-- tell the bot that a decision did not survive contact with the world.

function P.get_transport_status()
  return P.impl.transport.status()
end

function P.start_transport(actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  return P.impl.transport.start()
end

function P.stop_transport(actor)
  local allowed, reason = bridge.impl.permissions.can_administer(actor)
  if not allowed then return false, "permission_denied", reason end
  return P.impl.transport.stop()
end

--- Report what a real client managed to do with an intent.
-- Exposed for the tests and for any in-process consumer; the external runtime
-- reaches this through the spool rather than through Lua.
function P.report_execution(player_name, document)
  return P.impl.transport.ingest_result(player_name, document)
end

function P.get_last_execution(player_name)
  local mind = brain.get(player_name)
  if not mind then return nil end
  return mind.last_execution
end

P.NULL = canonical.NULL
P.EMPTY_ARRAY = canonical.EMPTY_ARRAY

function P.encode_canonical(value)
  return canonical.encode(value)
end

return P
