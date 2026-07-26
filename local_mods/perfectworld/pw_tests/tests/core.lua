-- tests/core.lua
-- PerfectWorld core module tests

local T = luanti_testkit

T.register_test("perfectworld", "version_returns_string", function(ctx)
  local v = perfectworld.get_version()
  ctx.assert.not_nil(v, "version must not be nil")
  ctx.assert.is_true(type(v) == "string", "version must be string, got " .. type(v))
end)

T.register_test("perfectworld", "region_coords_positive", function(ctx)
  local rx, rz = perfectworld.get_region_coords({x = 500, y = 0, z = 500})
  ctx.assert.equal(rx, 0, "region x for 500 must be 0, got " .. tostring(rx))
  ctx.assert.equal(rz, 0, "region z for 500 must be 0, got " .. tostring(rz))
end)

T.register_test("perfectworld", "region_coords_negative", function(ctx)
  local rx, rz = perfectworld.get_region_coords({x = -1, y = 0, z = -1})
  ctx.assert.equal(rx, -1, "region x for -1 must be -1, got " .. tostring(rx))
  ctx.assert.equal(rz, -1, "region z for -1 must be -1, got " .. tostring(rz))
end)

T.register_test("perfectworld", "region_coords_negative_exact", function(ctx)
  -- -1024 is exactly at region boundary
  local rx, rz = perfectworld.get_region_coords({x = -1024, y = 0, z = -1024})
  ctx.assert.equal(rx, -1, "region x for -1024 must be -1, got " .. tostring(rx))
  ctx.assert.equal(rz, -1, "region z for -1024 must be -1, got " .. tostring(rz))
end)

T.register_test("perfectworld", "region_coords_negative_below", function(ctx)
  -- -1025 is in the next negative region
  local rx, rz = perfectworld.get_region_coords({x = -1025, y = 0, z = -1025})
  ctx.assert.equal(rx, -2, "region x for -1025 must be -2, got " .. tostring(rx))
  ctx.assert.equal(rz, -2, "region z for -1025 must be -2, got " .. tostring(rz))
end)

T.register_test("perfectworld", "region_coords_zero_boundary", function(ctx)
  local rx, rz = perfectworld.get_region_coords({x = 0, y = 0, z = 0})
  ctx.assert.equal(rx, 0, "region x for 0 must be 0")
  ctx.assert.equal(rz, 0, "region z for 0 must be 0")
end)

T.register_test("perfectworld", "region_coords_upper_boundary", function(ctx)
  local rx, rz = perfectworld.get_region_coords({x = 1023, y = 0, z = 1023})
  ctx.assert.equal(rx, 0, "region x for 1023 must be 0, got " .. tostring(rx))
end)

T.register_test("perfectworld", "region_coords_next_region", function(ctx)
  local rx, rz = perfectworld.get_region_coords({x = 1024, y = 0, z = 1024})
  ctx.assert.equal(rx, 1, "region x for 1024 must be 1, got " .. tostring(rx))
end)

T.register_test("perfectworld", "region_id_format", function(ctx)
  local id = perfectworld.get_region_id(0, 0)
  ctx.assert.contains(id, "region_", "region id must use region_ prefix, got " .. id)
  local same = perfectworld.get_region_id(0, 0)
  local other = perfectworld.get_region_id(-1, 5)
  ctx.assert.equal(id, same, "same region id must be stable")
  ctx.assert.is_true(id ~= other, "different region ids must differ")
end)

T.register_test("perfectworld", "region_seed_stable", function(ctx)
  local s1 = perfectworld.region_seed(0, 0)
  local s2 = perfectworld.region_seed(0, 0)
  ctx.assert.equal(s1, s2, "region_seed must be identical for same region")
end)

T.register_test("perfectworld", "region_seed_different", function(ctx)
  local s1 = perfectworld.region_seed(0, 0)
  local s2 = perfectworld.region_seed(1, 0)
  ctx.assert.is_true(s1 ~= s2, "region_seed must differ for different regions")
end)

T.register_test("perfectworld", "region_seed_not_colliding_simple", function(ctx)
  local s_0_1 = perfectworld.region_seed(0, 1)
  local s_1_0 = perfectworld.region_seed(1, 0)
  ctx.assert.is_true(s_0_1 ~= s_1_0, "region_seed (0,1) and (1,0) must differ (avoid sum collision)")
end)

T.register_test("perfectworld", "structures_list_returns_registered_names", function(ctx)
  local list = perfectworld.structures.list()
  ctx.assert.not_nil(list, "list must not be nil (got nil)")
  ctx.assert.is_true(type(list) == "table", "list must be a table")
  ctx.assert.contains(table.concat(list, ","), "pw_farmstead_v1", "pw_farmstead_v1 must be registered")
end)

T.register_test("perfectworld", "structures_get_registered", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  ctx.assert.not_nil(def, "pw_farmstead_v1 must be registered")
  ctx.assert.not_nil(def.size, "structure must have size")
  ctx.assert.is_true(def.size.x >= 1, "size.x must be >= 1")
end)

T.register_test("perfectworld", "structures_get_returns_copy", function(ctx)
  local def = perfectworld.structures.get("pw_farmstead_v1")
  ctx.assert.not_nil(def, "pw_farmstead_v1 must be registered")
  def.size.x = 9999
  local again = perfectworld.structures.get("pw_farmstead_v1")
  ctx.assert.is_true(again.size.x ~= 9999, "structure definitions must be returned as copies")
end)
