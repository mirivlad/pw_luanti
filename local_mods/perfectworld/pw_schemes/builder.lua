-- pw_schemes/builder.lua
--
-- One builder for every scheme. It reads the scheme's description and the
-- style's proportions and raises the building; no scheme carries code.
--
-- The order matters and is not arbitrary. Terrain preparation has already
-- happened by the time this runs, so the first thing to do is clear the volume
-- the building will occupy — otherwise leftovers from that preparation end up
-- sealed inside the walls. Then floor, walls, openings, roof, and last the
-- interior, which needs the room to exist before it can be furnished.

local schemes = perfectworld.schemes
local put, put_facing, fill = schemes.put, schemes.put_facing, schemes.fill

--- Window columns along a wall run: spaced, never in a corner, never in the
--- door's column.
local function window_columns(span, skip, spacing)
  spacing = spacing or 2
  local out = {}
  for value = -span + 1, span - 1 do
    if value ~= skip and (value + span) % spacing == 0 then
      out[#out + 1] = value
    end
  end
  return out
end

schemes.window_columns = window_columns

--- Materials a scheme needs, resolved once through style then palette.
local function materials(style, palette)
  local m = schemes.material
  return {
    wall = m(style, palette, "wall_primary", "wall"),
    base = m(style, palette, "wall_secondary", "foundation"),
    post = m(style, palette, "wall_post", "tree"),
    floor = m(style, palette, "floor_block", "floor"),
    stair = m(style, palette, "roof_stair", "roof"),
    slab = m(style, palette, "roof_slab", "roof"),
    window = m(style, palette, "window", "window"),
    fence = m(style, palette, "fence", "fence"),
    door = perfectworld.compat.get_material("door", {required = false}),
    door_top = perfectworld.compat.get_material("door_top", {required = false}),
  }
end

--- Raise one scheme at `origin`, turned by `rotation`.
--
-- Returns true, or false and a reason. It never half-builds on purpose: the
-- caller's rollback handles a failure part-way, and this returns false only for
-- things it can see before writing a node.
function schemes.build(scheme, context)
  if type(scheme) == "string" then scheme = schemes.get(scheme) end
  if not scheme then return false, "no such scheme" end

  local origin = context.prepared_position or context.pos
  local rotation = context.rotation or 0
  local palette = context.palette
  local style = schemes.get_style(scheme.style)
  local mat = materials(style, palette)

  local half_w = math.floor(scheme.footprint.w / 2)
  local half_d = math.floor(scheme.footprint.d / 2)
  local height = scheme.wall_height
  local raise = scheme.raised_floor or 0
  local door_x = scheme.door and scheme.door.offset or 0
  local floor_y = raise

  -- The volume, cleared. Everything below is written into known-empty space.
  fill(origin, rotation, {x = -half_w, y = floor_y + 1, z = -half_d},
    {x = half_w, y = floor_y + height + 1, z = half_d}, "air")

  fill(origin, rotation, {x = -half_w, y = floor_y, z = -half_d},
    {x = half_w, y = floor_y, z = half_d}, mat.floor)

  if raise == 0 then
    -- A solid course under the floor, so nothing stands on air once the plinth
    -- has been carried down by terrain preparation.
    fill(origin, rotation, {x = -half_w, y = floor_y - 1, z = -half_d},
      {x = half_w, y = floor_y - 1, z = half_d}, mat.base)
  else
    -- A raised floor stands on posts over open air. Filling under it would put
    -- the building on a mound, which is a different building: the gap is the
    -- whole point of raising it, both for damp ground and for the look.
    fill(origin, rotation, {x = -half_w + 1, y = 0, z = -half_d + 1},
      {x = half_w - 1, y = floor_y - 1, z = half_d - 1}, "air")
  end

  if raise > 0 then
    for _, corner in ipairs({
      {x = -half_w, z = -half_d}, {x = half_w, z = -half_d},
      {x = -half_w, z = half_d}, {x = half_w, z = half_d},
    }) do
      for y = 0, floor_y - 1 do
        put(origin, rotation, {x = corner.x, y = y, z = corner.z}, mat.post)
      end
    end
  end

  -- Walls, with the lowest course in the secondary material when the scheme
  -- asks for a plinth.
  for y = floor_y + 1, floor_y + height do
    local course = mat.wall
    if scheme.plinth ~= false and y == floor_y + 1 then course = mat.base end
    for x = -half_w, half_w do
      put(origin, rotation, {x = x, y = y, z = -half_d}, course)
      put(origin, rotation, {x = x, y = y, z = half_d}, course)
    end
    for z = -half_d + 1, half_d - 1 do
      put(origin, rotation, {x = -half_w, y = y, z = z}, course)
      put(origin, rotation, {x = half_w, y = y, z = z}, course)
    end
  end

  -- Timber corner posts, full height. They are what stops a plank box from
  -- reading as a plank box.
  if scheme.posts ~= false then
    for y = floor_y + 1, floor_y + height do
      for _, corner in ipairs({
        {x = -half_w, z = -half_d}, {x = half_w, z = -half_d},
        {x = -half_w, z = half_d}, {x = half_w, z = half_d},
      }) do
        put(origin, rotation, {x = corner.x, y = y, z = corner.z}, mat.post)
      end
    end
  end

  -- Windows. `rows` counts them up from the course above the plinth.
  local rows = scheme.windows and scheme.windows.rows or 1
  if rows > 0 and mat.window ~= "air" then
    local spacing = scheme.windows and scheme.windows.spacing or 2
    for row = 1, math.min(rows, height - 1) do
      local y = floor_y + 1 + row
      for _, x in ipairs(window_columns(half_w, door_x, spacing)) do
        put(origin, rotation, {x = x, y = y, z = half_d}, mat.window)
        put(origin, rotation, {x = x, y = y, z = -half_d}, mat.window)
      end
      for _, z in ipairs(window_columns(half_d, nil, spacing)) do
        put(origin, rotation, {x = -half_w, y = y, z = z}, mat.window)
        put(origin, rotation, {x = half_w, y = y, z = z}, mat.window)
      end
    end
  end

  -- The doorway, on the +z wall, which is the side the street is on.
  local wide = scheme.door and scheme.door.wide
  local reach = wide and 1 or 0
  for dx = -reach, reach do
    put(origin, rotation, {x = door_x + dx, y = floor_y + 1, z = half_d}, "air")
    put(origin, rotation, {x = door_x + dx, y = floor_y + 2, z = half_d}, "air")
    if wide and height >= 4 then
      put(origin, rotation, {x = door_x + dx, y = floor_y + 3, z = half_d}, "air")
    end
  end
  if not wide and mat.door then
    put_facing(origin, rotation, {x = door_x, y = floor_y + 1, z = half_d},
      mat.door, {x = 0, y = 0, z = 1})
    put_facing(origin, rotation, {x = door_x, y = floor_y + 2, z = half_d},
      mat.door_top, {x = 0, y = 0, z = 1})
  end

  -- The doorstep, and a second step clear of the eaves. The connector sits on
  -- the outer one, so nothing overhangs the point a walker aims for.
  local overhang = math.max(scheme.roof.eaves or 1, 1)
  for dz = 1, overhang + 1 do
    put(origin, rotation, {x = door_x, y = floor_y, z = half_d + dz}, mat.base)
    put(origin, rotation, {x = door_x, y = floor_y + 1, z = half_d + dz}, "air")
    put(origin, rotation, {x = door_x, y = floor_y + 2, z = half_d + dz}, "air")
  end

  -- A veranda: a floor deck running along the front, under the eaves. It is
  -- what makes a wide-eaved building look inhabited rather than merely shaded.
  if scheme.veranda then
    for x = -half_w, half_w do
      for dz = 1, overhang do
        put(origin, rotation, {x = x, y = floor_y, z = half_d + dz}, mat.floor)
        put(origin, rotation, {x = x, y = floor_y + 1, z = half_d + dz}, "air")
      end
    end
  end

  -- Ceiling, then the roof on top of it.
  fill(origin, rotation,
    {x = -half_w + 1, y = floor_y + height + 1, z = -half_d + 1},
    {x = half_w - 1, y = floor_y + height + 1, z = half_d - 1}, mat.floor)

  local roof_kind = scheme.roof.kind
  local build_roof = schemes.ROOFS[roof_kind]
  if not build_roof then return false, "unknown roof kind " .. tostring(roof_kind) end
  build_roof({
    origin = origin, rotation = rotation,
    half_w = half_w, half_d = half_d,
    base_y = floor_y + height + 1,
    stair = mat.stair, slab = mat.slab, gable = mat.wall,
    pitch = scheme.roof.pitch or (style and style.roof and style.roof.pitch) or 1,
    eaves = scheme.roof.eaves or (style and style.roof and style.roof.eaves) or 1,
    parapet = scheme.roof.parapet,
  })

  if scheme.interior and #scheme.interior > 0 then
    schemes.furnish(scheme, {
      origin = origin, rotation = rotation, palette = palette, style = style,
      materials = mat, half_w = half_w, half_d = half_d,
      floor_y = floor_y, height = height, door_x = door_x,
      -- Which trade this house is for. Decided by the settlement, not the
      -- scheme, so one dwelling design serves a fishing village and a mining
      -- one and furnishes differently in each.
      trade = context.trade,
    })
  end

  return true
end
