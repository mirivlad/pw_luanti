perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.roads = perfectworld.roads or {}

-- Road network API.
-- Road data is persisted by pw_planner in mod_storage under "pw_roads".
-- This module provides the public-facing API on top of that storage.

local function has_planner()
  return perfectworld.planner
    and perfectworld.planner.save_road
    and perfectworld.planner.get_road
    and perfectworld.planner.list_roads
end

--- Save a road record.
-- Delegates to pw_planner.save_road if planner is loaded.
function perfectworld.roads.save(road)
  if has_planner() then
    perfectworld.planner.save_road(road)
  end
end

--- Get a single road by id.
-- Returns a deep copy or nil.
function perfectworld.roads.get(road_id)
  if has_planner() then
    return perfectworld.planner.get_road(road_id)
  end
  return nil
end

--- List all roads as an array of road records.
-- Note: pw_planner.list_roads() returns full records, not just ids.
function perfectworld.roads.list_routes()
  if has_planner() then
    return perfectworld.planner.list_roads()
  end
  return {}
end

--- Get the full road network as a table keyed by road id.
function perfectworld.roads.get_network()
  local network = {}
  if has_planner() then
    for _, road in ipairs(perfectworld.planner.list_roads()) do
      if road and road.id then
        network[road.id] = road
      end
    end
  end
  return network
end

--- List all road ids.
function perfectworld.roads.list_ids()
  if has_planner() then
    local ids = {}
    for _, road in ipairs(perfectworld.planner.list_roads()) do
      if road and road.id then
        table.insert(ids, road.id)
      end
    end
    table.sort(ids)
    return ids
  end
  return {}
end

minetest.log("action", "[pw_roads] loaded")
