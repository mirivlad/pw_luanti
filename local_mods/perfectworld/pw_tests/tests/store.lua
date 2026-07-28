-- tests/store.lua
-- Sharded persistence: the point of the change is that a write is local.

local T = luanti_testkit

local function store()
  return perfectworld.planner.store
end

-- Mod storage belongs to the mod that opened it, so this suite cannot read
-- pw_planner's storage directly. The store exposes a read-only window for it.
local function blob(kind, shard)
  return store().shard_blob(kind, shard)
end

T.register_test("perfectworld", "store_derives_the_shard_from_the_id", function(ctx)
  local s = store()
  ctx.assert.equal(s.shard_for("settlement_v1_p2_n3_1"), "p2_n3",
    "a settlement id names its region")
  ctx.assert.equal(s.shard_for("structure_v1_settlement_v1_p2_n3_1_1"), "p2_n3",
    "a structure lands in the same shard as its settlement")
  ctx.assert.equal(s.shard_for("settlement_v1_p2_n3_1_road_main_0"), "p2_n3",
    "so does a road belonging to it")
  ctx.assert.equal(s.shard_for("road_anchor_v1_n10_p0_2"), "n10_p0",
    "negative coordinates keep their tags")
  ctx.assert.equal(s.shard_for("something_without_a_region"), "misc",
    "an id with no region tag still has somewhere to live")
end)

T.register_test("perfectworld", "writing_one_region_leaves_the_others_untouched", function(ctx)
  -- This is the whole reason the storage layer was changed. Before sharding,
  -- saving one structure rewrote every settlement, structure and road in the
  -- world, so the cost of a small change grew with the size of the world. A
  -- test that only checked the records could still be read back would have
  -- passed just as happily against the old layout.
  local s = store()
  local here = "settlement_v1_p600_p600_1"
  local far = "settlement_v1_p700_p700_1"

  s.put("settlements", here, {marker = "here"})
  s.put("settlements", far, {marker = "far"})

  local far_before = blob("settlements", "p700_p700")
  ctx.assert.is_true(far_before ~= "", "the far region must have been written")

  s.put("settlements", here, {marker = "here", changed = true})

  ctx.assert.equal(blob("settlements", "p700_p700"), far_before,
    "writing one region must not rewrite another")
  ctx.assert.equal(s.get("settlements", here).changed, true, "the change landed")
  ctx.assert.equal(s.get("settlements", far).marker, "far", "the neighbour survived")

  s.delete("settlements", here)
  s.delete("settlements", far)
end)

T.register_test("perfectworld", "records_survive_the_round_trip_across_shards", function(ctx)
  local s = store()
  local ids = {
    "settlement_v1_p610_p610_1",
    "settlement_v1_p610_p610_2",
    "settlement_v1_n611_p611_1",
  }
  for index, id in ipairs(ids) do
    s.put("settlements", id, {index = index})
  end
  s.drop_cache()

  local listed = {}
  for _, id in ipairs(s.ids("settlements")) do listed[id] = true end
  for index, id in ipairs(ids) do
    ctx.assert.is_true(listed[id], id .. " must be listed after a cache drop")
    local record = s.get("settlements", id)
    ctx.assert.equal(record and record.index, index, id .. " must read back intact")
  end

  for _, id in ipairs(ids) do s.delete("settlements", id) end
  s.drop_cache()
  for _, id in ipairs(ids) do
    ctx.assert.equal(s.get("settlements", id), nil, id .. " must be gone after delete")
  end
end)

T.register_test("perfectworld", "migration_moves_a_flat_map_into_shards", function(ctx)
  -- Worlds generated before this change hold one flat `id -> record` map per
  -- kind. The migration has to move every record without losing any and
  -- without needing the world to be regenerated.
  local s = store()
  local records = {
    ["structure_v1_settlement_v1_p620_p620_1_1"] = {marker = "a"},
    ["structure_v1_settlement_v1_p620_p620_1_2"] = {marker = "b"},
    ["structure_v1_settlement_v1_n621_p621_1_1"] = {marker = "c"},
  }
  s._test_seed_legacy("structures", records)

  local from, moved = s.migrate()
  ctx.assert.equal(from, 1, "must have seen the old format")
  ctx.assert.is_true(moved >= 3, "must have moved at least the three test records")

  for id, record in pairs(records) do
    local read_back = s.get("structures", id)
    ctx.assert.equal(read_back and read_back.marker, record.marker,
      id .. " must survive migration")
  end
  ctx.assert.equal(s._test_legacy_blob("structures"), "",
    "the flat map must be cleared once its records are sharded")
  ctx.assert.equal(s.format_version(), s.FORMAT_VERSION,
    "the format version must be recorded so migration does not run again")

  local _, again = s.migrate()
  ctx.assert.equal(again, 0, "a second migration must be a no-op")

  for id, _ in pairs(records) do s.delete("structures", id) end
end)

T.register_test("perfectworld", "planner_persistence_still_answers_across_shards", function(ctx)
  -- The public API did not change. This checks it through the planner rather
  -- than through the store, because that is what every caller uses.
  local a = "settlement_v1_p630_p630_1"
  local b = "settlement_v1_n631_n631_1"

  perfectworld.planner.save_settlement_plan(a, {settlement_id = a, lots = {}})
  perfectworld.planner.save_settlement_plan(b, {settlement_id = b, lots = {}})
  perfectworld.planner.mark_placed(a)

  ctx.assert.equal(perfectworld.planner.get_settlement_plan(a).settlement_id, a,
    "plan a reads back")
  ctx.assert.equal(perfectworld.planner.get_settlement_plan(b).settlement_id, b,
    "plan b reads back from a different shard")
  ctx.assert.is_true(perfectworld.planner.is_placed(a), "a is marked placed")
  ctx.assert.is_true(not perfectworld.planner.is_placed(b), "b is not")

  local listed = {}
  for _, id in ipairs(perfectworld.planner.list_settlements()) do listed[id] = true end
  ctx.assert.is_true(listed[a] and listed[b], "both settlements must be listed")

  perfectworld.planner._test_clear_settlement(a)
  perfectworld.planner._test_clear_settlement(b)
  perfectworld.planner._test_unmark_placed(a)
end)
