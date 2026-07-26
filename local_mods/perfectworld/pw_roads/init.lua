perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.roads = perfectworld.roads or {}

-- Road network API.
-- Road data is persisted by pw_planner in mod_storage under "pw_roads".
-- This module provides the public-facing API on top of that storage.
-- Requires pw_planner (declared in mod.conf depends).

--- Save a road record.
function perfectworld.roads.save(road)
  perfectworld.planner.save_road(road)
end

--- Get a single road by id.
-- Returns a deep copy or nil.
function perfectworld.roads.get(road_id)
  return perfectworld.planner.get_road(road_id)
end

--- List all roads as an array of road records.
function perfectworld.roads.list_routes()
  return perfectworld.planner.list_roads()
end

--- Get the full road network as a table keyed by road id.
function perfectworld.roads.get_network()
  local network = {}
  for _, road in ipairs(perfectworld.planner.list_roads()) do
    if road and road.id then
      network[road.id] = road
    end
  end
  return network
end

--- List all road ids.
function perfectworld.roads.list_ids()
  local ids = {}
  for _, road in ipairs(perfectworld.planner.list_roads()) do
    if road and road.id then
      table.insert(ids, road.id)
    end
  end
  table.sort(ids)
  return ids
end

minetest.log("action", "[pw_roads] loaded")
