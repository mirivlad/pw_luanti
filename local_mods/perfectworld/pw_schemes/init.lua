-- pw_schemes/init.lua
--
-- Buildings as data, grouped into architectural styles.
--
-- Until now every building was a Lua generator, and all of them called one
-- shared function with slightly different numbers. Ten structures that were the
-- same house in different wood. Adding a shape meant writing a generator;
-- adding a *style* was not expressible at all.
--
-- A scheme here is a table describing a building: its footprint, how tall its
-- walls are, what kind of roof it carries, where its door is, what furniture
-- belongs inside, and which roles it can fill in a village. A style is a set of
-- schemes plus the proportions and materials they share. One builder reads both
-- and raises the thing.
--
-- Why data and not `.mts` schematics, which would have been quicker to bulk up:
--
--   * a schematic bakes node names, and this project spent a whole cycle
--     fixing exactly that — palettes existed but were never passed to the
--     generator, so every village was oak regardless of biome. A scheme names
--     *roles* (wall_primary, roof_stair, floor_block) and the palette dresses
--     them per biome and per style;
--   * a schematic carries no terrain contract, no connectors, no door side and
--     no interior roles, and those are what the planner actually needs;
--   * a schematic is opaque to tests. The roof that came out looking like a row
--     of combs was caught by a test asserting on the `param2` of every stair.
--     That test cannot be written against a blob.
--
-- A settlement picks one style, deterministically, and builds only from it.
-- That is what makes a village look like one village rather than a sample book.

perfectworld = perfectworld or {}
perfectworld.schemes = perfectworld.schemes or {}

local modpath = minetest.get_modpath("pw_schemes")
local deep_copy = perfectworld.core.deep_copy
local rotate_point = perfectworld.structures.rotate_point
local palette_material = perfectworld.structures.palette_material

local schemes = {}
local styles = {}

-- === Placement helpers =======================================================
--
-- Local space is the scheme's own: +z is the front, where the door and the
-- street are. Rotation is applied on the way out so a scheme never has to know
-- which way the building ended up facing.

local function world_of(origin, rotation, local_pos)
  local turned = rotate_point(local_pos, rotation)
  return {
    x = origin.x + turned.x,
    y = origin.y + turned.y,
    z = origin.z + turned.z,
  }
end

local function put(origin, rotation, local_pos, node_name, param2)
  if node_name == nil or node_name == "" then return end
  minetest.set_node(world_of(origin, rotation, local_pos),
    {name = node_name, param2 = param2 or 0})
end

--- Place a node whose facing is given in the scheme's own space.
--
-- The direction is where the node's +Z face ends up, because that is what
-- `dir_to_facedir` means. For a stair, param2 0 puts the raised half at +Z, so
-- this is the direction the step *rises*, not the way it falls. Getting that
-- backwards is invisible in a unit test and obvious on a roof.
local function put_facing(origin, rotation, local_pos, node_name, local_dir)
  if node_name == nil or node_name == "" or node_name == "air" then return end
  local dir = rotate_point(local_dir, rotation)
  put(origin, rotation, local_pos, node_name,
    minetest.dir_to_facedir({x = dir.x, y = 0, z = dir.z}))
end

local function fill(origin, rotation, from, to, node_name)
  if node_name == nil then return end
  for x = math.min(from.x, to.x), math.max(from.x, to.x) do
    for y = math.min(from.y, to.y), math.max(from.y, to.y) do
      for z = math.min(from.z, to.z), math.max(from.z, to.z) do
        put(origin, rotation, {x = x, y = y, z = z}, node_name)
      end
    end
  end
end

perfectworld.schemes.put = put
perfectworld.schemes.put_facing = put_facing
perfectworld.schemes.fill = fill

-- === Registry ================================================================

--- Fields a scheme must carry, with what each one means.
--
-- Validation is deliberately strict. A scheme with a missing footprint is a
-- building-shaped hole in a village, and the failure shows up as a planner
-- rejection three layers away from the typo that caused it.
local REQUIRED = {"id", "style", "roles", "footprint", "wall_height", "roof"}

local function fail(id, message)
  return false, string.format("scheme %s: %s", tostring(id), message)
end

function perfectworld.schemes.validate(scheme)
  if type(scheme) ~= "table" then return false, "scheme must be a table" end
  for _, field in ipairs(REQUIRED) do
    if scheme[field] == nil then return fail(scheme.id, "missing " .. field) end
  end
  local f = scheme.footprint
  if type(f) ~= "table" or type(f.w) ~= "number" or type(f.d) ~= "number" then
    return fail(scheme.id, "footprint needs numeric w and d")
  end
  -- Odd widths only. The builder works from a centre outwards, so an even
  -- footprint would have no middle column for a door or a ridge to sit on.
  if f.w % 2 == 0 or f.d % 2 == 0 then
    return fail(scheme.id, "footprint w and d must be odd, got "
      .. f.w .. "x" .. f.d)
  end
  if f.w < 3 or f.d < 3 then return fail(scheme.id, "footprint must be at least 3x3") end
  if type(scheme.roles) ~= "table" or #scheme.roles == 0 then
    return fail(scheme.id, "roles must be a non-empty list")
  end
  if type(scheme.wall_height) ~= "number" or scheme.wall_height < 2 then
    return fail(scheme.id, "wall_height must be at least 2")
  end
  local roof = scheme.roof
  if type(roof) ~= "table" or type(roof.kind) ~= "string" then
    return fail(scheme.id, "roof needs a kind")
  end
  if not perfectworld.schemes.ROOFS[roof.kind] then
    return fail(scheme.id, "unknown roof kind " .. roof.kind)
  end
  return true
end

function perfectworld.schemes.register(scheme)
  local ok, err = perfectworld.schemes.validate(scheme)
  if not ok then
    minetest.log("error", "[pw_schemes] " .. tostring(err))
    return false, err
  end
  if schemes[scheme.id] then
    return fail(scheme.id, "already registered")
  end
  schemes[scheme.id] = deep_copy(scheme)
  return true
end

function perfectworld.schemes.get(id)
  local scheme = schemes[id]
  return scheme and deep_copy(scheme) or nil
end

function perfectworld.schemes.list()
  local ids = {}
  for id, _ in pairs(schemes) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

--- Every scheme of a style that can fill a role, in a stable order.
--
-- Sorted, because the caller picks from this list by hash and an unstable order
-- would make the same seed build different villages.
function perfectworld.schemes.for_role(style_id, role)
  local out = {}
  for _, id in ipairs(perfectworld.schemes.list()) do
    local scheme = schemes[id]
    if scheme.style == style_id then
      for _, candidate in ipairs(scheme.roles) do
        if candidate == role then out[#out + 1] = id break end
      end
    end
  end
  return out
end

-- === Styles ==================================================================

function perfectworld.schemes.register_style(style)
  if type(style) ~= "table" or type(style.id) ~= "string" then
    return false, "style must be a table with an id"
  end
  styles[style.id] = deep_copy(style)
  return true
end

function perfectworld.schemes.get_style(id)
  local style = styles[id]
  return style and deep_copy(style) or nil
end

function perfectworld.schemes.list_styles()
  local ids = {}
  for id, _ in pairs(styles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

--- Which styles may appear in a biome family. A style with no `biomes` list is
--- at home anywhere, which is what the vernacular one is for.
function perfectworld.schemes.styles_for_biome(family)
  local out = {}
  for _, id in ipairs(perfectworld.schemes.list_styles()) do
    local style = styles[id]
    if not style.biomes then
      out[#out + 1] = id
    else
      for _, allowed in ipairs(style.biomes) do
        if allowed == family then out[#out + 1] = id break end
      end
    end
  end
  return out
end

--- The style a settlement is built in.
--
-- One decision, hashed from the settlement's own id, so the same seed always
-- produces the same village and adding a style elsewhere in the world does not
-- reshuffle the ones already built. A settlement that mixed styles would read
-- as a sample book rather than a place.
function perfectworld.schemes.style_for(settlement_id, biome_family)
  local candidates = perfectworld.schemes.styles_for_biome(biome_family)
  if #candidates == 0 then return nil end
  return perfectworld.core.choice.pick(tostring(settlement_id), "style", candidates)
end

--- Resolve a material role through the style first, then the biome palette.
--
-- A style may pin a material outright — a Japanese roof is dark tile whatever
-- grows nearby — or leave it to the palette, which is what keeps a vernacular
-- village made of the wood of its own forest.
function perfectworld.schemes.material(style, palette, role, fallback)
  if style and style.materials and style.materials[role] then
    local named = style.materials[role]
    if named == "air" or minetest.registered_nodes[named] then return named end
  end
  return palette_material(palette, role, fallback or role)
end

dofile(modpath .. "/roofs.lua")
dofile(modpath .. "/interior.lua")
dofile(modpath .. "/builder.lua")

for _, file in ipairs({"vernacular", "nordic", "japanese", "mediterranean", "stilt"}) do
  local ok, err = pcall(dofile, modpath .. "/styles/" .. file .. ".lua")
  if not ok then
    minetest.log("error", "[pw_schemes] style " .. file .. ": " .. tostring(err))
  end
end

minetest.log("action", string.format(
  "[pw_schemes] loaded: %d schemes across %d styles",
  #perfectworld.schemes.list(), #perfectworld.schemes.list_styles()))
