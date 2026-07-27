-- pw_player_bot/goals.lua
--
-- The things the bot can want, and how each of them is turned into a plan.
--
-- A goal is a candidate, not a command. It knows which needs it would satisfy,
-- how to propose concrete instances of itself from the current beliefs, and how
-- to build a plan once chosen. What it does not know is whether it is the right
-- thing to do — that is the utility layer's job, and keeping the two apart is
-- what lets a new goal be added without re-tuning every existing one.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = P.impl.memory
local beliefs = P.impl.beliefs
local navigation = P.impl.navigation
local intent = P.impl.intent
local goals = {}
P.impl.goals = goals

-- Features worth walking over to look at, in the order a curious walker would
-- rank them. Doors and roads are how a settlement is understood; water is
-- mostly a thing to note and stay out of.
local FEATURE_INTEREST = {
  structure_entrance = 1.0,
  door = 0.95,
  boat = 0.8,
  road_surface = 0.6,
  path_surface = 0.55,
  ladder = 0.5,
  container = 0.5,
  gate = 0.45,
  stair = 0.35,
  farmland = 0.3,
  fence = 0.2,
  water = 0.15,
}

goals.FEATURE_INTEREST = FEATURE_INTEREST

--- Every goal kind this version knows, with the drives it answers.
goals.KINDS = {
  stand_still = {satisfies = {}, description = "hold position and do nothing"},
  look_around = {satisfies = {"orientation", "recovery"},
    description = "turn the head to widen the observed sector"},
  explore_frontier = {satisfies = {"curiosity", "orientation"},
    description = "walk to the edge of what is known"},
  approach_feature = {satisfies = {"interest"},
    description = "walk to something recognised and not yet visited"},
  retreat_from_hazard = {satisfies = {"safety"},
    description = "walk away from something that can hurt"},
  leave_liquid = {satisfies = {"safety"},
    description = "get back onto dry ground"},
  unstick = {satisfies = {"recovery"},
    description = "abandon the current approach and look somewhere else"},
}

function goals.list_kinds()
  local out = {}
  for kind in pairs(goals.KINDS) do out[#out + 1] = kind end
  table.sort(out)
  return out
end

-- === Candidate generation ===
--
-- Each generator proposes concrete instances from beliefs. None of them scores
-- anything; they only say what is possible.

local function candidate(kind, fields)
  local out = {kind = kind}
  for key, value in pairs(fields or {}) do out[key] = value end
  return out
end

--- Somewhere dry and safe, as far from a hazard as memory allows.
local function safe_retreat_target(memo, model, origin, away_from)
  local best, best_score = nil, -math.huge
  for _, cell in pairs(memo.cells) do
    if beliefs.is_traversable(cell) then
      local dx, dz = cell.x - away_from.x, cell.z - away_from.z
      local from_hazard = math.sqrt(dx * dx + dz * dz)
      local ox, oz = cell.x - origin.x, cell.z - origin.z
      local from_here = math.sqrt(ox * ox + oz * oz)
      -- Far from the danger, near enough to reach.
      local score = from_hazard - from_here * 0.5
      if from_hazard >= 6 and score > best_score then
        best, best_score = cell, score
      end
    end
  end
  if not best then return nil end
  return {x = best.x, y = best.ground_y + 1, z = best.z}
end

--- Propose every goal that the current beliefs make possible.
function goals.propose(state, memo, model, history)
  local out = {}
  local origin = memo.last_position

  -- Always available, and always last: doing nothing is a legitimate answer.
  out[#out + 1] = candidate("stand_still", {note = "no better option"})

  -- Looking around costs nothing and is the right move when memory is thin.
  out[#out + 1] = candidate("look_around", {note = "widen the observed sector"})

  if not origin then
    return out
  end

  if state.in_liquid then
    local target = safe_retreat_target(memo, model, origin, origin)
    if target then
      out[#out + 1] = candidate("leave_liquid", {target = target})
    end
  end

  local hazard, hazard_distance = beliefs.nearest_hazard(model, origin, 8)
  if hazard then
    local target = safe_retreat_target(memo, model, origin, hazard)
    if target then
      out[#out + 1] = candidate("retreat_from_hazard", {
        target = target,
        note = "hazard at " .. hazard_distance,
      })
    end
  end

  for _, cell in ipairs(beliefs.frontier_targets(model)) do
    out[#out + 1] = candidate("explore_frontier", {
      target = {x = cell.x, y = cell.ground_y + 1, z = cell.z},
      unknown_neighbours = cell.unknown_neighbours,
      distance = cell.distance,
      already_visited = cell.visited,
    })
  end

  local seen_features = 0
  for _, entry in ipairs(memory.features_of(memo, nil, origin)) do
    if not entry.visited and FEATURE_INTEREST[entry.feature] and seen_features < 8 then
      seen_features = seen_features + 1
      out[#out + 1] = candidate("approach_feature", {
        target = entry.position,
        feature = entry.feature,
        feature_key = entry.key,
        distance = entry.distance,
        stale = entry.stale,
      })
    end
  end

  if (history and (history.stuck_ticks or 0) >= 2) then
    out[#out + 1] = candidate("unstick", {note = "the last plan did not move me"})
  end

  -- Bounded: however much the bot remembers, one tick scores a fixed number of
  -- options.
  local capped = {}
  for index = 1, math.min(#out, settings.HARD.max_candidates) do
    capped[index] = out[index]
  end
  return capped
end

-- === Plan construction ===
--
-- Only the chosen goal is planned, because planning is the expensive half and
-- scoring already told us which one is worth it.

local function route_plan(memo, origin, target, avoid)
  local route, reason, info = navigation.plan(memo, origin, target)
  if not route then
    return nil, reason, info
  end
  local simplified = navigation.simplify(route)
  return {
    kind = "route",
    route = simplified,
    steps = navigation.route_to_steps(simplified, origin),
    max_step_up = settings.route_max_step_up,
    max_step_down = settings.route_max_step_down,
    avoid = avoid or {"hazard", "lava", "water"},
    reason = "planned over remembered cells only",
  }, nil, info
end

--- Build the plan for a chosen goal. Returns plan, reason.
function goals.plan(kind, chosen, state, memo, model)
  local origin = memo.last_position

  if kind == "stand_still" then
    return {
      kind = "none",
      steps = {intent.step_stop()},
      reason = chosen.note or "nothing worth doing",
    }
  end

  if kind == "look_around" then
    -- Turning the head is an action, so it is a step for the controller, not
    -- something this mod performs. Four quarters and a fresh observation.
    local yaw = (memo.last_yaw or 0) + math.pi / 2
    return {
      kind = "look",
      steps = {
        intent.step_face(yaw, 0),
        intent.step_observe(settings.observation_profile),
        intent.step_wait(1),
      },
      reason = "widen the observed sector without moving",
    }
  end

  if kind == "unstick" then
    local yaw = (memo.last_yaw or 0) + math.pi
    return {
      kind = "look",
      steps = {
        intent.step_face(yaw, 0),
        intent.step_observe("detailed"),
      },
      reason = "the last plan did not move me; look the other way",
    }
  end

  if not origin then
    return nil, "position_unknown"
  end

  if kind == "approach_feature" then
    -- A door is not somewhere to stand. Route to the cell beside it.
    local stand_at = navigation.approach_cell(memo, chosen.target)
    if not stand_at then
      return nil, "no_remembered_approach"
    end
    local plan, reason, info = route_plan(memo, origin, stand_at)
    if not plan then return nil, reason, info end
    -- Once there, face the thing that was worth walking to.
    plan.steps[#plan.steps + 1] = intent.step_face(
      intent.yaw_towards(stand_at, chosen.target), 0)
    plan.steps[#plan.steps + 1] = intent.step_observe("detailed")
    plan.reason = "approach " .. tostring(chosen.feature) .. " over remembered cells"
    return plan, nil, info
  end

  if kind == "explore_frontier" or kind == "retreat_from_hazard" or kind == "leave_liquid" then
    local plan, reason, info = route_plan(memo, origin, chosen.target)
    if not plan then return nil, reason, info end
    if kind == "explore_frontier" then
      -- Arriving at the frontier is only half of it; the point was to look.
      plan.steps[#plan.steps + 1] = intent.step_observe(settings.observation_profile)
      plan.reason = "walk to the edge of what is known and look"
    elseif kind == "leave_liquid" then
      plan.avoid = {"hazard", "lava"}
      plan.reason = "get back onto dry ground"
    else
      plan.reason = "put distance between me and the hazard"
    end
    return plan, nil, info
  end

  return nil, "unknown_goal_kind"
end

function goals.describe(kind)
  local entry = goals.KINDS[kind]
  if not entry then return canonical.NULL end
  return entry.description
end

return goals
