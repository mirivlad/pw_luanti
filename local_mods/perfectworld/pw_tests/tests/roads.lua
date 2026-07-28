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
