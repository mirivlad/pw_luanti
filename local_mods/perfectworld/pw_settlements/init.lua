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

function perfectworld.settlements.normalize(data)
  if type(data) ~= "table" then return nil end
  local settlement
  if type(data.settlement) == "table" then
    settlement = data.settlement
  elseif data.settlement_id then
    settlement = data
  end
  if type(settlement) ~= "table" then return nil end

  local plan = type(data.plan) == "table" and data.plan or {}
  local profile = type(data.profile) == "table" and data.profile or {}
  local normalized = deep_copy(settlement)

  normalized.settlement_grammar_version =
    tonumber(settlement.settlement_grammar_version)
    or tonumber(plan.settlement_grammar_version)
    or tonumber(profile.settlement_grammar_version)
    or 2
  normalized.center_pos = deep_copy(settlement.center_pos
    or plan.center
    or profile.selected_site)
  normalized.bounds = deep_copy(settlement.bounds or plan.bounds)
  normalized.archetype = settlement.archetype or plan.archetype
  normalized.name = settlement.name
  normalized.settlement_type = settlement.settlement_type
  normalized.size_class = settlement.size_class or plan.size_class
  normalized.plan_lots = deep_copy(plan.lots or settlement.plan_lots or {})
  normalized.ecology = deep_copy(settlement.ecology or profile.ecology or {})
  normalized.worksite_ids = deep_copy(settlement.worksite_ids or {})
  normalized.worksite_kinds = deep_copy(settlement.worksite_kinds or {})
  normalized.worksites = deep_copy(settlement.worksites or {})
  normalized.resource_features = deep_copy(settlement.resource_features
    or profile.resource_features or {})
  normalized.errors = deep_copy(settlement.errors or {})
  normalized.warnings = deep_copy(settlement.warnings or {})

  return normalized
end

function perfectworld.settlements.get(settlement_id)
  local data = perfectworld.planner.get_settlement_plan(settlement_id)
  return perfectworld.settlements.normalize(data)
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
dofile(minetest.get_modpath("pw_settlements") .. "/naming.lua")

minetest.log("action", "[pw_settlements] loaded")
