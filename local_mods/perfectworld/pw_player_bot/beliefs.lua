-- pw_player_bot/beliefs.lua
--
-- What the bot thinks is true, derived from what it remembers.
--
-- Memory is a pile of observations; beliefs are the shape that pile has. The
-- separation matters because beliefs are cheap to throw away and rebuild, while
-- memory is expensive and must not be corrupted by a bad inference.
--
-- The most important derived thing here is the **frontier**: remembered columns
-- that border on nothing at all. A frontier cell is the bot's own statement
-- that it does not know what is over there, and it is the only honest source of
-- somewhere to go next. A bot that picked exploration targets from the map
-- would not be exploring.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = P.impl.memory
local beliefs = {}
P.impl.beliefs = beliefs

local NEIGHBOURS = {
  {1, 0}, {-1, 0}, {0, 1}, {0, -1},
  {1, 1}, {1, -1}, {-1, 1}, {-1, -1},
}

beliefs.NEIGHBOURS = NEIGHBOURS

--- Can a body stand in this remembered column?
function beliefs.is_standable(cell)
  if not cell then return false end
  if not cell.walkable then return false end
  if cell.blocked_above then return false end
  if (cell.head_clearance or 0) < 2 then return false end
  return true
end

--- Would a walker accept this column on a route?
-- Water and hazards are traversable in principle and refused here: this bot has
-- no reason to wade and every reason not to burn.
function beliefs.is_traversable(cell)
  if not beliefs.is_standable(cell) then return false end
  if cell.hazard then return false end
  if cell.water then return false end
  return true
end

--- Can a walker get from one remembered column to the next?
function beliefs.can_step(from, to)
  if not from or not to then return false end
  if not beliefs.is_traversable(to) then return false end
  local climb = to.ground_y - from.ground_y
  if climb > settings.route_max_step_up then return false end
  if -climb > settings.route_max_step_down then return false end
  return true
end

--- Rebuild the derived model.
--
-- One pass over remembered columns produces everything downstream needs: which
-- cells are usable, where the edges of knowledge are, and where the things the
-- bot cares about sit. Rebuilding is cheap enough to do every tick, which means
-- beliefs can never drift out of step with memory.
function beliefs.rebuild(memo)
  local model = {
    tick = memo.tick,
    traversable = 0,
    standable = 0,
    known = memo.cell_count,
    frontier = {},
    frontier_count = 0,
    hazards = {},
    water_cells = 0,
    origin = memo.last_position,
  }

  for key, cell in pairs(memo.cells) do
    if beliefs.is_standable(cell) then
      model.standable = model.standable + 1
    end
    if cell.water then model.water_cells = model.water_cells + 1 end
    if cell.hazard then
      model.hazards[#model.hazards + 1] = {x = cell.x, z = cell.z, ground_y = cell.ground_y}
    end
    if beliefs.is_traversable(cell) then
      model.traversable = model.traversable + 1
      -- A frontier cell is one the bot can stand in that touches somewhere it
      -- has never seen. That is the edge of its knowledge, and the only place
      -- worth going to enlarge it.
      local unknown_neighbours = 0
      for _, offset in ipairs(NEIGHBOURS) do
        if not memo.cells[memory.cell_key(cell.x + offset[1], cell.z + offset[2])] then
          unknown_neighbours = unknown_neighbours + 1
        end
      end
      if unknown_neighbours > 0 then
        model.frontier[#model.frontier + 1] = {
          key = key,
          x = cell.x,
          z = cell.z,
          ground_y = cell.ground_y,
          unknown_neighbours = unknown_neighbours,
          visited = memo.visited[key] ~= nil,
          last_seen_tick = cell.last_seen_tick,
        }
      end
    end
  end
  model.frontier_count = #model.frontier

  -- Sorted so the same memory always proposes the same targets in the same
  -- order: most unknown first, then nearest, then by key. Without the final key
  -- the order would depend on the hash walk above.
  local origin = model.origin or {x = 0, z = 0}
  for _, cell in ipairs(model.frontier) do
    local dx, dz = cell.x - origin.x, cell.z - origin.z
    cell.distance = canonical.round(math.sqrt(dx * dx + dz * dz))
  end
  table.sort(model.frontier, function(a, b)
    if a.unknown_neighbours ~= b.unknown_neighbours then
      return a.unknown_neighbours > b.unknown_neighbours
    end
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.key < b.key
  end)

  table.sort(model.hazards, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.z < b.z
  end)

  return model
end

--- The nearest hazard the bot remembers, if any is close enough to matter.
function beliefs.nearest_hazard(model, origin, radius)
  if not origin then return nil end
  local best, best_distance = nil, math.huge
  for _, hazard in ipairs(model.hazards) do
    local dx, dz = hazard.x - origin.x, hazard.z - origin.z
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < best_distance and distance <= (radius or 8) then
      best, best_distance = hazard, distance
    end
  end
  if not best then return nil end
  return best, canonical.round(best_distance)
end

--- How much of what the bot can reach has it actually stood in?
-- A crude but honest measure of how well explored the neighbourhood is, and the
-- thing curiosity is scored against.
function beliefs.exploration_ratio(memo, model)
  if model.traversable == 0 then return 0 end
  local visited_traversable = 0
  for key in pairs(memo.visited) do
    local cell = memo.cells[key]
    if cell and beliefs.is_traversable(cell) then
      visited_traversable = visited_traversable + 1
    end
  end
  return math.min(1, visited_traversable / model.traversable)
end

--- Frontier targets worth considering this tick, capped so the utility pass
--- stays bounded however large memory grows.
function beliefs.frontier_targets(model, limit)
  limit = math.min(limit or settings.HARD.max_frontier_targets,
    settings.HARD.max_frontier_targets)
  local out = {}
  for index = 1, math.min(#model.frontier, limit) do
    out[#out + 1] = model.frontier[index]
  end
  return out
end

function beliefs.summary(model)
  return {
    tick = model.tick,
    known_cells = model.known,
    standable_cells = model.standable,
    traversable_cells = model.traversable,
    water_cells = model.water_cells,
    hazard_cells = #model.hazards,
    frontier_cells = model.frontier_count,
  }
end

return beliefs
