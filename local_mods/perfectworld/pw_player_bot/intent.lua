-- pw_player_bot/intent.lua
--
-- What the bot has decided to do, written down so that something else can do it.
--
-- An intent is the output of this mod and the input of a future controller that
-- drives a real Luanti client. It is declarative on purpose: it says "walk to
-- this cell", never "hold the forward key for 400 ms". Keystrokes are the
-- controller's business, and describing them here would tie the brain to one
-- particular way of pressing them.
--
--   pw_bot_bridge     perceives      -- never acts
--   pw_player_bot     decides        -- never acts
--   future controller acts           -- through a real client, like a player

local P = pw_player_bot
local canonical = pw_bot_bridge.impl.canonical
local intent = {}
P.impl.intent = intent

intent.PROTOCOL = "pw_player_bot/v1"
intent.IMPLEMENTATION_VERSION = "0.1.0"

--- The action vocabulary a controller must understand.
--
-- Every one of these is something a human player does with a keyboard, a mouse
-- and their own eyes. Nothing here can be performed server side, which is the
-- property that keeps the boundary honest.
intent.ACTIONS = {
  face = "turn the head to a yaw and pitch",
  walk_to = "walk to a position on foot",
  follow_route = "walk a sequence of positions in order",
  jump_to = "jump up to a position one step higher",
  interact = "right-click a position or an observed object",
  observe = "look around: request a wider or narrower observation",
  wait = "hold still for a number of ticks",
  stop = "do nothing further until the next intent",
}

function intent.is_known_action(name)
  return intent.ACTIONS[name] ~= nil
end

function intent.list_actions()
  local out = {}
  for name in pairs(intent.ACTIONS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local counter = 0

--- Build an intent document.
--
-- `alternatives` carries the goals that lost, with their scores. A bot whose
-- decisions cannot be second-guessed is a bot nobody can debug, and the runner
-- up is usually the most informative thing in the record.
function intent.build(player_name, tick, decision, plan, rationale)
  counter = counter + 1
  local goal = decision.goal or {}
  local alternatives = {}
  for _, candidate in ipairs(decision.alternatives or {}) do
    alternatives[#alternatives + 1] = {
      kind = candidate.kind,
      score = canonical.round(candidate.score or 0),
      reason = candidate.reason or canonical.NULL,
    }
  end

  local steps = {}
  for _, step in ipairs((plan and plan.steps) or {}) do
    steps[#steps + 1] = step
  end

  return {
    protocol = intent.PROTOCOL,
    intent_id = string.format("intent-%s-%d", player_name, counter),
    player_name = player_name,
    issued_tick = tick,
    issued_at = os.time(),
    goal = {
      kind = goal.kind or "stand_still",
      score = canonical.round(goal.score or 0),
      target = goal.target and canonical.node_vector(goal.target) or canonical.NULL,
      feature = goal.feature or canonical.NULL,
      note = goal.note or canonical.NULL,
    },
    alternatives = #alternatives > 0 and alternatives or canonical.EMPTY_ARRAY,
    rationale = canonical.sorted_unique(rationale or {}),
    plan = {
      kind = (plan and plan.kind) or "none",
      route = (plan and plan.route and #plan.route > 0) and plan.route or canonical.EMPTY_ARRAY,
      route_length = (plan and plan.route and #plan.route) or 0,
      steps = #steps > 0 and steps or canonical.EMPTY_ARRAY,
      reason = (plan and plan.reason) or canonical.NULL,
    },
    constraints = {
      max_step_up = (plan and plan.max_step_up) or 1,
      max_step_down = (plan and plan.max_step_down) or 3,
      avoid = canonical.sorted_unique((plan and plan.avoid) or {"hazard", "lava"}),
      route_is_belief_only = true,
    },
    expires_after_ticks = decision.ttl or 10,
    executed_by = "a future pw_player_bot runtime driving a real Luanti client; "
      .. "neither pw_player_bot nor pw_bot_bridge performs any action",
  }
end

--- The empty intent. Issued when the bot has decided to do nothing, which is a
--- decision and deserves a record like any other.
function intent.idle(player_name, tick, reason)
  return intent.build(player_name, tick,
    {goal = {kind = "stand_still", score = 0, note = reason}, ttl = 1},
    {kind = "none", steps = {{action = "stop"}}, reason = reason},
    {reason})
end

-- === Step constructors ===

function intent.step_face(yaw, pitch)
  return {
    action = "face",
    yaw = canonical.round(yaw or 0),
    pitch = canonical.round(pitch or 0),
  }
end

function intent.step_walk_to(position)
  return {action = "walk_to", position = canonical.node_vector(position)}
end

function intent.step_follow_route(route)
  local out = {}
  for _, cell in ipairs(route or {}) do
    out[#out + 1] = canonical.node_vector(cell)
  end
  return {
    action = "follow_route",
    route = #out > 0 and out or canonical.EMPTY_ARRAY,
    length = #out,
  }
end

function intent.step_observe(profile)
  return {action = "observe", profile = profile or "navigation"}
end

function intent.step_wait(ticks)
  return {action = "wait", ticks = math.floor(ticks or 1)}
end

function intent.step_stop()
  return {action = "stop"}
end

--- Yaw that faces `to` from `from`, in Luanti's convention: yaw 0 looks along
--- +Z and grows anticlockwise.
function intent.yaw_towards(from, to)
  local dx = to.x - from.x
  local dz = to.z - from.z
  if math.abs(dx) < 1e-9 and math.abs(dz) < 1e-9 then return 0 end
  local yaw = math.atan2(-dx, dz)
  if yaw < 0 then yaw = yaw + 2 * math.pi end
  return yaw
end

--- Reject anything that is not a well-formed intent. Used by the tests and by
--- any future controller that would rather fail loudly than act on nonsense.
function intent.validate(document)
  if type(document) ~= "table" then return false, "not_a_table" end
  if document.protocol ~= intent.PROTOCOL then return false, "wrong_protocol" end
  if type(document.intent_id) ~= "string" or document.intent_id == "" then
    return false, "missing_intent_id"
  end
  if type(document.goal) ~= "table" or type(document.goal.kind) ~= "string" then
    return false, "missing_goal"
  end
  if type(document.plan) ~= "table" then return false, "missing_plan" end
  for _, step in ipairs(document.plan.steps == canonical.EMPTY_ARRAY and {} or document.plan.steps) do
    if not intent.is_known_action(step.action) then
      return false, "unknown_action:" .. tostring(step.action)
    end
  end
  return true
end

return intent
