-- pw_player_bot/needs.lua
--
-- What the bot currently lacks, on a scale of nothing to urgent.
--
-- Needs are the only place where the bot's condition is turned into pressure.
-- Goals do not decide their own importance; they are scored against these, which
-- is what stops "walk to that door" from outranking "get out of the fire".
--
-- Every need is a number in [0, 1] with a stated reason. The reason is not
-- decoration: an intent that says `curiosity=0.82` is debuggable, and one that
-- says `score=0.71` is not.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local beliefs = P.impl.beliefs
local needs = {}
P.impl.needs = needs

needs.NAMES = {
  "safety",       -- something here can hurt
  "recovery",     -- the last plan is not working
  "orientation",  -- too little is known to act sensibly
  "curiosity",    -- there is an edge of knowledge worth pushing
  "interest",     -- something recognised has not been looked at yet
}

local function clamp(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

needs.clamp = clamp

--- Evaluate every drive from the current state, memory and beliefs.
function needs.evaluate(state, memo, model, history)
  local out = {}
  local why = {}

  -- Safety. Standing in a liquid, standing on something that hurts, or losing
  -- health all raise it, and it outranks everything by construction.
  local safety = 0
  if state.in_liquid then
    safety = math.max(safety, 0.6)
    why[#why + 1] = "in_liquid"
  end
  local hp = tonumber(state.hp) or 20
  if hp < 20 then
    safety = math.max(safety, clamp((20 - hp) / 20 + 0.2))
    why[#why + 1] = "hp=" .. hp
  end
  if history and history.last_hp and hp < history.last_hp then
    safety = math.max(safety, 0.85)
    why[#why + 1] = "hp_falling"
  end
  local hazard, hazard_distance = beliefs.nearest_hazard(model, memo.last_position, 6)
  if hazard then
    safety = math.max(safety, clamp(1 - (hazard_distance or 6) / 6))
    why[#why + 1] = "hazard_at=" .. hazard_distance
  end
  if not state.on_ground and not state.in_liquid then
    -- Falling is not an emergency by itself, but it is not a moment to start
    -- walking somewhere either.
    safety = math.max(safety, 0.3)
    why[#why + 1] = "not_on_ground"
  end
  out.safety = clamp(safety)

  -- Recovery. The bot has been asked to move and has not moved. Something in
  -- the plan is wrong, and repeating it will not fix it.
  local recovery = 0
  if history then
    local stuck = history.stuck_ticks or 0
    if stuck > 0 then
      recovery = clamp(stuck / 5)
      why[#why + 1] = "stuck_ticks=" .. stuck
    end
    if (history.failed_routes or 0) > 0 then
      recovery = math.max(recovery, clamp((history.failed_routes or 0) / 4))
      why[#why + 1] = "failed_routes=" .. history.failed_routes
    end
  end
  out.recovery = clamp(recovery)

  -- Orientation. With almost nothing remembered, the useful thing to do is look
  -- around rather than set off somewhere.
  local traversable = model.traversable or 0
  local orientation = clamp(1 - traversable / 24)
  if orientation > 0 then
    why[#why + 1] = "traversable_known=" .. traversable
  end
  out.orientation = orientation

  -- Curiosity. Scaled by how much of the reachable neighbourhood remains
  -- unvisited, and gated on there actually being a frontier to push. It tops out
  -- below safety on purpose: wanting to see what is over there should never be
  -- able to outbid not catching fire.
  local curiosity = 0
  if (model.frontier_count or 0) > 0 then
    local explored = beliefs.exploration_ratio(memo, model)
    curiosity = clamp(0.25 + (1 - explored) * 0.45)
    why[#why + 1] = "frontier=" .. model.frontier_count
  end
  out.curiosity = curiosity

  -- Interest. Something recognised and not yet approached.
  local interest = 0
  local unvisited = 0
  for _, entry in pairs(memo.features) do
    if not entry.visited then unvisited = unvisited + 1 end
  end
  if unvisited > 0 then
    interest = clamp(0.2 + math.min(unvisited, 8) / 20)
    why[#why + 1] = "unvisited_features=" .. unvisited
  end
  out.interest = interest

  -- Fear crowds everything else out.
  --
  -- Safety is not just another drive competing on equal terms; past a threshold
  -- it changes what the bot is capable of caring about. Without this a bot on
  -- six health beside a lava flow can still be talked into sightseeing by a
  -- sufficiently interesting doorway, which is not a bot anybody would believe.
  if out.safety > needs.FEAR_THRESHOLD then
    local suppression = 1 - out.safety
    for _, name in ipairs({"curiosity", "interest", "orientation"}) do
      out[name] = clamp((out[name] or 0) * suppression)
    end
    why[#why + 1] = string.format("fear_suppresses_others=%.2f", suppression)
  end

  local rounded = {}
  for _, name in ipairs(needs.NAMES) do
    rounded[name] = canonical.round(out[name] or 0)
  end
  table.sort(why)
  return rounded, why
end

--- Above this, safety starts suppressing every drive that is not about survival.
needs.FEAR_THRESHOLD = 0.5

--- The strongest drive, for a one-line summary.
function needs.dominant(values)
  local best, best_value = "none", -1
  for _, name in ipairs(needs.NAMES) do
    local value = values[name] or 0
    if value > best_value then best, best_value = name, value end
  end
  return best, best_value
end

--- Track the things a single observation cannot show: whether the bot moved,
--- whether its health is falling, how often planning has failed lately.
function needs.update_history(history, state, memo)
  history = history or {stuck_ticks = 0, failed_routes = 0}
  local position = memo.last_position
  if history.last_position and position then
    local moved = math.abs(position.x - history.last_position.x)
      + math.abs(position.y - history.last_position.y)
      + math.abs(position.z - history.last_position.z)
    if moved < 1 and history.expected_movement then
      history.stuck_ticks = math.min((history.stuck_ticks or 0) + 1, 10)
    else
      history.stuck_ticks = 0
    end
  end
  history.last_position = position and {x = position.x, y = position.y, z = position.z} or nil
  history.last_hp = tonumber(state.hp) or history.last_hp
  return history
end

function needs.note_route_failure(history)
  history.failed_routes = math.min((history.failed_routes or 0) + 1, 8)
  return history
end

function needs.note_route_success(history)
  history.failed_routes = 0
  return history
end

return needs
