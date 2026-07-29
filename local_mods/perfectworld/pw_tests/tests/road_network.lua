-- tests/road_network.lua
-- The roads between settlements: which pairs are joined, and along what line.
--
-- The property that matters most is not in any single link, it is that two
-- regions sharing a border agree about the countryside between them. A network
-- that looks right from one side and different from the other would leave
-- roads that start and never arrive, so that is what most of this file checks.

local T = luanti_testkit
local network = perfectworld.roads

--- A region that actually has settlements in it. Region planning gives some
--- regions none at all, and a test that happened to land on an empty one would
--- pass by saying nothing.
local function populated_regions(limit)
  local found = {}
  for rx = -3, 3 do
    for rz = -3, 3 do
      local plan = perfectworld.planner.plan_region(rx, rz)
      if #(plan.settlement_candidates or {}) > 0 then
        found[#found + 1] = {rx = rx, rz = rz}
        if #found >= (limit or 4) then return found end
      end
    end
  end
  return found
end

local function summarize(link)
  return table.concat({
    link.id, link.kind, tostring(link.width),
    link.from.x .. ":" .. link.from.z,
    link.to.x .. ":" .. link.to.z,
    tostring(#link.points),
  }, "|")
end

T.register_test("perfectworld", "settlement_links_are_planned_at_all", function(ctx)
  ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
  if not network.plan_links then return end

  local total = 0
  for _, region in ipairs(populated_regions(8)) do
    total = total + #network.plan_links(region.rx, region.rz)
  end
  ctx.assert.is_true(total > 0,
    "a world with settlements in it must have roads between some of them")
end)

T.register_test("perfectworld", "a_link_is_the_same_road_seen_from_either_end", function(ctx)
  if not network.plan_links then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end

  -- Collect every link each region claims, then compare the two descriptions
  -- of every link that two regions both claim. Nothing may differ: not the
  -- class, not the width, not a single point.
  local claimed = {}
  local shared, mismatched = 0, {}
  for rx = -3, 3 do
    for rz = -3, 3 do
      for _, link in ipairs(network.plan_links(rx, rz)) do
        local seen = claimed[link.id]
        if seen then
          shared = shared + 1
          if seen ~= summarize(link) then
            mismatched[#mismatched + 1] = link.id
          end
        else
          claimed[link.id] = summarize(link)
        end
      end
    end
  end

  ctx.assert.equal(#mismatched, 0,
    "the same link must be identical from both regions, differed: "
      .. table.concat(mismatched, ","))
  ctx.assert.is_true(shared > 0,
    "the test is worthless unless some links actually cross a region border")
end)

T.register_test("perfectworld", "links_never_run_past_a_settlement_in_between", function(ctx)
  if not network.plan_links or not network.anchor_field then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end

  local checked, offenders = 0, {}
  for _, region in ipairs(populated_regions(6)) do
    local field = network.anchor_field(region.rx, region.rz)
    local by_ref = {}
    for _, anchor in ipairs(field) do by_ref[anchor.ref] = anchor end

    for _, link in ipairs(network.plan_links(region.rx, region.rz)) do
      local a, b = by_ref[link.from_settlement], by_ref[link.to_settlement]
      if a and b then
        checked = checked + 1
        for _, c in ipairs(field) do
          if c.ref ~= a.ref and c.ref ~= b.ref then
            -- Inside the circle on diameter ab: the angle at c is obtuse.
            local ax, az = a.x - c.x, a.z - c.z
            local bx, bz = b.x - c.x, b.z - c.z
            if ax * bx + az * bz < 0 then
              offenders[#offenders + 1] = link.id
              break
            end
          end
        end
      end
    end
  end

  ctx.assert.is_true(checked > 0, "no links were checked, so nothing was proved")
  ctx.assert.equal(#offenders, 0,
    "a link must not skip over a settlement lying between its ends: "
      .. table.concat(offenders, ","))
end)

T.register_test("perfectworld", "the_nearest_settlement_is_always_reachable", function(ctx)
  if not network.plan_links or not network.anchor_field then
    ctx.assert.not_nil(network.anchor_field, "roads must expose the anchor field")
    return
  end

  -- Nobody within range may be left off the network. If a neighbour is close
  -- enough to link at all, the closest one must be linked, or settlements
  -- would sit in sight of each other with no way between.
  local checked, stranded = 0, {}
  for _, region in ipairs(populated_regions(6)) do
    local field = network.anchor_field(region.rx, region.rz)
    local links = network.plan_links(region.rx, region.rz)
    local joined = {}
    for _, link in ipairs(links) do
      joined[link.from_settlement .. ">" .. link.to_settlement] = true
      joined[link.to_settlement .. ">" .. link.from_settlement] = true
    end

    for _, a in ipairs(field) do
      if a.rx == region.rx and a.rz == region.rz then
        local nearest, best = nil, math.huge
        for _, b in ipairs(field) do
          if b.ref ~= a.ref then
            local dx, dz = b.x - a.x, b.z - a.z
            local d = dx * dx + dz * dz
            if d < best then nearest, best = b, d end
          end
        end
        if nearest and best <= network.LINK_MAX_DISTANCE * network.LINK_MAX_DISTANCE then
          checked = checked + 1
          if not joined[a.ref .. ">" .. nearest.ref] then
            stranded[#stranded + 1] = a.ref
          end
        end
      end
    end
  end

  ctx.assert.is_true(checked > 0, "no settlement had a neighbour in range to check")
  ctx.assert.equal(#stranded, 0,
    "these settlements have a neighbour in range and no road to it: "
      .. table.concat(stranded, ","))
end)

T.register_test("perfectworld", "no_link_exceeds_the_distance_it_is_capped_at", function(ctx)
  if not network.plan_links then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end
  local too_long = {}
  for rx = -3, 3 do
    for rz = -3, 3 do
      for _, link in ipairs(network.plan_links(rx, rz)) do
        if link.distance > network.LINK_MAX_DISTANCE then
          too_long[#too_long + 1] = link.id .. "=" .. link.distance
        end
      end
    end
  end
  ctx.assert.equal(#too_long, 0,
    "links must respect the cap that keeps the decision local: "
      .. table.concat(too_long, ","))
end)

T.register_test("perfectworld", "a_link_starts_and_ends_at_the_settlements_it_serves", function(ctx)
  if not network.plan_links then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end

  local wrong = {}
  for _, region in ipairs(populated_regions(6)) do
    for _, link in ipairs(network.plan_links(region.rx, region.rz)) do
      local first, last = link.points[1], link.points[#link.points]
      if first.x ~= link.from.x or first.z ~= link.from.z
        or last.x ~= link.to.x or last.z ~= link.to.z then
        wrong[#wrong + 1] = link.id
      end
      if #link.points < 2 then wrong[#wrong + 1] = link.id .. ":degenerate" end
    end
  end
  ctx.assert.equal(#wrong, 0,
    "a road that misses the village it was drawn for is not a road: "
      .. table.concat(wrong, ","))
end)

T.register_test("perfectworld", "a_links_curve_stays_within_its_stated_bow", function(ctx)
  if not network.plan_links then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end

  -- A bowed road is scenery; a road that wanders off is a bug that would send
  -- the paving crew across a mountain range.
  local wandering, bowed = {}, 0
  for _, region in ipairs(populated_regions(6)) do
    for _, link in ipairs(network.plan_links(region.rx, region.rz)) do
      local dx, dz = link.to.x - link.from.x, link.to.z - link.from.z
      local length = math.sqrt(dx * dx + dz * dz)
      local limit = length * network.LINK_MAX_BOW + 1.5
      local furthest = 0
      for _, point in ipairs(link.points) do
        -- Distance from the point to the straight line through the ends.
        local off = math.abs(dx * (point.z - link.from.z) - dz * (point.x - link.from.x))
          / math.max(length, 1)
        if off > furthest then furthest = off end
      end
      if furthest > limit then
        wandering[#wandering + 1] = link.id .. string.format("=%.1f>%.1f", furthest, limit)
      end
      if furthest > 1 then bowed = bowed + 1 end
    end
  end

  ctx.assert.equal(#wandering, 0,
    "a link must stay within its bow of the straight line: "
      .. table.concat(wandering, ","))
  ctx.assert.is_true(bowed > 0,
    "every link came out dead straight, so the curve is not being applied")
end)

T.register_test("perfectworld", "a_road_is_no_grander_than_the_smaller_place_it_serves", function(ctx)
  if not network.link_class then
    ctx.assert.not_nil(network.link_class, "roads must classify links by their ends")
    return
  end
  ctx.assert.equal(network.link_class("village", "village"), "highway",
    "two villages are joined by the largest class of road")
  ctx.assert.equal(network.link_class("village", "farm"), "track",
    "a lone farm gets a track even when the other end is a village")
  ctx.assert.equal(network.link_class("hamlet", "village"), "road",
    "a hamlet is served by a road, whichever way round it is asked")
  ctx.assert.equal(network.link_class("village", "hamlet"),
    network.link_class("hamlet", "village"),
    "the class of a road cannot depend on which end you start from")
end)

T.register_test("perfectworld", "every_stretch_of_every_link_is_claimed_by_the_chunk_it_crosses", function(ctx)
  local find = perfectworld.planner._links_near_chunk
  if not find then
    ctx.assert.not_nil(find, "the planner must find the links crossing a chunk")
    return
  end

  -- A link is paved by whichever mapchunk it happens to cross, and a chunk only
  -- knows about the regions it can reach. A stretch running through countryside
  -- far from both of its settlements is the case that silently leaves a gap, so
  -- every point of every link is checked against the chunk that contains it.
  local size = 80
  local checked, unclaimed = 0, {}
  for _, region in ipairs(populated_regions(4)) do
    for _, link in ipairs(network.plan_links(region.rx, region.rz)) do
      for _, point in ipairs(link.points) do
        local minp = {
          x = math.floor(point.x / size) * size, y = -64,
          z = math.floor(point.z / size) * size,
        }
        local maxp = {x = minp.x + size - 1, y = 256, z = minp.z + size - 1}
        local claimed = false
        for _, found in ipairs(find(minp, maxp)) do
          if found.id == link.id then claimed = true break end
        end
        checked = checked + 1
        if not claimed then
          unclaimed[#unclaimed + 1] = link.id .. "@" .. point.x .. "," .. point.z
          break
        end
      end
    end
  end

  ctx.assert.is_true(checked > 0, "no stretch was checked, so nothing was proved")
  ctx.assert.equal(#unclaimed, 0,
    "no chunk would ever pave these stretches: " .. table.concat(unclaimed, " "))
end)

T.register_test("perfectworld", "a_chunk_no_link_crosses_is_left_alone", function(ctx)
  local touches = perfectworld.planner._segment_touches_chunk
  if not touches then
    ctx.assert.not_nil(touches, "the planner must decide whether a segment crosses a chunk")
    return
  end

  local minp = {x = 0, y = -64, z = 0}
  local maxp = {x = 79, y = 256, z = 79}
  ctx.assert.is_false(touches({x = 200, z = 40}, {x = 300, z = 40}, minp, maxp),
    "a segment well to the east must not be paved into this chunk")
  ctx.assert.is_false(touches({x = 40, z = -300}, {x = 40, z = -200}, minp, maxp),
    "a segment well to the north must not be paved into this chunk")
  ctx.assert.is_true(touches({x = -100, z = 40}, {x = 100, z = 40}, minp, maxp),
    "a segment running clean through the chunk must be paved")
  ctx.assert.is_true(touches({x = 40, z = 40}, {x = 40, z = 400}, minp, maxp),
    "a segment starting inside the chunk must be paved")
end)

T.register_test("perfectworld", "an_empty_stretch_of_countryside_paves_nothing", function(ctx)
  if not perfectworld.planner.pave_links_in_chunk then
    ctx.assert.not_nil(perfectworld.planner.pave_links_in_chunk,
      "the planner must pave the links crossing a chunk")
    return
  end

  -- Somewhere no settlement has been planned within link range. Paving must be
  -- a no-op there rather than writing a road across empty ground.
  local size = 80
  local found_empty = false
  for step = 0, 40 do
    local base = 40000 + step * size
    local minp = {x = base, y = -64, z = base}
    local maxp = {x = base + size - 1, y = 256, z = base + size - 1}
    local crossing = 0
    for _, link in ipairs(perfectworld.planner._links_near_chunk(minp, maxp)) do
      for i = 1, #link.points - 1 do
        if perfectworld.planner._segment_touches_chunk(
          link.points[i], link.points[i + 1], minp, maxp) then
          crossing = crossing + 1
        end
      end
    end
    if crossing == 0 then
      found_empty = true
      local result = perfectworld.planner.pave_links_in_chunk(minp, maxp)
      ctx.assert.equal(result.nodes, 0, "empty countryside must stay empty")
      ctx.assert.equal(result.links, 0, "no link crosses here, so none may be recorded")
      break
    end
  end
  ctx.assert.is_true(found_empty, "found no chunk without a link, so nothing was proved")
end)

T.register_test("perfectworld", "a_road_profile_is_walkable_end_to_end", function(ctx)
  local profile = perfectworld.planner._walkable_profile
  if not profile then
    ctx.assert.not_nil(profile, "the planner must flatten ground into a road profile")
    return
  end

  -- A cliff, a valley, a plateau and a spike, which between them cover every
  -- way a height profile can go wrong.
  local ground = {64, 64, 65, 78, 78, 78, 60, 61, 62, 62, 90, 62, 62, 63}
  local y = profile(ground, 1, #ground)

  for i = 2, #ground do
    ctx.assert.is_true(math.abs(y[i] - y[i - 1]) <= 1,
      string.format("step of %d between cell %d and %d is not walkable",
        math.abs(y[i] - y[i - 1]), i - 1, i))
  end
  for i = 1, #ground do
    -- The rule used to be "never above the ground at all". It is now "never
    -- more than an embankment above it": the profile has a floor under it so a
    -- road does not bore a mine under a mountain, and lifting it out of the
    -- abyss means it sometimes rides a little proud of a dip. More than an
    -- embankment's worth and the road is decked instead.
    ctx.assert.is_true(y[i] <= ground[i] + 3,
      "a road may ride an embankment but not float, at cell " .. i
        .. ": ground " .. ground[i] .. ", road " .. y[i])
  end
  -- Flat ground must be left exactly as it is, or every road would sit in a
  -- trench of its own making.
  ctx.assert.equal(y[1], 64, "flat ground must be paved at its own level")
  ctx.assert.equal(y[2], 64, "flat ground must be paved at its own level")
end)

T.register_test("perfectworld", "a_road_profile_reads_the_same_forwards_and_backwards", function(ctx)
  local profile = perfectworld.planner._walkable_profile
  if not profile then
    ctx.assert.not_nil(profile, "the planner must flatten ground into a road profile")
    return
  end

  -- Two chunks pave the same road from opposite directions. A profile that
  -- depended on which way it was walked would leave a step at every seam.
  local ground = {70, 71, 84, 85, 66, 67, 68, 90, 91, 64}
  local forward = profile(ground, 1, #ground)
  local reversed = {}
  for i = 1, #ground do reversed[i] = ground[#ground + 1 - i] end
  local backward = profile(reversed, 1, #ground)

  for i = 1, #ground do
    ctx.assert.equal(forward[i], backward[#ground + 1 - i],
      "the profile must not depend on the direction it was computed in, at cell " .. i)
  end
end)

T.register_test("perfectworld", "narrow_water_is_bridged_and_open_water_is_not", function(ctx)
  local bridgeable = perfectworld.planner._bridgeable
  if not bridgeable then
    ctx.assert.not_nil(bridgeable, "the planner must decide which water it will cross")
    return
  end

  -- A stream, then a lake far too wide to bridge. The stream gets a deck; the
  -- lake gets left alone, because a road that walks across open water is worse
  -- than a road that stops at the shore.
  local water = {}
  for i = 1, 200 do water[i] = false end
  for i = 20, 25 do water[i] = true end
  for i = 60, 180 do water[i] = true end

  local ok = bridgeable(water, 1, 200)
  for i = 20, 25 do
    ctx.assert.is_true(ok[i] == true, "a six-node stream must be bridged, at cell " .. i)
  end
  for i = 60, 180 do
    ctx.assert.is_true(ok[i] ~= true, "open water must not be paved over, at cell " .. i)
  end
  ctx.assert.is_true(ok[19] == nil, "dry ground is not the bridge's business")
end)

T.register_test("perfectworld", "a_links_centreline_has_no_holes_in_it", function(ctx)
  local centreline = perfectworld.planner._link_centreline
  if not centreline or not network.plan_links then
    ctx.assert.not_nil(centreline, "the planner must walk a link cell by cell")
    return
  end

  -- Every cell must touch the one before it. A centreline that jumps is a road
  -- with holes, and the holes would be exactly where the profile is steepest.
  local checked, jumps = 0, {}
  for _, region in ipairs(populated_regions(3)) do
    for _, link in ipairs(network.plan_links(region.rx, region.rz)) do
      local cells = centreline(link)
      ctx.assert.is_true(#cells > 1, "a link must be more than one cell long")
      for i = 2, #cells do
        checked = checked + 1
        local step = math.max(math.abs(cells[i].x - cells[i - 1].x),
          math.abs(cells[i].z - cells[i - 1].z))
        if step ~= 1 then
          jumps[#jumps + 1] = link.id .. "@" .. i .. "=" .. step
        end
      end
      local last = cells[#cells]
      ctx.assert.equal(last.x .. "," .. last.z, link.to.x .. "," .. link.to.z,
        "the centreline must reach the far settlement")
    end
  end
  ctx.assert.is_true(checked > 0, "no centreline was walked, so nothing was proved")
  ctx.assert.equal(#jumps, 0,
    "the centreline skipped cells: " .. table.concat(jumps, " "))
end)

T.register_test("perfectworld", "a_paved_way_can_be_walked_from_end_to_end", function(ctx)
  local pave = perfectworld.planner._pave_way
  if not pave then
    ctx.assert.not_nil(pave, "the planner must be able to pave a way")
    return
  end

  -- Ground that goes wrong in every way a road can: a flat run, a gentle
  -- climb, a cliff, and a dip. The claim is that what comes out is walkable
  -- whatever went in — this is the same code village streets and the roads
  -- between settlements both use, so one wrong profile would be wrong in both.
  -- Inside the engine's map limit, which is a little over 31000: `set_node`
  -- past it silently does nothing, and the first version of this test built
  -- its hillside at 32100 and measured an empty world.
  local origin = {x = 29800, z = -29800}
  local base = 40
  local heights = {}
  local length = 48
  for i = 1, length do
    local y = base
    if i > 12 and i <= 24 then y = base + math.floor((i - 12) / 2) end
    if i > 24 and i <= 30 then y = base + 14 end
    if i > 30 then y = base - 3 end
    heights[i] = y
  end

  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 3, y = base - 12, z = origin.z - 4},
      {x = origin.x + length + 3, y = base + 24, z = origin.z + 4})
  end
  local ground = perfectworld.compat.get_material("ground", {required = false})
  for i = 1, length do
    local x = origin.x + i
    for dz = -3, 3 do
      for y = base - 10, base + 22 do
        minetest.set_node({x = x, y = y, z = origin.z + dz},
          {name = y <= heights[i] and ground or "air"})
      end
    end
  end

  perfectworld.planner._world_terrain.reset()
  local cells = {}
  for i = 1, length do cells[i] = {x = origin.x + i, z = origin.z} end
  local placed = pave(cells, 1, length, {width = 1, surface = "road"})
  ctx.assert.is_true(placed > 0, "the way must actually be laid")

  local surface = perfectworld.compat.get_material("road", {required = false})
  local previous, biggest, missing = nil, 0, 0
  local floating = 0
  for i = 1, length do
    local found = nil
    for y = base + 24, base - 12, -1 do
      if minetest.get_node({x = cells[i].x, y = y, z = cells[i].z}).name == surface then
        found = y
        break
      end
    end
    if not found then
      missing = missing + 1
      previous = nil
    else
      -- Nothing under the carriageway is a road hanging in the air.
      local below = minetest.get_node({x = cells[i].x, y = found - 1, z = cells[i].z}).name
      if below == "air" or below == "ignore" then floating = floating + 1 end
      if previous then
        local step = math.abs(found - previous)
        if step > biggest then biggest = step end
      end
      previous = found
    end
  end

  ctx.assert.equal(missing, 0, "every cell of the way must be paved")
  ctx.assert.equal(floating, 0, "no stretch of the way may hang in the air")
  ctx.assert.is_true(biggest <= 1,
    "a walker steps up one node, and the way asked for " .. biggest)

  for i = 1, length do
    for dz = -3, 3 do
      for y = base - 10, base + 22 do
        minetest.set_node({x = origin.x + i, y = y, z = origin.z + dz}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end)

T.register_test("perfectworld", "planning_the_same_region_twice_gives_the_same_roads", function(ctx)
  if not network.plan_links then
    ctx.assert.not_nil(network.plan_links, "roads must plan links between settlements")
    return
  end
  local region = populated_regions(1)[1]
  ctx.assert.not_nil(region, "no populated region was found to plan")
  if not region then return end

  local function fingerprint(rx, rz)
    local parts = {}
    for _, link in ipairs(network.plan_links(rx, rz)) do
      parts[#parts + 1] = summarize(link)
      for _, point in ipairs(link.points) do
        parts[#parts + 1] = point.x .. "," .. point.z
      end
    end
    return table.concat(parts, ";")
  end

  ctx.assert.equal(fingerprint(region.rx, region.rz), fingerprint(region.rx, region.rz),
    "the road network must be a function of the seed and nothing else")
end)

T.register_test("perfectworld", "a_road_through_a_hill_leaves_the_hill_standing", function(ctx)
  local pave = perfectworld.planner._pave_way
  if not pave then
    ctx.assert.not_nil(pave, "the planner must be able to pave a way")
    return
  end

  -- A ridge across the line of the road, too long to walk round inside the
  -- lateral limit, with flat ground either side of it. What the road must not
  -- do is open the ridge from the sky down: that is a canyon with a road at the
  -- bottom, and it is what this project built until the head-room clearing was
  -- bounded.
  local origin = {x = 28600, z = -28600}
  local base, crest = 30, 44
  local length = 60
  local ridge_from, ridge_to = 22, 38
  local ground = perfectworld.compat.get_material("ground", {required = false})

  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 2, y = base - 8, z = origin.z - 26},
      {x = origin.x + length + 2, y = crest + 12, z = origin.z + 26})
  end
  -- The ridge runs across the way and far to either side of it, so there is no
  -- flank to go round: the only ways past are through it or over it.
  for i = 1, length do
    local x = origin.x + i
    local top = (i >= ridge_from and i <= ridge_to) and crest or base
    for dz = -24, 24 do
      for y = base - 6, crest + 10 do
        minetest.set_node({x = x, y = y, z = origin.z + dz},
          {name = y <= top and ground or "air"})
      end
    end
  end

  perfectworld.planner._world_terrain.reset()
  local cells = {}
  for i = 1, length do cells[i] = {x = origin.x + i, z = origin.z} end
  local placed = pave(cells, 1, length, {width = 1, surface = "road"})
  ctx.assert.is_true(placed > 0, "the way must actually be laid")

  local surface = perfectworld.compat.get_material("road", {required = false})
  -- At the middle of the ridge, find the road and then look up. If the hill is
  -- still there, there is rock over the road. If it was cut open, there is sky.
  local middle = math.floor((ridge_from + ridge_to) / 2)
  local road_y = nil
  for y = crest + 10, base - 8, -1 do
    if minetest.get_node({x = origin.x + middle, y = y, z = origin.z}).name == surface then
      road_y = y
      break
    end
  end

  if road_y then
    local cover = 0
    for y = road_y + 4, crest do
      local name = minetest.get_node({x = origin.x + middle, y = y, z = origin.z}).name
      if name ~= "air" and name ~= "ignore" then cover = cover + 1 end
    end
    ctx.assert.is_true(cover > 0,
      "the hill must still stand over the road: found " .. cover
        .. " nodes of cover between y=" .. (road_y + 4) .. " and the crest at " .. crest)
  else
    -- No road at the crest at all is the other acceptable answer: the way went
    -- round, or stopped. What is not acceptable is a road with the hill gone.
    local standing = 0
    for y = base, crest do
      local name = minetest.get_node({x = origin.x + middle, y = y, z = origin.z}).name
      if name ~= "air" and name ~= "ignore" then standing = standing + 1 end
    end
    ctx.assert.is_true(standing > 0,
      "no road at the crest and no hill either: the ridge was removed")
  end

  for i = 1, length do
    for dz = -24, 24 do
      for y = base - 6, crest + 10 do
        minetest.set_node({x = origin.x + i, y = y, z = origin.z + dz}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end)

T.register_test("perfectworld", "a_road_does_not_bore_a_mine_under_a_mountain", function(ctx)
  local profile = perfectworld.planner._walkable_profile
  if not profile then
    ctx.assert.not_nil(profile, "the planner must flatten ground into a road profile")
    return
  end

  -- A coast with a mountain behind it: the lowest ground within reach is sea
  -- level, and an unbounded profile takes the road down to it and bores through
  -- the mountain at that level. Measured on a real link before this was bounded:
  -- a cut 191 deep.
  local ground = {}
  for i = 1, 30 do ground[i] = 4 end
  for i = 31, 90 do ground[i] = math.min(4 + (i - 30) * 4, 190) end
  for i = 91, 140 do ground[i] = 190 end

  local y = profile(ground, 1, #ground)

  local deepest = 0
  for i = 1, #ground do
    local cut = ground[i] - y[i]
    if cut > deepest then deepest = cut end
  end
  ctx.assert.is_true(deepest <= 24,
    "a road may tunnel, not mine: deepest cut was " .. deepest)

  -- And it must still be walkable, which is the constraint the floor could
  -- easily have broken.
  for i = 2, #ground do
    ctx.assert.is_true(math.abs(y[i] - y[i - 1]) <= 1,
      "step of " .. math.abs(y[i] - y[i - 1]) .. " at cell " .. i)
  end

  -- The road does climb early, and that is correct: it cannot be at sea level
  -- beside the mountain and on top of it sixty cells later at one node a cell.
  -- What it must not do is stay at sea level and bore.
  ctx.assert.is_true(y[120] > 150,
    "the road must be up on the mountain by the far end, not under it: " .. y[120])
end)

T.register_test("perfectworld", "a_road_goes_round_a_hill_rather_than_through_it", function(ctx)
  local route = perfectworld.planner.route_way
  if not route then
    ctx.assert.not_nil(route, "the planner must route a way against the ground")
    return
  end

  -- A round hill with clear ground either side of it, straddling the line. A
  -- road with somewhere to go should go round: tunnelling is what a machine
  -- does because a machine finds tunnelling cheap, and people do not.
  local origin = {x = 29500, z = -29500}
  local base, crest = 30, 52
  local length = 120
  local hill_at, hill_radius = 60, 22
  local ground = perfectworld.compat.get_material("ground", {required = false})

  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 2, y = base - 6, z = origin.z - 60},
      {x = origin.x + length + 2, y = crest + 8, z = origin.z + 60})
  end
  for i = 1, length do
    for dz = -55, 55 do
      -- A dome: high on the line, falling away to open ground either side.
      local from_centre = math.sqrt((i - hill_at) ^ 2 + dz ^ 2)
      local top = base
      if from_centre < hill_radius then
        top = base + math.floor((crest - base) * (1 - from_centre / hill_radius))
      end
      for y = base - 4, crest + 6 do
        minetest.set_node({x = origin.x + i, y = y, z = origin.z + dz},
          {name = y <= top and ground or "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()

  local cells, raw, water = {}, {}, {}
  for i = 1, length do
    cells[i] = {x = origin.x + i, z = origin.z}
    raw[i] = perfectworld.planner._paving_level(cells[i].x, cells[i].z)
    water[i] = false
  end

  local result = route(cells, 1, length, raw, water)
  ctx.assert.not_nil(result, "the way must be routed")

  local tunnelled, moved = 0, 0
  for i = 1, length do
    if result.mode[i] == "tunnel" then tunnelled = tunnelled + 1 end
    local shifted = math.abs(result.cells[i].z - origin.z)
    if shifted > moved then moved = shifted end
  end

  ctx.assert.is_true(moved >= 8,
    "the road must move aside to clear the hill; it moved " .. moved)
  ctx.assert.is_true(tunnelled == 0,
    "with open ground either side there is no reason to tunnel, and it tunnelled "
      .. tunnelled .. " cell(s) after moving " .. moved)

  for i = 1, length do
    for dz = -55, 55 do
      for y = base - 4, crest + 6 do
        minetest.set_node({x = origin.x + i, y = y, z = origin.z + dz}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end)

T.register_test("perfectworld", "a_road_through_a_wood_fells_the_trees_it_clears", function(ctx)
  local pave = perfectworld.planner._pave_way
  if not pave then
    ctx.assert.not_nil(pave, "the planner must be able to pave a way")
    return
  end

  -- Flat ground with a line of trees across it. Clearing head-room used to cut
  -- the trunk at road height and leave everything above it hanging in the sky,
  -- which from the air is the most obviously wrong thing about a road through
  -- forest. Clearing a wood for a road is ordinary; leaving the tops up is not.
  local origin = {x = 29050, z = -29050}
  local base = 24
  local length = 30
  local ground = perfectworld.compat.get_material("ground", {required = false})
  local trunk = perfectworld.compat.get_material("tree", {required = false})
  if not trunk or trunk == "air" or not minetest.registered_nodes[trunk] then
    ctx.assert.is_true(true, "this game registers no tree trunk to fell")
    return
  end

  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 3, y = base - 4, z = origin.z - 4},
      {x = origin.x + length + 3, y = base + 24, z = origin.z + 4})
  end
  for x = origin.x - 2, origin.x + length + 2 do
    for z = origin.z - 3, origin.z + 3 do
      minetest.set_node({x = x, y = base - 1, z = z}, {name = ground})
      for y = base, base + 22 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  -- A trunk fourteen high standing on the line of the road.
  local tree_x = origin.x + 15
  for y = base, base + 13 do
    minetest.set_node({x = tree_x, y = y, z = origin.z}, {name = trunk})
  end

  perfectworld.planner._world_terrain.reset()
  local cells = {}
  for i = 1, length do cells[i] = {x = origin.x + i, z = origin.z} end
  pave(cells, 1, length, {width = 1, surface = "road", deviate = false})

  local left_standing = 0
  for y = base, base + 13 do
    local name = minetest.get_node({x = tree_x, y = y, z = origin.z}).name
    if name == trunk then left_standing = left_standing + 1 end
  end
  ctx.assert.equal(left_standing, 0,
    "the road cut the tree and left " .. left_standing
      .. " node(s) of trunk hanging over the carriageway")

  for x = origin.x - 2, origin.x + length + 2 do
    for z = origin.z - 3, origin.z + 3 do
      for y = base - 1, base + 22 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end)

T.register_test("perfectworld", "a_way_across_water_is_a_boardwalk_not_a_path_on_the_bottom", function(ctx)
  local carve = perfectworld.planner._carve_walkway
  if not carve then
    ctx.assert.not_nil(carve, "the planner must be able to carve a way")
    return
  end

  -- A trench of standing water between a door and a street. `paving_level` in a
  -- flooded column returns the floor of the basin, because water counts as
  -- loose cover, so a way across a shoal used to be laid along the bottom — and
  -- a villager stepping out of the house walked straight into the sea.
  local origin = {x = 29800, y = 30, z = -29800}
  local ground = perfectworld.compat.get_material("ground", {required = false})
  local water = perfectworld.compat.get_material("water", {required = false})
  if not water or water == "air" then
    ctx.assert.is_true(true, "this game has no water to cross")
    return
  end

  local length = 24
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = origin.x - 3, y = origin.y - 10, z = origin.z - 3},
      {x = origin.x + length + 3, y = origin.y + 8, z = origin.z + 3})
  end
  -- Solid everywhere, then a trench dug out of the middle of it.
  for x = origin.x - 2, origin.x + length + 2 do
    for z = origin.z - 2, origin.z + 2 do
      for y = origin.y - 8, origin.y + 6 do
        minetest.set_node({x = x, y = y, z = z},
          {name = y < origin.y and ground or "air"})
      end
    end
  end
  for x = origin.x + 8, origin.x + 16 do
    for z = origin.z - 1, origin.z + 1 do
      for y = origin.y - 4, origin.y - 1 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  -- The water goes in second, once the trench exists: filling as you dig pours
  -- each column into the next one before it has been dug.
  for x = origin.x + 8, origin.x + 16 do
    for z = origin.z - 1, origin.z + 1 do
      for y = origin.y - 4, origin.y - 1 do
        minetest.set_node({x = x, y = y, z = z}, {name = water})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()

  local wet_cells = 0
  for x = origin.x + 8, origin.x + 16 do
    if perfectworld.compat.is_liquid_node(
      minetest.get_node({x = x, y = origin.y - 1, z = origin.z}).name) then
      wet_cells = wet_cells + 1
    end
  end
  if wet_cells < 5 then
    return ctx.skip("the water would not stay in the trench: " .. wet_cells .. " cell(s)")
  end

  carve({x = origin.x, y = origin.y, z = origin.z},
    {x = origin.x + length, z = origin.z},
    perfectworld.compat.get_material("road", {required = false}), nil, {})

  -- Across the water the way must be at the doorstep's level, not on the bed.
  -- Piles are allowed down there, and wanted: without them the decking is a
  -- plank ribbon lying on the sea. What must not be down there is the path.
  local surface = perfectworld.compat.get_material("road", {required = false})
  local on_the_bottom, decked, piles = 0, 0, 0
  for x = origin.x + 9, origin.x + 15 do
    local at_level = minetest.get_node({x = x, y = origin.y - 1, z = origin.z}).name
    local below = minetest.get_node({x = x, y = origin.y - 4, z = origin.z}).name
    if at_level ~= "air" and not perfectworld.compat.is_liquid_node(at_level) then
      decked = decked + 1
    end
    if below == surface then on_the_bottom = on_the_bottom + 1 end
    if below ~= "air" and below ~= ground and below ~= surface
      and not perfectworld.compat.is_liquid_node(below) then
      piles = piles + 1
    end
  end

  ctx.assert.is_true(decked >= 5,
    "the way across the water must be held at the doorstep's level; "
      .. decked .. " of 7 cells were")
  ctx.assert.equal(on_the_bottom, 0,
    "and the path itself must not be laid along the bed: "
      .. on_the_bottom .. " cell(s) were")
  ctx.assert.is_true(piles > 0,
    "the decking must stand on something rather than lie on the sea")

  for x = origin.x - 2, origin.x + length + 2 do
    for z = origin.z - 2, origin.z + 2 do
      for y = origin.y - 8, origin.y + 6 do
        minetest.set_node({x = x, y = y, z = z}, {name = "air"})
      end
    end
  end
  perfectworld.planner._world_terrain.reset()
end)
