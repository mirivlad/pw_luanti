-- pw_bot_bridge/canonical.lua
--
-- Canonical value representation.
--
-- The same world state and the same request must produce byte-identical JSON,
-- so nothing here may depend on the order `pairs` happens to walk a Lua table.
-- Object keys are emitted in lexicographic order, arrays keep the order the
-- producer chose, and every floating point number is rounded to a documented
-- number of decimal places before it is formatted.

local B = pw_bot_bridge
local canonical = {}
B.impl.canonical = canonical

--- Number of decimal places every non-integer keeps in a response.
canonical.ROUND_PLACES = 3

-- JSON `null`. Lua tables cannot store nil, so an explicit sentinel is the
-- only way to say "this field exists and is empty".
canonical.NULL = setmetatable({}, {__tostring = function() return "null" end})

-- An empty table is ambiguous: `{}` could be an object or an array. Producers
-- use this sentinel when they mean an empty array; a plain `{}` means an empty
-- object.
canonical.EMPTY_ARRAY = setmetatable({}, {__tostring = function() return "[]" end})

local POW10 = {[0] = 1, 10, 100, 1000, 10000, 100000, 1000000}

--- Round half away from zero to `places` decimals.
function canonical.round(value, places)
  local n = tonumber(value)
  if not n then return 0 end
  if n ~= n or n == math.huge or n == -math.huge then return 0 end
  places = places or canonical.ROUND_PLACES
  local scale = POW10[places] or 10 ^ places
  if n >= 0 then
    return math.floor(n * scale + 0.5) / scale
  end
  return -math.floor(-n * scale + 0.5) / scale
end

local round = canonical.round

--- Round a vector, keeping only x/y/z.
function canonical.vector(v, places)
  if type(v) ~= "table" then return canonical.NULL end
  return {
    x = round(v.x or 0, places),
    y = round(v.y or 0, places),
    z = round(v.z or 0, places),
  }
end

--- Integer node coordinates, as they are stored in the map.
function canonical.node_vector(v)
  if type(v) ~= "table" then return canonical.NULL end
  return {
    x = math.floor(tonumber(v.x) or 0),
    y = math.floor(tonumber(v.y) or 0),
    z = math.floor(tonumber(v.z) or 0),
  }
end

--- Sorted, de-duplicated array of strings. Used for every tag/group list so
--- that tag order can never carry information or churn between runs.
function canonical.sorted_unique(list)
  local seen, out = {}, {}
  for _, item in ipairs(list or {}) do
    local key = tostring(item)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  table.sort(out)
  if #out == 0 then return canonical.EMPTY_ARRAY end
  return out
end

--- Groups table -> sorted array of {name, value} pairs.
-- A Lua map would serialise in hash order; an array of pairs cannot.
function canonical.groups(groups)
  local names = {}
  for name, value in pairs(groups or {}) do
    if type(value) == "number" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if #names == 0 then return canonical.EMPTY_ARRAY end
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = {name = name, value = math.floor(groups[name])}
  end
  return out
end

-- === Encoding ===

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function encode_string(s)
  local out = s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. out .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return "0"
  end
  if n == math.floor(n) and math.abs(n) < 9007199254740992 then
    return string.format("%d", n)
  end
  local text = string.format("%." .. canonical.ROUND_PLACES .. "f", n)
  -- Trim trailing zeros so 1.500 and 1.5 never differ between runs.
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function is_array(t)
  local count = 0
  for key in pairs(t) do
    if type(key) ~= "number" then return false end
    count = count + 1
  end
  if count == 0 then return false end
  for i = 1, count do
    if t[i] == nil then return false end
  end
  return true
end

local encode_value

local function encode_table(t, out, depth)
  if depth > 32 then
    out[#out + 1] = '"__depth_limit__"'
    return
  end
  if t == canonical.NULL then
    out[#out + 1] = "null"
    return
  end
  if t == canonical.EMPTY_ARRAY then
    out[#out + 1] = "[]"
    return
  end
  if is_array(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode_value(t[i], out, depth + 1)
    end
    out[#out + 1] = "]"
    return
  end
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  out[#out + 1] = "{"
  for i, key in ipairs(keys) do
    if i > 1 then out[#out + 1] = "," end
    out[#out + 1] = encode_string(tostring(key))
    out[#out + 1] = ":"
    encode_value(t[key], out, depth + 1)
  end
  out[#out + 1] = "}"
end

encode_value = function(value, out, depth)
  local kind = type(value)
  if value == nil then
    out[#out + 1] = "null"
  elseif kind == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif kind == "number" then
    out[#out + 1] = encode_number(value)
  elseif kind == "string" then
    out[#out + 1] = encode_string(value)
  elseif kind == "table" then
    encode_table(value, out, depth)
  else
    -- Functions and userdata never belong in a response. Emitting a marker
    -- instead of the value keeps a producer bug from leaking a Lua reference.
    out[#out + 1] = encode_string("__unencodable_" .. kind .. "__")
  end
end

--- Encode a value as canonical JSON.
function canonical.encode(value)
  local out = {}
  encode_value(value, out, 0)
  return table.concat(out)
end

--- Decode JSON.
--
-- Malformed input from outside the server is expected traffic, not a server
-- fault, so the third argument asks the engine to return the parse error
-- instead of writing it to the log. A spool full of junk must not be able to
-- fill an operator's log with ERROR lines.
function canonical.decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "empty_document"
  end
  local ok, value = pcall(minetest.parse_json, text, nil, true)
  if not ok or value == nil then
    return nil, "malformed_json"
  end
  return value
end

return canonical
