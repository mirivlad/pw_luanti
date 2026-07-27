-- pw_player_bot/utility.lua
--
-- Which of the possible things is the right thing.
--
-- Every candidate is scored as need satisfaction, scaled by how good this
-- particular instance is and how much it costs to reach. No goal has an
-- intrinsic priority: a door outranks a frontier only when interest outranks
-- curiosity, which is a statement about the bot's condition rather than about
-- doors.
--
-- Scoring is deterministic. Ties break on a hash of the candidate's identity —
-- through `perfectworld.core.choice`, the project's exact 32-bit hashing, never
-- `math.random` — so the same beliefs always produce the same decision, and a
-- test can assert that.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local goals = P.impl.goals
local needs = P.impl.needs
local utility = {}
P.impl.utility = utility

--- How strongly each goal answers each drive.
--
-- A row that is all zeros is a goal that never wins, which is correct for
-- standing still: it is the floor, chosen when nothing else scores above it.
utility.WEIGHTS = {
  stand_still = {},
  look_around = {orientation = 0.9, recovery = 0.4, curiosity = 0.25},
  explore_frontier = {curiosity = 1.0, orientation = 0.5},
  approach_feature = {interest = 1.0, curiosity = 0.2},
  retreat_from_hazard = {safety = 1.0},
  leave_liquid = {safety = 0.95},
  unstick = {recovery = 1.0},
}

--- The floor a candidate must clear to beat doing nothing.
utility.IDLE_SCORE = 0.05

--- Distance at which walking somewhere stops being worth it on its own.
utility.DISTANCE_HALF_LIFE = 24

local function clamp01(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

--- Value that decays with distance rather than being cut off at a threshold.
-- A cliff produces a bot that ignores an interesting thing 25 blocks away and
-- sprints to one 24 blocks away; a curve produces one that prefers near things
-- without being blind to far ones.
local function distance_factor(distance)
  if not distance or distance <= 0 then return 1 end
  return 1 / (1 + distance / utility.DISTANCE_HALF_LIFE)
end

utility.distance_factor = distance_factor

--- Everything about a candidate other than which drive it serves.
-- Returns a multiplier in [0, 1.2] and the reasons that produced it.
local function quality(candidate, memo)
  local factor = 1
  local why = {}

  if candidate.distance then
    local decay = distance_factor(candidate.distance)
    factor = factor * decay
    why[#why + 1] = string.format("distance=%.1f", candidate.distance)
  end

  if candidate.kind == "explore_frontier" then
    -- More unknown neighbours means more is learned by standing there. Eight is
    -- the maximum, and a cell with eight is surrounded by nothing at all.
    local unknown = candidate.unknown_neighbours or 1
    factor = factor * (0.6 + 0.4 * math.min(unknown, 8) / 8)
    why[#why + 1] = "unknown_neighbours=" .. unknown
    if candidate.already_visited then
      -- Standing somewhere again teaches less than standing somewhere new.
      factor = factor * 0.6
      why[#why + 1] = "already_visited"
    end
  end

  if candidate.kind == "approach_feature" then
    local interest = goals.FEATURE_INTEREST[candidate.feature] or 0.25
    factor = factor * interest
    why[#why + 1] = "feature=" .. tostring(candidate.feature)
    if candidate.stale then
      -- It was there a long time ago. Worth checking, worth less than something
      -- seen a moment ago.
      factor = factor * 0.7
      why[#why + 1] = "stale"
    end
  end

  if candidate.kind == "look_around" then
    -- Looking is cheap and always possible, which would make it win constantly
    -- if it were not held down. It earns its keep only through orientation.
    factor = factor * 0.8
  end

  return factor, why
end

utility.quality = quality

--- Score one candidate against the current drives.
function utility.score_candidate(candidate, drives, memo)
  local weights = utility.WEIGHTS[candidate.kind] or {}
  local base = 0
  local contributions = {}
  for _, name in ipairs(needs.NAMES) do
    local weight = weights[name]
    if weight and weight > 0 then
      local drive = drives[name] or 0
      if drive > 0 then
        base = base + weight * drive
        contributions[#contributions + 1] = string.format("%s=%.2f*%.2f", name, drive, weight)
      end
    end
  end

  local factor, why = quality(candidate, memo)
  local score = clamp01(base * factor)

  for _, reason in ipairs(why) do
    contributions[#contributions + 1] = reason
  end
  table.sort(contributions)
  return canonical.round(score), contributions
end

--- A stable identity for a candidate, used for deterministic tie-breaking.
local function candidate_label(candidate)
  local parts = {candidate.kind}
  if candidate.feature then parts[#parts + 1] = tostring(candidate.feature) end
  if candidate.target then
    parts[#parts + 1] = table.concat({
      math.floor(candidate.target.x or 0),
      math.floor(candidate.target.y or 0),
      math.floor(candidate.target.z or 0),
    }, ":")
  end
  return table.concat(parts, "|")
end

utility.candidate_label = candidate_label

--- Choose. Returns the winner, the ranked alternatives, and why.
--
-- The tie-break deserves a word. Equal scores are common — two frontier cells at
-- the same distance with the same unknown count are genuinely equivalent — and
-- picking by table order would make the choice depend on Lua's hash walk. A
-- hash of the label plus the memory tick breaks the tie the same way every time
-- for the same state, and differently across ticks, so the bot does not lock
-- onto one of two equal options forever.
function utility.choose(candidates, drives, memo)
  local scored = {}
  for _, candidate in ipairs(candidates) do
    local score, reasons = utility.score_candidate(candidate, drives, memo)
    local label = candidate_label(candidate)
    scored[#scored + 1] = {
      candidate = candidate,
      kind = candidate.kind,
      label = label,
      score = score,
      reasons = reasons,
      tiebreak = perfectworld.core.choice.unit(
        "pw_player_bot:" .. tostring(memo.player_name), label .. "#" .. tostring(memo.tick)),
    }
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.tiebreak ~= b.tiebreak then return a.tiebreak > b.tiebreak end
    return a.label < b.label
  end)

  local winner = scored[1]
  local alternatives = {}
  for index = 2, math.min(#scored, 5) do
    alternatives[#alternatives + 1] = {
      kind = scored[index].kind,
      score = scored[index].score,
      reason = table.concat(scored[index].reasons, " "),
    }
  end

  return winner, alternatives, scored
end

--- Everything the scorer knows, for a diagnostic dump.
function utility.explain(candidates, drives, memo)
  local _, _, scored = utility.choose(candidates, drives, memo)
  local out = {}
  for _, entry in ipairs(scored) do
    out[#out + 1] = {
      kind = entry.kind,
      label = entry.label,
      score = entry.score,
      reasons = entry.reasons,
    }
  end
  return out
end

return utility
