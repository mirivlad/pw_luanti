-- pw_player_bot/navigation.lua
--
-- Routing over what the bot remembers, and only over that.
--
-- This is the single most important constraint in the module. The planner never
-- reads the map. It expands remembered columns, and a column the bot has not
-- observed simply does not exist to it — so a route can only ever go where the
-- bot has already looked. That is what makes the bot's competence its own
-- rather than the server's, and it is why "walk somewhere you have not seen" is
-- not a plan the bot can make: it has to go and look first, which is exactly
-- what exploration is for.
--
-- A* over an eight-connected grid of surface columns, bounded in expansions and
-- in the length of what it will return.

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local memory = P.impl.memory
local beliefs = P.impl.beliefs
local navigation = {}
P.impl.navigation = navigation

local SQRT2 = math.sqrt(2)

--- Octile distance: the exact cost of the cheapest unobstructed path on an
--- eight-connected grid, so the heuristic is admissible and A* stays optimal.
local function heuristic(ax, az, bx, bz)
  local dx = math.abs(ax - bx)
  local dz = math.abs(az - bz)
  local straight = math.max(dx, dz) - math.min(dx, dz)
  return straight + SQRT2 * math.min(dx, dz)
end

navigation.heuristic = heuristic

--- Cost of stepping between two adjacent remembered columns.
local function step_cost(from, to, diagonal)
  local cost = diagonal and SQRT2 or 1
  local climb = to.ground_y - from.ground_y
  if climb > 0 then
    -- Climbing is slower than walking, and a bot that ignores that will keep
    -- choosing staircases over the flat road beside them.
    cost = cost + climb * 0.8
  elseif climb < 0 then
    cost = cost + (-climb) * 0.2
  end
  -- Prefer what the bot is sure about. A route across half-glimpsed ground is
  -- a route that will need replanning.
  cost = cost + (1 - (to.confidence or 0.5)) * 0.5
  -- Roads exist to be walked on.
  if memory.has_tag(to.semantics, "road_surface")
    or memory.has_tag(to.semantics, "path_surface") then
    cost = cost * 0.7
  end
  return cost
end

navigation.step_cost = step_cost

-- A binary min-heap. A linear scan for the cheapest open node would make the
-- planner quadratic, which shows up as a stutter long before the expansion cap
-- does.
local function heap_push(heap, item)
  heap[#heap + 1] = item
  local index = #heap
  while index > 1 do
    local parent = math.floor(index / 2)
    if heap[parent].f <= heap[index].f then break end
    heap[parent], heap[index] = heap[index], heap[parent]
    index = parent
  end
end

local function heap_pop(heap)
  local size = #heap
  if size == 0 then return nil end
  local top = heap[1]
  heap[1] = heap[size]
  heap[size] = nil
  size = size - 1
  local index = 1
  while true do
    local left, right = index * 2, index * 2 + 1
    local smallest = index
    if left <= size and heap[left].f < heap[smallest].f then smallest = left end
    if right <= size and heap[right].f < heap[smallest].f then smallest = right end
    if smallest == index then break end
    heap[index], heap[smallest] = heap[smallest], heap[index]
    index = smallest
  end
  return top
end

--- Plan a route from one remembered column to another.
--
-- Returns a route (array of {x, y, z}) or nil plus a reason. The reasons are
-- deliberately specific: "the goal is not somewhere I have been able to look"
-- and "I know that place and cannot get there" lead to completely different
-- decisions upstream.
function navigation.plan(memo, from, to, options)
  options = options or {}
  local max_expansions = math.min(options.max_expansions or settings.route_max_expansions,
    settings.route_max_expansions)
  local max_length = math.min(options.max_length or settings.route_max_length,
    settings.route_max_length)

  local start_cell = memory.get_cell(memo, from.x, from.z)
  local goal_cell = memory.get_cell(memo, to.x, to.z)

  if not start_cell then return nil, "start_not_remembered" end
  if not goal_cell then return nil, "goal_not_remembered" end
  if not beliefs.is_traversable(goal_cell) then return nil, "goal_not_traversable" end

  local start_key = memory.cell_key(from.x, from.z)
  local goal_key = memory.cell_key(to.x, to.z)
  if start_key == goal_key then
    return {{x = start_cell.x, y = start_cell.ground_y + 1, z = start_cell.z}}, nil, {expansions = 0}
  end

  local open = {}
  local best_g = {[start_key] = 0}
  local came_from = {}
  local closed = {}
  local expansions = 0

  heap_push(open, {
    key = start_key, x = start_cell.x, z = start_cell.z,
    g = 0, f = heuristic(start_cell.x, start_cell.z, goal_cell.x, goal_cell.z),
  })

  while true do
    local current = heap_pop(open)
    if not current then
      return nil, "no_route", {expansions = expansions}
    end
    if current.key == goal_key then
      -- Walk the parent chain back and reverse it.
      local reversed = {}
      local key = goal_key
      while key do
        local cell = memo.cells[key]
        if not cell then break end
        reversed[#reversed + 1] = {x = cell.x, y = cell.ground_y + 1, z = cell.z}
        key = came_from[key]
        if #reversed > max_length + 1 then
          return nil, "route_too_long", {expansions = expansions}
        end
      end
      local route = {}
      for index = #reversed, 1, -1 do route[#route + 1] = reversed[index] end
      return route, nil, {expansions = expansions, cost = canonical.round(current.g)}
    end

    if not closed[current.key] then
      closed[current.key] = true
      expansions = expansions + 1
      if expansions > max_expansions then
        return nil, "expansion_limit", {expansions = expansions}
      end

      local cell = memo.cells[current.key]
      for _, offset in ipairs(beliefs.NEIGHBOURS) do
        local nx, nz = cell.x + offset[1], cell.z + offset[2]
        local neighbour_key = memory.cell_key(nx, nz)
        if not closed[neighbour_key] then
          local neighbour = memo.cells[neighbour_key]
          -- An unremembered column is not an obstacle; it is simply not part of
          -- the graph. The bot cannot route through what it has not seen.
          if neighbour and beliefs.can_step(cell, neighbour) then
            local diagonal = offset[1] ~= 0 and offset[2] ~= 0
            -- Refuse to cut a diagonal corner between two cells the bot cannot
            -- walk through: a real body does not fit through that gap.
            local passable = true
            if diagonal then
              local side_a = memo.cells[memory.cell_key(cell.x + offset[1], cell.z)]
              local side_b = memo.cells[memory.cell_key(cell.x, cell.z + offset[2])]
              passable = beliefs.can_step(cell, side_a) or beliefs.can_step(cell, side_b)
            end
            if passable then
              local tentative = current.g + step_cost(cell, neighbour, diagonal)
              if tentative < (best_g[neighbour_key] or math.huge) then
                best_g[neighbour_key] = tentative
                came_from[neighbour_key] = current.key
                heap_push(open, {
                  key = neighbour_key, x = nx, z = nz,
                  g = tentative,
                  f = tentative + heuristic(nx, nz, goal_cell.x, goal_cell.z),
                })
              end
            end
          end
        end
      end
    end
  end
end

--- Turn a route into the steps a controller executes.
--
-- The first step always faces the way the bot is about to walk. A controller
-- that walks before it turns walks into a wall, and asking it to infer the turn
-- would put a decision back into the layer that is supposed to have none.
function navigation.route_to_steps(route, from)
  local intent = P.impl.intent
  local steps = {}
  if not route or #route == 0 then
    steps[#steps + 1] = intent.step_stop()
    return steps
  end
  local first = route[1]
  local next_cell = route[2] or first
  if from then
    steps[#steps + 1] = intent.step_face(intent.yaw_towards(from, next_cell), 0)
  end
  steps[#steps + 1] = intent.step_follow_route(route)
  return steps
end

--- Simplify a route by dropping cells that lie on a straight run.
-- The controller walks between waypoints; a waypoint every single cell tells it
-- nothing extra and makes an intent three times larger than it needs to be.
function navigation.simplify(route)
  if not route or #route <= 2 then return route end
  local out = {route[1]}
  for index = 2, #route - 1 do
    local previous, current, following = route[index - 1], route[index], route[index + 1]
    local dx1, dz1 = current.x - previous.x, current.z - previous.z
    local dx2, dz2 = following.x - current.x, following.z - current.z
    local turned = (dx1 ~= dx2) or (dz1 ~= dz2)
    local climbed = current.y ~= previous.y
    if turned or climbed then
      out[#out + 1] = current
    end
  end
  out[#out + 1] = route[#route]
  return out
end

--- How far apart two positions are on the ground plane.
function navigation.ground_distance(a, b)
  local dx, dz = b.x - a.x, b.z - a.z
  return math.sqrt(dx * dx + dz * dz)
end

--- The nearest traversable column the bot remembers next to a target it cannot
--- stand in. A door is not somewhere to stand; the doorstep is.
function navigation.approach_cell(memo, target)
  local best, best_distance = nil, math.huge
  for _, offset in ipairs(beliefs.NEIGHBOURS) do
    local cell = memory.get_cell(memo, target.x + offset[1], target.z + offset[2])
    if cell and beliefs.is_traversable(cell) then
      local distance = math.abs(cell.ground_y - (target.y or cell.ground_y))
      if distance < best_distance then
        best, best_distance = cell, distance
      end
    end
  end
  if not best then return nil end
  return {x = best.x, y = best.ground_y + 1, z = best.z}
end

return navigation
