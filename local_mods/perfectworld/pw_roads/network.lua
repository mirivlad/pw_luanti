-- pw_roads/network.lua
--
-- The roads *between* settlements.
--
-- Every settlement candidate a region plans carries a road anchor. This file
-- decides which of those anchors are joined to which, and along what line. It
-- decides nothing about the ground: a link is a plan, and stays a plan until
-- something materializes it.
--
-- === Why a Gabriel graph ===
--
-- The hard requirement is that the network must not depend on where you stand
-- when you ask for it. Region (0,0) and region (0,1) both border the same
-- countryside; if each invented its own idea of which settlements are joined,
-- a road would exist from one side and not from the other, and the world would
-- contradict itself at the seam.
--
-- Joining every pair within range fails a different way: it produces a cobweb,
-- with long links running straight past a settlement that sits on the way. So
-- does joining each anchor to its k nearest, which is not even symmetric — b
-- can be a's nearest without a being b's.
--
-- The Gabriel graph joins a and b exactly when no third anchor lies inside the
-- circle that has ab as its diameter: "there is nothing between them". It is
-- symmetric by construction, it is decided purely by the positions involved,
-- and — this is the property that makes it usable here — deciding one edge only
-- ever needs anchors near that edge. No global pass, no ordering, no state.
-- It also contains every nearest-neighbour pair, so no settlement is left
-- stranded while a neighbour sits within sight.
--
-- The test is exact in integers: c lies strictly inside the circle on diameter
-- ab if and only if the angle acb is obtuse, which is (a-c)·(b-c) < 0. No
-- square roots, no epsilon, no drift between one caller and the next.

local roads = perfectworld.roads
local choice = perfectworld.core.choice

--- The longest link the network will draw, in nodes.
--
-- Two settlements further apart than this are simply not neighbours, and the
-- land between them stays wild. The cap is also what keeps the decision local:
-- see `neighbourhood_radius` below.
roads.LINK_MAX_DISTANCE = 900

--- How much a link is allowed to bow away from the straight line, as a
--- fraction of its length. Roads that run dead straight for nine hundred nodes
--- look surveyed, not walked.
roads.LINK_MAX_BOW = 0.10

--- Spacing of the points along a link. Materialization walks between
--- consecutive points and follows the ground; this only controls the curve.
roads.LINK_POINT_SPACING = 40

--- Link classes, by the pair of settlements at the ends.
--
-- A road is as important as the smaller of the two places it serves: a track
-- to a lone farm does not become a highway because it happens to end at a
-- village.
--
-- The surface is part of the class and not a decoration: a road you can tell
-- apart by looking at it is one the bot's perception can tell apart too, and
-- one a test can check without consulting the plan.
roads.LINK_CLASSES = {
  highway = {width = 3, rank = 3, surface = "gravel"},
  road    = {width = 2, rank = 2, surface = "road"},
  track   = {width = 1, rank = 1, surface = "footpath"},
}

local SETTLEMENT_RANK = {village = 3, hamlet = 2, farm = 1}

local function rank_of(settlement_type)
  return SETTLEMENT_RANK[settlement_type] or 1
end

function roads.link_class(type_a, type_b)
  local rank = math.min(rank_of(type_a), rank_of(type_b))
  if rank >= 3 then return "highway" end
  if rank >= 2 then return "road" end
  return "track"
end

--- How many regions out the anchor field must reach for the decision to be
--- safe, given the link cap.
--
-- Deciding whether a-b is an edge needs every anchor that could be inside the
-- circle on diameter ab, and each of those is within `LINK_MAX_DISTANCE` of a.
-- Region planning keeps anchors at least `REGION_MARGIN` inside their region,
-- so an anchor outside a radius-n neighbourhood is more than n * REGION_SIZE
-- away from anything inside the middle one. One region of reach is therefore
-- enough as long as the cap stays below the region size.
local function neighbourhood_radius()
  local size = perfectworld.REGION_SIZE or 1024
  return math.max(1, math.ceil(roads.LINK_MAX_DISTANCE / size))
end

roads._neighbourhood_radius = neighbourhood_radius

--- Every anchor in and around a region, with the settlement it belongs to.
--
-- The anchor records a region plans carry only a position and a reference. The
-- class of a link depends on what stands at each end, so the settlement is
-- joined back on here rather than duplicated into the anchor.
function roads.anchor_field(rx, rz, radius)
  local planner = perfectworld.planner
  if not planner or type(planner.plan_region) ~= "function" then return {} end
  radius = radius or neighbourhood_radius()

  local field = {}
  for dx = -radius, radius do
    for dz = -radius, radius do
      local plan = planner.plan_region(rx + dx, rz + dz)
      local settlements = {}
      for _, candidate in ipairs(plan.settlement_candidates or {}) do
        settlements[candidate.id] = candidate
      end
      for _, anchor in ipairs(plan.road_anchors or {}) do
        local candidate = settlements[anchor.ref]
        if candidate then
          field[#field + 1] = {
            id = anchor.id,
            ref = anchor.ref,
            x = math.floor(anchor.x),
            z = math.floor(anchor.z),
            type = candidate.type,
            priority = candidate.priority,
            rx = plan.rx,
            rz = plan.rz,
          }
        end
      end
    end
  end

  -- A stable order, so that anything derived from the field is stable too.
  table.sort(field, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    return a.ref < b.ref
  end)
  return field
end

--- The canonical id of the link between two settlements.
--
-- Sorted, so the two ends agree without having to talk to each other.
function roads.link_id(ref_a, ref_b)
  local first, second = tostring(ref_a), tostring(ref_b)
  if second < first then first, second = second, first end
  return "link_v" .. tostring(perfectworld.PLANNER_VERSION)
    .. "_" .. first .. "__" .. second
end

--- Is there nothing between a and b?
--
-- Exact integer form of "c is inside the circle on diameter ab": the vectors
-- from c to each end point away from each other.
local function nothing_between(a, b, field)
  for _, c in ipairs(field) do
    if c.ref ~= a.ref and c.ref ~= b.ref then
      local ax, az = a.x - c.x, a.z - c.z
      local bx, bz = b.x - c.x, b.z - c.z
      if ax * bx + az * bz < 0 then return false end
    end
  end
  return true
end

roads._nothing_between = nothing_between

--- The line a link follows, from the lower-sorted end to the higher one.
--
-- Always generated in canonical order so that the same link planned from
-- either region produces the same points, node for node.
local function link_points(link_id, from, to)
  local dx, dz = to.x - from.x, to.z - from.z
  local length = math.sqrt(dx * dx + dz * dz)
  if length < 1 then return {{x = from.x, z = from.z}, {x = to.x, z = to.z}} end

  local segments = math.max(2, math.floor(length / roads.LINK_POINT_SPACING + 0.5))
  local seed_key = "pwlink|" .. tostring(perfectworld.world_seed_string) .. "|" .. link_id
  local bow = choice.range(seed_key, "bow", -roads.LINK_MAX_BOW, roads.LINK_MAX_BOW)
  -- Perpendicular unit vector, in the plane.
  local px, pz = -dz / length, dx / length

  local points = {}
  for step = 0, segments do
    local t = step / segments
    -- A single arch: nothing at either end, most in the middle, so the road
    -- leaves and arrives pointing at the settlement it serves.
    local swing = math.sin(math.pi * t) * bow * length
    points[#points + 1] = {
      x = math.floor(from.x + dx * t + px * swing + 0.5),
      z = math.floor(from.z + dz * t + pz * swing + 0.5),
    }
  end
  -- The ends belong to the settlements, not to the curve.
  points[1] = {x = from.x, z = from.z}
  points[#points] = {x = to.x, z = to.z}
  return points
end

roads._link_points = link_points

--- Plan every link touching a region.
--
-- Returns links incident to at least one anchor *in* (rx, rz), each planned in
-- canonical form. Planning a neighbouring region returns the shared links
-- unchanged — same id, same points, same class — which is the whole point.
-- Planned links, by region. Mapchunk generation asks for nine regions' worth on
-- every chunk, and the answer is a pure function of the seed, so it is computed
-- once. Region plans are cached the same way and for the same reason.
local link_cache = {}

function roads._test_clear_link_cache()
  link_cache = {}
end

function roads.plan_links(rx, rz)
  local cache_key = rx .. "_" .. rz
  local cached = link_cache[cache_key]
  if cached then return perfectworld.core.deep_copy(cached) end

  local field = roads.anchor_field(rx, rz)
  local max_squared = roads.LINK_MAX_DISTANCE * roads.LINK_MAX_DISTANCE
  local links = {}

  for i = 1, #field do
    for j = i + 1, #field do
      local a, b = field[i], field[j]
      -- One end must be in the region asked about; the rest of the field is
      -- there to witness, not to generate links of its own.
      if (a.rx == rx and a.rz == rz) or (b.rx == rx and b.rz == rz) then
        local dx, dz = b.x - a.x, b.z - a.z
        local distance_squared = dx * dx + dz * dz
        if distance_squared > 0 and distance_squared <= max_squared
          and nothing_between(a, b, field) then
          local from, to = a, b
          if to.ref < from.ref then from, to = b, a end
          local id = roads.link_id(a.ref, b.ref)
          local class = roads.link_class(a.type, b.type)
          links[#links + 1] = {
            id = id,
            type = "settlement_link",
            kind = class,
            width = roads.LINK_CLASSES[class].width,
            surface = roads.LINK_CLASSES[class].surface,
            from_settlement = from.ref,
            to_settlement = to.ref,
            from = {x = from.x, z = from.z},
            to = {x = to.x, z = to.z},
            distance = math.floor(math.sqrt(distance_squared) + 0.5),
            points = link_points(id, from, to),
          }
        end
      end
    end
  end

  table.sort(links, function(a, b) return a.id < b.id end)
  link_cache[cache_key] = perfectworld.core.deep_copy(links)
  return links
end

--- Every link a single settlement is an end of.
function roads.links_for_settlement(settlement_id, rx, rz)
  local out = {}
  for _, link in ipairs(roads.plan_links(rx, rz)) do
    if link.from_settlement == settlement_id or link.to_settlement == settlement_id then
      out[#out + 1] = link
    end
  end
  return out
end
