perfectworld = rawget(_G, "perfectworld") or {}
_G.perfectworld = perfectworld
perfectworld.settlements = perfectworld.settlements or {}

local settlement_types = {
  farm = { label_en = "Farm", priority_range = {1, 2}, max_population = 10, required_structures = {"farmhouse"} },
  hamlet = { label_en = "Hamlet", priority_range = {2, 4}, max_population = 50, required_structures = {"house", "well"} },
  village = { label_en = "Village", priority_range = {4, 5}, max_population = 200, required_structures = {"house", "well", "meeting_place"} },
  town = { label_en = "Town", priority_range = {5, 7}, max_population = 500, required_structures = {} },
  city = { label_en = "City", priority_range = {7, 10}, max_population = 2000, required_structures = {} },
}

local deep_copy = perfectworld.core.deep_copy

function perfectworld.settlements.get_types()
  return deep_copy(settlement_types)
end

function perfectworld.settlements.get_type(name)
  return settlement_types[name] and deep_copy(settlement_types[name]) or nil
end

-- === Settlement Record API ===
-- Persisted via pw_planner mod_storage. This module provides accessors.

function perfectworld.settlements.get(settlement_id)
  local data = perfectworld.planner.get_settlement_plan(settlement_id)
  if data and data.settlement then
    return deep_copy(data.settlement)
  end
  return nil
end

function perfectworld.settlements.list_ids()
  return perfectworld.planner.list_settlements()
end

function perfectworld.settlements.list()
  local out = {}
  for _, id in ipairs(perfectworld.settlements.list_ids()) do
    local s = perfectworld.settlements.get(id)
    if s then
      table.insert(out, s)
    end
  end
  return out
end

function perfectworld.settlements.get_by_candidate(candidate_id)
  return perfectworld.settlements.get(candidate_id)
end

dofile(minetest.get_modpath("pw_settlements") .. "/specializations.lua")

minetest.log("action", "[pw_settlements] loaded")
