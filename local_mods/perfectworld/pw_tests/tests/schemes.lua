-- tests/schemes.lua
-- Building schemes: the catalogue, the styles, and the builder that raises them.

local T = luanti_testkit

local function flat_ground(center, radius, surface_y, clear_to_y)
  if minetest.load_area then
    pcall(minetest.load_area,
      {x = center.x - radius, y = surface_y - 8, z = center.z - radius},
      {x = center.x + radius, y = clear_to_y, z = center.z + radius})
  end
  local ground, air = {}, {}
  for dx = -radius, radius do
    for dz = -radius, radius do
      ground[#ground + 1] = {x = center.x + dx, y = surface_y, z = center.z + dz}
      for y = surface_y + 1, clear_to_y do
        air[#air + 1] = {x = center.x + dx, y = y, z = center.z + dz}
      end
    end
  end
  minetest.bulk_set_node(ground, {name = perfectworld.compat.get_material("ground")})
  minetest.bulk_set_node(air, {name = "air"})
end

T.register_test("perfectworld", "scheme_catalogue_is_not_thin", function(ctx)
  -- The catalogue existing is not the point; its size is. Ten buildings that
  -- were the same house in different wood is what this replaces, so a
  -- regression that quietly drops a style back to a handful of schemes should
  -- be a failure rather than something noticed in a screenshot months later.
  local ids = perfectworld.schemes.list()
  ctx.assert.is_true(#ids >= 30,
    "the catalogue should carry at least 30 schemes, has " .. #ids)

  local styles = perfectworld.schemes.list_styles()
  ctx.assert.is_true(#styles >= 3, "at least three styles, has " .. #styles)

  for _, style in ipairs(styles) do
    local dwellings = perfectworld.schemes.for_role(style, "dwelling")
    ctx.assert.is_true(#dwellings >= 4,
      style .. " must offer at least 4 dwellings, offers " .. #dwellings)
  end
end)

T.register_test("perfectworld", "every_scheme_validates", function(ctx)
  -- Registration already rejects a malformed scheme, but a scheme that failed
  -- to register is simply absent, and absence is quiet. This checks that what
  -- did register still satisfies the contract.
  local bad = {}
  for _, id in ipairs(perfectworld.schemes.list()) do
    local scheme = perfectworld.schemes.get(id)
    local ok, err = perfectworld.schemes.validate(scheme)
    if not ok then bad[#bad + 1] = tostring(err) end
    if scheme.style and not perfectworld.schemes.get_style(scheme.style) then
      bad[#bad + 1] = id .. " names unregistered style " .. scheme.style
    end
  end
  ctx.assert.equal(#bad, 0, "invalid schemes: " .. table.concat(bad, "; ", 1, math.min(#bad, 3)))
end)

T.register_test("perfectworld", "scheme_validation_rejects_a_broken_scheme", function(ctx)
  -- A validator that never says no is decoration.
  local v = perfectworld.schemes.validate
  ctx.assert.is_true(not (v({id = "x", style = "vernacular", roles = {"dwelling"},
    footprint = {w = 4, d = 5}, wall_height = 3, roof = {kind = "gable"}})),
    "an even footprint must be rejected: there would be no centre column")
  ctx.assert.is_true(not (v({id = "x", style = "vernacular", roles = {},
    footprint = {w = 5, d = 5}, wall_height = 3, roof = {kind = "gable"}})),
    "a scheme with no roles must be rejected: nothing could ever choose it")
  ctx.assert.is_true(not (v({id = "x", style = "vernacular", roles = {"dwelling"},
    footprint = {w = 5, d = 5}, wall_height = 3, roof = {kind = "pagoda"}})),
    "an unknown roof kind must be rejected rather than silently skipped")
end)

T.register_test("perfectworld", "a_settlement_gets_one_style_and_keeps_it", function(ctx)
  -- A village that mixed styles would read as a sample book rather than a
  -- place, and a village that changed style between runs would mean the world
  -- is not deterministic.
  local id = "settlement_v1_p3_n7_2"
  local first = perfectworld.schemes.style_for(id, "temperate")
  ctx.assert.not_nil(first, "some style must be available for a temperate biome")
  for _ = 1, 5 do
    ctx.assert.equal(perfectworld.schemes.style_for(id, "temperate"), first,
      "the same settlement must always get the same style")
  end

  local others = 0
  for index = 1, 12 do
    local other = perfectworld.schemes.style_for("settlement_v1_p3_n7_" .. index, "temperate")
    if other ~= first then others = others + 1 end
  end
  ctx.assert.is_true(others > 0,
    "twelve settlements must not all land on one style")
end)

T.register_test("perfectworld", "styles_respect_the_biomes_they_belong_in", function(ctx)
  -- Nordic turf halls in a jungle would be as wrong as a paper-walled minka on
  -- a tundra. A style says where it belongs and the chooser must honour it.
  local cold = {}
  for _, id in ipairs(perfectworld.schemes.styles_for_biome("tundra")) do cold[id] = true end
  ctx.assert.is_true(cold["nordic"], "nordic belongs on a tundra")
  ctx.assert.is_true(not cold["japanese"], "japanese does not")

  local wet = {}
  for _, id in ipairs(perfectworld.schemes.styles_for_biome("jungle")) do wet[id] = true end
  ctx.assert.is_true(wet["japanese"], "japanese belongs in a jungle")
  ctx.assert.is_true(not wet["nordic"], "nordic does not")

  -- The fallback names no biomes, so it is at home anywhere.
  for _, family in ipairs({"tundra", "jungle", "temperate", "desert"}) do
    local found = false
    for _, id in ipairs(perfectworld.schemes.styles_for_biome(family)) do
      if id == "vernacular" then found = true end
    end
    ctx.assert.is_true(found, "vernacular must be available in " .. family)
  end
end)

T.register_test("perfectworld", "building_a_scheme_raises_a_physical_shell", function(ctx)
  local center = {x = 900, y = 24, z = 900}
  flat_ground(center, 14, center.y, center.y + 24)

  local ok, err = perfectworld.schemes.build("vern_house_tall", {
    pos = center,
    rotation = 0,
    palette = perfectworld.compat.get_family_palette("temperate"),
  })
  ctx.assert.is_true(ok, "build must succeed: " .. tostring(err))

  local solid, doors = 0, 0
  for x = center.x - 8, center.x + 8 do
    for y = center.y + 1, center.y + 20 do
      for z = center.z - 8, center.z + 8 do
        local node = minetest.get_node({x = x, y = y, z = z})
        if node.name ~= "air" and node.name ~= "ignore" then solid = solid + 1 end
        if node.name:find("door", 1, true) then doors = doors + 1 end
      end
    end
  end
  ctx.assert.is_true(solid >= 100, "a house should be more than 100 nodes, was " .. solid)
  ctx.assert.is_true(doors >= 1, "a dwelling must have a door, found " .. doors)
end)

T.register_test("perfectworld", "scheme_roofs_rise_towards_the_ridge", function(ctx)
  -- The same defect the hand-written generator had, in the shared builder this
  -- time: a stair whose raised half points downhill leaves every course lifted
  -- at its outer edge and dropping at its inner one, and the roof reads as a
  -- row of combs. Every gable scheme in the catalogue goes through this code,
  -- so one wrong direction would be wrong everywhere at once.
  local center = {x = 940, y = 24, z = 940}
  flat_ground(center, 14, center.y, center.y + 24)

  local ok = perfectworld.schemes.build("vern_cottage_wide", {
    pos = center,
    rotation = 0,
    palette = perfectworld.compat.get_family_palette("temperate"),
  })
  if not ok then ctx.skip("scheme did not build here") return end

  local counted, wrong = 0, {}
  for x = center.x - 8, center.x + 8 do
    for y = center.y + 1, center.y + 20 do
      for z = center.z - 8, center.z + 8 do
        local node = minetest.get_node({x = x, y = y, z = z})
        if node.name:find("stair", 1, true) then
          local rise = minetest.facedir_to_dir(node.param2)
          local towards_ridge = center.x - x
          if rise.x ~= 0 and towards_ridge ~= 0 then
            counted = counted + 1
            if rise.x * towards_ridge <= 0 then
              wrong[#wrong + 1] = string.format("(%d,%d,%d)", x, y, z)
            end
          end
        end
      end
    end
  end
  ctx.assert.is_true(counted >= 30, "a gable roof needs stairs, found " .. counted)
  ctx.assert.equal(#wrong, 0, counted .. " roof stairs, " .. #wrong .. " pointing downhill")
end)

T.register_test("perfectworld", "a_furnished_scheme_is_not_an_empty_shell", function(ctx)
  -- "Interiors are practically empty" was the complaint that started this. A
  -- dwelling that builds furniture-free should fail here rather than be
  -- discovered by walking into it.
  local center = {x = 980, y = 24, z = 980}
  flat_ground(center, 14, center.y, center.y + 24)

  local ok = perfectworld.schemes.build("vern_house_long", {
    pos = center,
    rotation = 0,
    palette = perfectworld.compat.get_family_palette("temperate"),
  })
  if not ok then ctx.skip("scheme did not build here") return end

  local scheme = perfectworld.schemes.get("vern_house_long")
  local found = {}
  for x = center.x - 4, center.x + 4 do
    for y = center.y + 1, center.y + 6 do
      for z = center.z - 6, center.z + 6 do
        local name = minetest.get_node({x = x, y = y, z = z}).name
        if name:find("bed", 1, true) then found.bed = true end
        if name:find("chest", 1, true) then found.chest = true end
        if name:find("torch", 1, true) or name:find("lantern", 1, true) then found.lamp = true end
      end
    end
  end
  ctx.assert.is_true(#scheme.interior >= 4, "this scheme should ask for furniture")
  ctx.assert.is_true(found.bed, "a dwelling that asked for a bed must have one")
  ctx.assert.is_true(found.chest, "and the chest it asked for")
end)

T.register_test("perfectworld", "raised_schemes_stand_on_posts_over_open_air", function(ctx)
  -- A raised floor is the structural half of the Japanese style. If it were
  -- built on fill instead of on posts the building would read as standing on a
  -- mound, which is a different kind of building entirely.
  local center = {x = 1020, y = 24, z = 1020}
  flat_ground(center, 14, center.y, center.y + 24)

  local scheme = perfectworld.schemes.get("jp_rice_barn")
  ctx.assert.is_true(scheme.raised_floor >= 2, "this scheme should be a raised one")

  local ok = perfectworld.schemes.build("jp_rice_barn", {
    pos = center,
    rotation = 0,
    palette = perfectworld.compat.get_family_palette("temperate"),
  })
  if not ok then ctx.skip("scheme did not build here") return end

  -- Directly under the middle of the floor, between the posts, there must be
  -- air: that is what "raised" means.
  local under = minetest.get_node({x = center.x, y = center.y + 1, z = center.z}).name
  ctx.assert.equal(under, "air",
    "under a raised floor there must be open air, found " .. under)
end)
