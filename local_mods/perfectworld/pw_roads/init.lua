perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.roads = perfectworld.roads or {}

dofile(minetest.get_modpath("pw_roads") .. "/geometry.lua")
-- The inter-settlement graph reads region plans, which pw_planner supplies
-- later. It resolves the planner at call time, so loading order does not
-- matter and there is no cycle to break.
dofile(minetest.get_modpath("pw_roads") .. "/network.lua")

-- Road persistence is supplied after pw_planner loads. Keeping geometry and
-- the public API here avoids a dependency cycle and gives every consumer the
-- same raster before any village is planned.
local provider

function perfectworld.roads.set_provider(value)
  if type(value) ~= "table" then
    provider = nil
    return false
  end
  provider = value
  return true
end

--- Save a road record.
function perfectworld.roads.save(road)
  if not provider or type(provider.save) ~= "function" then return false end
  provider.save(road)
  return true
end

--- Get a single road by id.
-- Returns a deep copy or nil.
function perfectworld.roads.get(road_id)
  if not provider or type(provider.get) ~= "function" then return nil end
  return provider.get(road_id)
end

--- List all roads as an array of road records.
function perfectworld.roads.list_routes()
  if not provider or type(provider.list) ~= "function" then return {} end
  return provider.list()
end

--- Get the full road network as a table keyed by road id.
function perfectworld.roads.get_network()
  local network = {}
  for _, road in ipairs(perfectworld.roads.list_routes()) do
    if road and road.id then
      network[road.id] = road
    end
  end
  return network
end

--- List all road ids.
function perfectworld.roads.list_ids()
  local ids = {}
  for _, road in ipairs(perfectworld.roads.list_routes()) do
    if road and road.id then
      table.insert(ids, road.id)
    end
  end
  table.sort(ids)
  return ids
end

minetest.log("action", "[pw_roads] loaded")
