-- tests/roads.lua
-- Exact shared road raster contracts.

local T = luanti_testkit

local function straight(kind)
  local points = {}
  for index = 0, 4 do
    if kind == "horizontal" then
      points[#points + 1] = {x = index, z = 0}
    elseif kind == "vertical" then
      points[#points + 1] = {x = 0, z = index}
    else
      points[#points + 1] = {x = index, z = index}
    end
  end
  return points
end

local function keys(cells)
  local result = {}
  for _, cell in ipairs(cells or {}) do
    result[#result + 1] = cell.x .. ":" .. cell.z
  end
  table.sort(result)
  return table.concat(result, ",")
end

T.register_test("perfectworld", "road_raster_has_exact_integer_width", function(ctx)
  ctx.assert.not_nil(perfectworld.roads.rasterize,
    "roads must expose shared exact raster geometry")
  if not perfectworld.roads.rasterize then return end

  for _, kind in ipairs({"horizontal", "vertical", "diagonal"}) do
    for width = 1, 3 do
      local cells = perfectworld.roads.rasterize(straight(kind), width)
      ctx.assert.equal(#cells, 5 * width,
        kind .. " width " .. width .. " must cover exactly five by width cells")
    end
  end
end)

T.register_test("perfectworld", "road_width_two_never_expands_to_three", function(ctx)
  if not perfectworld.roads.rasterize then
    ctx.assert.not_nil(perfectworld.roads.rasterize,
      "roads must expose shared exact raster geometry")
    return
  end
  local cells = perfectworld.roads.rasterize(straight("horizontal"), 2)
  local rows = {}
  for _, cell in ipairs(cells) do
    if cell.x == 2 then rows[cell.z] = true end
  end
  local row_count = 0
  for _ in pairs(rows) do row_count = row_count + 1 end
  ctx.assert.equal(row_count, 2, "a width-two road must occupy two rows")
end)

T.register_test("perfectworld", "road_raster_is_canonical_and_direction_independent", function(ctx)
  if not perfectworld.roads.rasterize then
    ctx.assert.not_nil(perfectworld.roads.rasterize,
      "roads must expose shared exact raster geometry")
    return
  end
  local forward = straight("diagonal")
  local backward = {}
  for index = #forward, 1, -1 do backward[#backward + 1] = forward[index] end
  ctx.assert.equal(keys(perfectworld.roads.rasterize(forward, 2)),
    keys(perfectworld.roads.rasterize(backward, 2)),
    "reversing an undirected road must not move its even-width surface")
end)

T.register_test("perfectworld", "road_records_prefer_persisted_cells_and_support_legacy_paths", function(ctx)
  if not perfectworld.roads.rasterize_record then
    ctx.assert.not_nil(perfectworld.roads.rasterize_record,
      "roads must rasterize both new and legacy records")
    return
  end
  local persisted = perfectworld.roads.rasterize_record({
    path = straight("horizontal"),
    width = 3,
    cells = {{x = 9, z = 8}, {x = 7, z = 6}, {x = 9, z = 8}},
  })
  ctx.assert.equal(keys(persisted), "7:6,9:8",
    "persisted cells are authoritative, canonical and de-duplicated")

  local legacy = perfectworld.roads.rasterize_record({
    path = straight("vertical"),
    width = 2,
  })
  ctx.assert.equal(#legacy, 10, "legacy path and width must derive exact cells")
end)

T.register_test("perfectworld", "new_road_records_persist_their_exact_cells", function(ctx)
  local road = {
    id = "test_exact_cells_road",
    type = "local_road",
    path = straight("horizontal"),
    width = 2,
  }
  local saved = perfectworld.roads.save(road)
  ctx.assert.is_true(saved, "public roads provider must accept the record")
  local stored = perfectworld.roads.get(road.id)
  ctx.assert.not_nil(stored, "saved road must be readable")
  if stored then
    ctx.assert.equal(#(stored.cells or {}), 10,
      "new road record must persist its canonical exact cells")
  end
end)

-- === The shape a way actually covers ===
--
-- These are the contracts that were missing while every road in the world came
-- out as a chain of two-cell dashes touching at their corners. A cross-section
-- alone is not a carriageway: it has to join up.

local function staircase(steps)
  -- A shallow diagonal: two along, one across. Rasterized, this is the
  -- direction that made `cross_section` flip between north-south and east-west
  -- from one cell to the next.
  local cells = {}
  for index = 0, steps do
    cells[#cells + 1] = {x = index, z = math.floor(index / 2)}
  end
  return cells
end

local function footprint_cells(footprint, first, last)
  local set, list = {}, {}
  for i = first, last do
    for _, cell in ipairs(footprint[i] or {}) do
      local key = cell.x .. ":" .. cell.z
      if not set[key] then
        set[key] = true
        list[#list + 1] = cell
      end
    end
  end
  return set, list
end

T.register_test("perfectworld", "a_way_is_one_piece_a_walker_can_cross", function(ctx)
  ctx.assert.not_nil(perfectworld.roads.way_footprint,
    "roads must expose the shape a way covers")
  if not perfectworld.roads.way_footprint then return end

  for _, width in ipairs({1, 2, 3}) do
    local cells = staircase(12)
    local footprint = perfectworld.roads.way_footprint(cells, 1, #cells, width)
    local set, list = footprint_cells(footprint, 1, #cells)
    ctx.assert.is_true(#list > 0, "width " .. width .. " must cover something")

    -- Flood fill from the first cell over four-connected neighbours only,
    -- because that is what walking means to the engine's pathfinder.
    local seen = {[list[1].x .. ":" .. list[1].z] = true}
    local queue = {list[1]}
    local reached = 1
    while #queue > 0 do
      local cell = table.remove(queue)
      for _, step in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
        local key = (cell.x + step[1]) .. ":" .. (cell.z + step[2])
        if set[key] and not seen[key] then
          seen[key] = true
          reached = reached + 1
          queue[#queue + 1] = {x = cell.x + step[1], z = cell.z + step[2]}
        end
      end
    end
    ctx.assert.equal(reached, #list, string.format(
      "width %d: every cell of a way must be reachable from every other by "
        .. "north/south/east/west steps, reached %d of %d", width, reached, #list))
  end
end)

T.register_test("perfectworld", "a_way_does_not_change_its_mind_about_which_way_it_faces",
  function(ctx)
    if not perfectworld.roads.way_footprint then return end
    -- Along a straight run the covered width must be exactly the width asked
    -- for, with no cell owned twice and no bulges.
    local cells = {}
    for index = 0, 9 do cells[#cells + 1] = {x = index, z = 0} end
    for width = 1, 3 do
      local footprint = perfectworld.roads.way_footprint(cells, 1, #cells, width)
      local _, list = footprint_cells(footprint, 1, #cells)
      ctx.assert.equal(#list, 10 * width, string.format(
        "a straight way of width %d over ten cells covers %d, found %d",
        width, 10 * width, #list))
    end
  end)

T.register_test("perfectworld", "the_same_way_walked_backwards_covers_the_same_cells",
  function(ctx)
    if not perfectworld.roads.way_footprint then return end
    local forwards = staircase(10)
    local backwards = {}
    for index = #forwards, 1, -1 do
      backwards[#backwards + 1] = forwards[index]
    end
    for width = 1, 3 do
      local a = select(1, footprint_cells(
        perfectworld.roads.way_footprint(forwards, 1, #forwards, width), 1, #forwards))
      local b = select(1, footprint_cells(
        perfectworld.roads.way_footprint(backwards, 1, #backwards, width), 1, #backwards))
      local only_a, only_b = 0, 0
      for key in pairs(a) do if not b[key] then only_a = only_a + 1 end end
      for key in pairs(b) do if not a[key] then only_b = only_b + 1 end end
      ctx.assert.equal(only_a + only_b, 0, string.format(
        "width %d: a way must not depend on which end it was walked from "
          .. "(%d cells only forwards, %d only backwards)", width, only_a, only_b))
    end
  end)
