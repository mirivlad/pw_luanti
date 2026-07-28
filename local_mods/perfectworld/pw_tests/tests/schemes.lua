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
  ctx.assert.is_true(#ids >= 50,
    "the catalogue should carry at least 50 schemes, has " .. #ids)

  local styles = perfectworld.schemes.list_styles()
  ctx.assert.is_true(#styles >= 5, "at least five styles, has " .. #styles)

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
  -- The families are the seven `pw_compat_mcl` actually reports — cold, coastal,
  -- dry, forest, rocky, temperate, wet. Naming any other here would make this
  -- test agree with a style list that is equally wrong, which is how the
  -- invented families survived registration in the first place.
  local cold = {}
  for _, id in ipairs(perfectworld.schemes.styles_for_biome("cold")) do cold[id] = true end
  ctx.assert.is_true(cold["nordic"], "nordic belongs in the cold")
  ctx.assert.is_true(not cold["japanese"], "japanese does not")

  local wet = {}
  for _, id in ipairs(perfectworld.schemes.styles_for_biome("wet")) do wet[id] = true end
  ctx.assert.is_true(wet["stilt"], "stilt belongs on wet ground")
  ctx.assert.is_true(not wet["nordic"], "nordic does not")

  local dry = {}
  for _, id in ipairs(perfectworld.schemes.styles_for_biome("dry")) do dry[id] = true end
  ctx.assert.is_true(dry["mediterranean"], "mediterranean belongs where it is dry")
  ctx.assert.is_true(not dry["stilt"], "stilt does not")

  -- The fallback names no biomes, so it is at home anywhere.
  for _, family in ipairs(perfectworld.compat.list_families()) do
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

-- === Integration with the planner ===========================================

local function planner_candidate(id, rx, rz, x, z)
  return {
    id = id, x = x, z = z, rx = rx, rz = rz,
    type = "village",
    structure_name = perfectworld.planner.COMPOSITE_MARKER,
    structure_id = id .. "_struct_0",
    rotation = 0,
    status = "candidate",
    region_id = perfectworld.get_region_id(rx, rz),
  }
end

local function planner_environment(family)
  return {
    biome_family = family,
    biome_name = family,
    roughness = 2,
    water_distance = 200,
    specialization = "farming",
    specialization_score = 1,
    ecology = {},
  }
end

T.register_test("perfectworld", "every_scheme_is_placeable_as_a_structure", function(ctx)
  -- A scheme the planner cannot see is a scheme that does not exist. This is
  -- the bridge: each one registered as an ordinary structure definition, so the
  -- terrain analysis, rotation, plinth, rollback and reachability machinery
  -- applies to it unchanged.
  local missing = {}
  for _, id in ipairs(perfectworld.schemes.list()) do
    local def = perfectworld.structures.get(id)
    if not def then
      missing[#missing + 1] = id
    else
      if #(def.rotations or {}) ~= 4 then
        missing[#missing + 1] = id .. " (rotations)"
      end
      if not (def.terrain and def.terrain.building_footprint) then
        missing[#missing + 1] = id .. " (no building footprint)"
      end
      if not (def.placement and def.placement.generator) then
        missing[#missing + 1] = id .. " (no generator)"
      end
    end
  end
  ctx.assert.equal(#missing, 0,
    "schemes not registered as structures: "
    .. table.concat(missing, ", ", 1, math.min(#missing, 4)))
end)

T.register_test("perfectworld", "a_village_is_composed_from_one_style", function(ctx)
  -- The integration test that matters. Everything else could pass with the
  -- wiring dead: the catalogue would exist, the builder would work, and
  -- villages would still be made of the ten old structures. This checks that a
  -- planned village actually names schemes, and names them from a single style.
  local mixed, styled = {}, 0
  for index = 1, 12 do
    local candidate = planner_candidate(
      "settlement_v1_p" .. index .. "_p" .. index .. "_1",
      index, index, index * 640, index * 512)
    local profile = perfectworld.planner.create_village_profile(
      candidate, planner_environment("temperate"))

    if profile.style then
      styled = styled + 1
      for role, variants in pairs(profile.role_variants or {}) do
        for _, name in ipairs(variants) do
          local scheme = perfectworld.schemes.get(name)
          if scheme and scheme.style ~= profile.style then
            mixed[#mixed + 1] = string.format("%s offers %s (%s) for %s in a %s village",
              candidate.id, name, scheme.style, role, profile.style)
          end
        end
      end
    end
  end
  ctx.assert.is_true(styled >= 10,
    "most villages should have been given a style, got " .. styled .. " of 12")
  ctx.assert.equal(#mixed, 0,
    "a village must not be offered another style's buildings: "
    .. table.concat(mixed, "; ", 1, math.min(#mixed, 3)))
end)

T.register_test("perfectworld", "villages_draw_dwellings_from_the_catalogue", function(ctx)
  -- Dwellings are the bulk of a village and were the whole of the complaint:
  -- four house shapes meant every village was the same village. If the bridge
  -- were wired but the role mapping were wrong, the profile would still carry
  -- the four legacy houses and nobody would notice.
  local from_catalogue, legacy = 0, 0
  for index = 1, 8 do
    local candidate = planner_candidate(
      "settlement_v1_n" .. index .. "_p" .. index .. "_1",
      -index, index, -index * 640, index * 512)
    local profile = perfectworld.planner.create_village_profile(
      candidate, planner_environment("temperate"))
    for _, name in ipairs((profile.role_variants or {}).dwelling or {}) do
      if perfectworld.schemes.get(name) then
        from_catalogue = from_catalogue + 1
      else
        legacy = legacy + 1
      end
    end
  end
  ctx.assert.is_true(from_catalogue > 0,
    "villages must draw dwellings from the scheme catalogue")
  ctx.assert.equal(legacy, 0,
    "a styled village should not be offered the pre-catalogue houses, got " .. legacy)
end)

T.register_test("perfectworld", "styles_name_biome_families_that_exist", function(ctx)
  -- A style that names a family the game does not have is never chosen, and
  -- nothing says so. Four of the five styles shipped with invented families —
  -- taiga, tundra, jungle, swamp, desert, savanna, mesa — none of which
  -- `pw_compat_mcl` knows, so every village came out vernacular while the
  -- catalogue looked like it was working.
  --
  -- Same shape as the defect that once made every biome resolve to temperate
  -- and killed the palette system: a name that does not match is silence.
  local known = {}
  for _, family in ipairs(perfectworld.compat.list_families()) do
    known[family] = true
  end
  ctx.assert.is_true(next(known) ~= nil, "the game must report some biome families")

  local invented = {}
  for _, id in ipairs(perfectworld.schemes.list_styles()) do
    local style = perfectworld.schemes.get_style(id)
    for _, family in ipairs(style.biomes or {}) do
      if not known[family] then
        invented[#invented + 1] = id .. " names '" .. family .. "'"
      end
    end
  end
  ctx.assert.equal(#invented, 0,
    "styles naming biome families that do not exist: "
    .. table.concat(invented, ", ", 1, math.min(#invented, 5)))
end)

T.register_test("perfectworld", "every_biome_family_builds_beyond_the_fallback", function(ctx)
  -- Vernacular is available everywhere, so a broken biome list still leaves
  -- every family with buildings — which is exactly why the previous defect was
  -- invisible. A world where the fallback is the only style anywhere has a
  -- catalogue of five styles and the variety of one.
  local bare = {}
  for _, family in ipairs(perfectworld.compat.list_families()) do
    local others = 0
    for _, id in ipairs(perfectworld.schemes.styles_for_biome(family)) do
      if id ~= "vernacular" then others = others + 1 end
    end
    if others == 0 then bare[#bare + 1] = family end
  end
  ctx.assert.equal(#bare, 0,
    "these families can only ever build the fallback style: "
    .. table.concat(bare, ", "))
end)

T.register_test("perfectworld", "production_roles_are_filled_by_buildings_of_that_trade", function(ctx)
  -- The worksite anchors to the lot holding the production role and never looks
  -- at what was built there, so any scheme *can* fill the role. That makes it
  -- worth checking that the ones which claim a trade are plausibly of it: a
  -- fishery that turns out to be a bakehouse passes every geometric test and
  -- still reads as nonsense.
  local expectations = {
    fishery = {"barrel", "hearth", "workbench"},
    mine_workshop = {"anvil", "hearth"},
    sawmill = {"workbench"},
  }
  local wrong = {}
  for role, wanted in pairs(expectations) do
    local claimed = 0
    for _, style in ipairs(perfectworld.schemes.list_styles()) do
      for _, id in ipairs(perfectworld.schemes.for_role(style, role)) do
        claimed = claimed + 1
        local scheme = perfectworld.schemes.get(id)
        local has = {}
        for _, fixture in ipairs(scheme.interior or {}) do has[fixture] = true end
        local matched = false
        for _, fixture in ipairs(wanted) do
          if has[fixture] then matched = true break end
        end
        if not matched then
          wrong[#wrong + 1] = id .. " claims " .. role .. " with no "
            .. table.concat(wanted, "/")
        end
      end
    end
    ctx.assert.is_true(claimed > 0, "no scheme claims the " .. role .. " role")
  end
  ctx.assert.equal(#wrong, 0, table.concat(wrong, "; ", 1, math.min(#wrong, 3)))
end)

T.register_test("perfectworld", "a_style_without_a_trade_falls_back_rather_than_failing", function(ctx)
  -- Not every style has a fish house, and it must not be forced to invent one.
  -- The contract is that `variants_for` returns nil for a role the style cannot
  -- fill, which leaves the specialization's own structure in place — a plain
  -- building rather than a missing one.
  local style_without = nil
  for _, style in ipairs(perfectworld.schemes.list_styles()) do
    if #perfectworld.schemes.for_role(style, "fishery") == 0 then
      style_without = style
      break
    end
  end
  if not style_without then
    ctx.skip("every style now offers a fishery; nothing to fall back from")
    return
  end
  ctx.assert.equal(perfectworld.schemes.variants_for(style_without, "fishery"), nil,
    style_without .. " has no fishery and must not claim to")
  ctx.assert.not_nil(perfectworld.schemes.variants_for(style_without, "dwelling"),
    "but it must still offer the roles it does have")
end)

T.register_test("perfectworld", "a_forestry_village_is_offered_a_sawmill_from_the_catalogue", function(ctx)
  -- The production roles go through `create_village_profile`, not through
  -- `variants_for` directly, and the two could disagree: the profile consults
  -- the catalogue for the roles the specialization named plus the ones its
  -- composition asks for. This walks the real path.
  --
  -- Three candidates, close in. An earlier version used two dozen at far-flung
  -- coordinates and made the server work hard enough emerging ground that the
  -- bot brain's freshness test, several suites later, started reporting its
  -- intent as stale. A test that breaks another test by being expensive is
  -- measuring the machine, not the code.
  --
  -- Checked at plan level because the development world has no unbuilt village
  -- candidates left: every settlement in it is placed, so nothing new is
  -- materialized there to look at.
  local from_catalogue = {}
  for index = 1, 3 do
    local candidate = {
      id = "settlement_v1_p" .. (40 + index) .. "_n" .. index .. "_1",
      x = index * 96, z = -index * 96, rx = 40 + index, rz = -index,
      type = "village",
      structure_name = perfectworld.planner.COMPOSITE_MARKER,
      structure_id = "sawmill_probe_" .. index,
      rotation = 0, status = "candidate",
      region_id = perfectworld.get_region_id(40 + index, -index),
    }
    local profile = perfectworld.planner.create_village_profile(candidate, {
      biome_family = "forest",
      biome_name = "forest",
      roughness = 2,
      water_distance = 200,
      specialization = "forestry",
      specialization_score = 1,
      ecology = {},
    })
    for _, name in ipairs((profile.role_variants or {}).sawmill or {}) do
      if perfectworld.schemes.get(name) then from_catalogue[name] = true end
    end
  end

  local names = {}
  for name, _ in pairs(from_catalogue) do names[#names + 1] = name end
  table.sort(names)
  ctx.assert.is_true(#names > 0,
    "a forestry village should be offered a sawmill from the catalogue")
  ctx.log("sawmills offered from the catalogue: " .. table.concat(names, ", "))
end)
