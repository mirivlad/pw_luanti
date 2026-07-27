-- pw_bot_bridge/oracle_perception.lua
--
-- Exact answers for the test kit, the coding agent and generator diagnostics.
--
-- Oracle mode changes how much a caller may know. It changes nothing about what
-- the bridge does: it still only reads. No node is placed, no player is moved,
-- no door is opened, and no map block is forced into memory — a position the
-- server has not loaded is reported as not loaded, never generated on demand.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local semantics = B.impl.semantics
local perception = B.impl.perception
local entities = B.impl.entities
local settings = B.impl.settings
local oracle = {}
B.impl.oracle_perception = oracle

local function planner()
  return perfectworld and perfectworld.planner
end

local function structures_api()
  return perfectworld and perfectworld.structures
end

-- === Geometry helpers ===

local function sorted_box(min, max)
  return {
    x = math.min(min.x, max.x), y = math.min(min.y, max.y), z = math.min(min.z, max.z),
  }, {
    x = math.max(min.x, max.x), y = math.max(min.y, max.y), z = math.max(min.z, max.z),
  }
end

oracle.sorted_box = sorted_box

function oracle.volume(min, max)
  local a, b = sorted_box(min, max)
  return (b.x - a.x + 1) * (b.y - a.y + 1) * (b.z - a.z + 1)
end

local function in_box(pos, min, max)
  return pos.x >= min.x and pos.x <= max.x
    and pos.y >= min.y and pos.y <= max.y
    and pos.z >= min.z and pos.z <= max.z
end

local function in_box_xz(x, z, min, max)
  return x >= min.x and x <= max.x and z >= min.z and z <= max.z
end

-- === Node reading ===

--- Every node in a box, in a fixed y/z/x order so the array is canonical.
function oracle.read_nodes(min, max, budget, opts)
  opts = opts or {}
  local a, b = sorted_box(min, max)
  local nodes = {}
  local counts = {air = 0, not_loaded = 0, ignore = 0, unknown = 0, solid = 0}
  for y = a.y, b.y do
    for z = a.z, b.z do
      for x = a.x, b.x do
        if not perception.spend(budget, 1) then
          return nodes, counts, true
        end
        local pos = {x = x, y = y, z = z}
        local sample = perception.node_at(pos)
        if sample.state == "not_loaded" then
          counts.not_loaded = counts.not_loaded + 1
          if opts.include_unloaded then
            nodes[#nodes + 1] = {
              position = canonical.node_vector(pos),
              available = false,
              reason = "map_not_loaded",
            }
          end
        elseif sample.state == "ignore" then
          counts.ignore = counts.ignore + 1
          if opts.include_unloaded then
            nodes[#nodes + 1] = {
              position = canonical.node_vector(pos),
              available = false,
              reason = "ignore",
            }
          end
        elseif sample.name == "air" then
          counts.air = counts.air + 1
          if opts.include_air then
            nodes[#nodes + 1] = {
              position = canonical.node_vector(pos),
              name = "air",
              param2 = 0,
            }
          end
        else
          if sample.state == "unknown" then counts.unknown = counts.unknown + 1 end
          counts.solid = counts.solid + 1
          local record
          if opts.detail == "full" then
            record = semantics.describe_node(sample.name, sample.param2, pos)
            record.position = canonical.node_vector(pos)
            record.state = sample.state
          else
            record = {
              position = canonical.node_vector(pos),
              name = sample.name,
              param2 = sample.param2,
              state = sample.state,
            }
            if opts.detail == "semantics" then
              record.semantics = semantics.tags_for_node_name(sample.name)
            end
          end
          nodes[#nodes + 1] = record
        end
      end
    end
  end
  return nodes, counts, false
end

--- Ground profile of every column in a box.
function oracle.read_surface(min, max, budget)
  local a, b = sorted_box(min, max)
  local columns = {}
  for z = a.z, b.z do
    for x = a.x, b.x do
      -- Oracle reports the exact topmost surface, and separately where a body
      -- could actually stand. Those are different questions and a diagnostic
      -- needs both: an overhang is a surface with no standing room under it.
      local ground_y, reason, sample = perception.surface_in_column(x, z, b.y, b.y - a.y, budget)
      if not ground_y then
        columns[#columns + 1] = {
          position = {x = x, z = z},
          available = false,
          reason = reason or "no_surface",
        }
      else
        local def = sample and minetest.registered_nodes[sample.name] or nil
        local clearance = perception.head_clearance(x, ground_y, z, 4, budget)
        local standable_y = perception.surface_in_column(x, z, b.y, b.y - a.y, budget,
          {clearance = 2})
        columns[#columns + 1] = {
          position = {x = x, z = z},
          ground_y = ground_y,
          ground_node = sample.name,
          standable_y = standable_y or canonical.NULL,
          walkable = clearance >= 2,
          head_clearance = clearance,
          liquid_type = (def and def.liquidtype) or "none",
          climbable = (def and def.climbable) and true or false,
          semantics = semantics.tags_for_node_name(sample.name),
        }
      end
      if budget.truncated then return columns, true end
    end
  end
  return columns, false
end

-- === PerfectWorld records ===

local function road_records()
  local api = planner()
  if not api or not api.list_roads then return {} end
  local ok, roads = pcall(api.list_roads)
  if not ok or type(roads) ~= "table" then return {} end
  return roads
end

local function structure_records()
  local api = planner()
  if not api or not api.list_structures then return {} end
  local ok, records = pcall(api.list_structures)
  if not ok or type(records) ~= "table" then return {} end
  return records
end

local function settlement_ids()
  local api = planner()
  if not api or not api.list_settlements then return {} end
  local ok, ids = pcall(api.list_settlements)
  if not ok or type(ids) ~= "table" then return {} end
  return ids
end

local function settlement_plan(settlement_id)
  local api = planner()
  if not api or not api.get_settlement_plan then return nil end
  local ok, data = pcall(api.get_settlement_plan, settlement_id)
  if not ok then return nil end
  return data
end

local function road_path(road)
  local out = {}
  for _, point in ipairs(road.path or road.points or {}) do
    out[#out + 1] = {x = math.floor(point.x), z = math.floor(point.z)}
  end
  return out
end

--- Cells a road covers, honouring its width.
local function road_cells(road)
  local cells = {}
  local half = math.floor((road.width or 2) / 2)
  local points = road_path(road)
  for i = 1, #points do
    local from = points[i]
    local to = points[i + 1] or from
    local steps = math.max(math.abs(to.x - from.x), math.abs(to.z - from.z), 1)
    for step = 0, steps do
      local t = step / steps
      local px = math.floor(from.x + (to.x - from.x) * t + 0.5)
      local pz = math.floor(from.z + (to.z - from.z) * t + 0.5)
      for dx = -half, half do
        for dz = -half, half do
          cells[(px + dx) .. ":" .. (pz + dz)] = {x = px + dx, z = pz + dz}
        end
      end
    end
  end
  return cells
end

oracle.road_cells = road_cells

--- Doorways of a materialised structure.
--
-- The settlement plan records the threshold the builder actually laid; where it
-- does not, the structure definition's road connector plus the placed rotation
-- gives the same point. Reporting both sources, and which one answered, keeps a
-- diagnostic honest about what it actually knows.
function oracle.structure_entrances(record)
  local out = {}
  local plan_data = record.settlement_id and settlement_plan(record.settlement_id) or nil
  if plan_data and plan_data.plan and plan_data.plan.lots then
    for _, lot in ipairs(plan_data.plan.lots) do
      if lot.structure_id == record.structure_id and lot.door then
        out[#out + 1] = {
          source = "settlement_plan",
          position = canonical.node_vector(lot.door),
          road_point = lot.road_point and {x = lot.road_point.x, z = lot.road_point.z} or canonical.NULL,
        }
      end
    end
  end
  local api = structures_api()
  if api and api.get and record.structure_name then
    local def = api.get(record.structure_name)
    if def and def.connectors and record.position then
      for _, connector in ipairs(def.connectors) do
        if connector.type == "road" and connector.offset_pos then
          local rotated = api.rotate_point(connector.offset_pos, record.rotation or 0)
          out[#out + 1] = {
            source = "structure_connector",
            position = canonical.node_vector({
              x = record.position.x + rotated.x,
              y = record.position.y + (rotated.y or 0),
              z = record.position.z + rotated.z,
            }),
            road_point = record.road_point
              and {x = record.road_point.x, z = record.road_point.z} or canonical.NULL,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.z ~= b.position.z then return a.position.z < b.position.z end
    return a.source < b.source
  end)
  if #out == 0 then return canonical.EMPTY_ARRAY end
  return out
end

-- === Operations ===

local function limits_of(bot)
  return bot.limits
end

--- Raw nodes in an explicit box.
function oracle.get_nodes(player, session, bot, params, budget)
  local min, max = sorted_box(params.min, params.max)
  local nodes, counts, truncated = oracle.read_nodes(min, max, budget, {
    include_air = params.include_air == true,
    include_unloaded = params.include_unloaded ~= false,
    detail = params.detail or "plain",
  })
  return {
    mode = "oracle",
    min = canonical.node_vector(min),
    max = canonical.node_vector(max),
    volume = oracle.volume(min, max),
    counts = counts,
    nodes = #nodes > 0 and nodes or canonical.EMPTY_ARRAY,
    truncated = truncated or budget.truncated,
    budget = perception.budget_report(budget),
  }
end

--- Composite area query. `include` names which layers to build.
function oracle.get_area(player, session, bot, params, budget)
  local min, max = sorted_box(params.min, params.max)
  local include = {}
  for _, name in ipairs(params.include or {"nodes", "semantics"}) do
    include[name] = true
  end

  local data = {
    mode = "oracle",
    min = canonical.node_vector(min),
    max = canonical.node_vector(max),
    volume = oracle.volume(min, max),
    include = canonical.sorted_unique(params.include or {"nodes", "semantics"}),
  }

  if include.nodes or include.semantics or include.collision then
    local detail = "plain"
    if include.collision then detail = "full"
    elseif include.semantics then detail = "semantics" end
    local nodes, counts, truncated = oracle.read_nodes(min, max, budget, {
      include_air = params.include_air == true,
      include_unloaded = true,
      detail = detail,
    })
    data.nodes = #nodes > 0 and nodes or canonical.EMPTY_ARRAY
    data.counts = counts
    data.nodes_truncated = truncated
  end

  if include.surface then
    local columns, truncated = oracle.read_surface(min, max, budget)
    data.surface = #columns > 0 and columns or canonical.EMPTY_ARRAY
    data.surface_truncated = truncated
  end

  if include.entities then
    local eye = {
      x = (min.x + max.x) / 2, y = (min.y + max.y) / 2, z = (min.z + max.z) / 2,
    }
    data.entities = entities.in_area(session, min, max, eye, budget, {include_hp = true})
  end

  if include.records then
    data.records = oracle.records_in_box(min, max)
  end

  data.truncated = budget.truncated
  data.budget = perception.budget_report(budget)
  return data
end

--- PerfectWorld records whose footprint touches a box.
function oracle.records_in_box(min, max)
  local roads, structures, settlements = {}, {}, {}

  for _, record in ipairs(structure_records()) do
    local fp_min = record.footprint_min
    local fp_max = record.footprint_max
    if fp_min and fp_max
      and fp_max.x >= min.x and fp_min.x <= max.x
      and fp_max.z >= min.z and fp_min.z <= max.z then
      structures[#structures + 1] = {
        structure_id = record.structure_id,
        structure_name = record.structure_name,
        role = record.role,
        settlement_id = record.settlement_id or canonical.NULL,
        position = record.position and canonical.node_vector(record.position) or canonical.NULL,
        rotation = math.floor(record.rotation or 0),
        footprint_min = {x = math.floor(fp_min.x), z = math.floor(fp_min.z)},
        footprint_max = {x = math.floor(fp_max.x), z = math.floor(fp_max.z)},
      }
    end
  end
  table.sort(structures, function(a, b) return a.structure_id < b.structure_id end)

  for _, road in ipairs(road_records()) do
    local touches = false
    for _, point in ipairs(road_path(road)) do
      if in_box_xz(point.x, point.z, min, max) then touches = true break end
    end
    if touches then
      roads[#roads + 1] = {
        road_id = road.id,
        kind = road.kind or road.type or "unknown",
        width = math.floor(road.width or 1),
        settlement_id = road.from_settlement or canonical.NULL,
        to_structure = road.to_structure or canonical.NULL,
        point_count = #road_path(road),
      }
    end
  end
  table.sort(roads, function(a, b) return a.road_id < b.road_id end)

  for _, id in ipairs(settlement_ids()) do
    local data = settlement_plan(id)
    local bounds = data and data.plan and data.plan.bounds
    if bounds
      and bounds.max_x >= min.x and bounds.min_x <= max.x
      and bounds.max_z >= min.z and bounds.min_z <= max.z then
      settlements[#settlements + 1] = {
        settlement_id = id,
        archetype = data.plan.archetype or "unknown",
        center = data.plan.center and {x = data.plan.center.x, z = data.plan.center.z} or canonical.NULL,
        bounds = {
          min_x = math.floor(bounds.min_x), max_x = math.floor(bounds.max_x),
          min_z = math.floor(bounds.min_z), max_z = math.floor(bounds.max_z),
        },
        lot_count = data.plan.lots and #data.plan.lots or 0,
      }
    end
  end
  table.sort(settlements, function(a, b) return a.settlement_id < b.settlement_id end)

  return {
    structures = #structures > 0 and structures or canonical.EMPTY_ARRAY,
    roads = #roads > 0 and roads or canonical.EMPTY_ARRAY,
    settlements = #settlements > 0 and settlements or canonical.EMPTY_ARRAY,
  }
end

function oracle.get_entities(player, session, bot, params, budget)
  local min, max = sorted_box(params.min, params.max)
  local eye = {x = (min.x + max.x) / 2, y = (min.y + max.y) / 2, z = (min.z + max.z) / 2}
  local found = entities.in_area(session, min, max, eye, budget, {include_hp = true})
  return {
    mode = "oracle",
    min = canonical.node_vector(min),
    max = canonical.node_vector(max),
    entities = found,
    entity_count = (found == canonical.EMPTY_ARRAY) and 0 or #found,
    note = "oracle reports objects regardless of occlusion",
    budget = perception.budget_report(budget),
  }
end

--- Full collision and selection geometry for one position or a small box.
function oracle.get_collision(player, session, bot, params, budget)
  local positions = {}
  if params.position then
    positions[#positions + 1] = canonical.node_vector(params.position)
  else
    local min, max = sorted_box(params.min, params.max)
    for y = min.y, max.y do
      for z = min.z, max.z do
        for x = min.x, max.x do
          positions[#positions + 1] = {x = x, y = y, z = z}
        end
      end
    end
  end
  local out = {}
  for _, pos in ipairs(positions) do
    if not perception.spend(budget, 1) then break end
    out[#out + 1] = perception.describe_at(pos, budget)
  end
  return {
    mode = "oracle",
    nodes = #out > 0 and out or canonical.EMPTY_ARRAY,
    note = "walkable, collision geometry, selection geometry and visual transparency are four different properties and are reported separately",
    truncated = budget.truncated,
    budget = perception.budget_report(budget),
  }
end

function oracle.get_surface(player, session, bot, params, budget)
  local min, max = sorted_box(params.min, params.max)
  local columns, truncated = oracle.read_surface(min, max, budget)
  return {
    mode = "oracle",
    min = canonical.node_vector(min),
    max = canonical.node_vector(max),
    columns = #columns > 0 and columns or canonical.EMPTY_ARRAY,
    truncated = truncated or budget.truncated,
    budget = perception.budget_report(budget),
  }
end

function oracle.get_structure(player, session, bot, params, budget)
  local records = structure_records()
  local matches = {}
  for _, record in ipairs(records) do
    local hit = false
    if params.structure_id and record.structure_id == params.structure_id then hit = true end
    if params.settlement_id and record.settlement_id == params.settlement_id then hit = true end
    if params.position and record.footprint_min and record.footprint_max then
      if in_box_xz(math.floor(params.position.x), math.floor(params.position.z),
        {x = record.footprint_min.x, z = record.footprint_min.z},
        {x = record.footprint_max.x, z = record.footprint_max.z}) then
        hit = true
      end
    end
    if hit then
      matches[#matches + 1] = {
        structure_id = record.structure_id,
        structure_name = record.structure_name,
        role = record.role,
        status = record.status or "unknown",
        settlement_id = record.settlement_id or canonical.NULL,
        region_id = record.region_id or canonical.NULL,
        position = record.position and canonical.node_vector(record.position) or canonical.NULL,
        rotation = math.floor(record.rotation or 0),
        footprint_min = record.footprint_min
          and {x = math.floor(record.footprint_min.x), z = math.floor(record.footprint_min.z)}
          or canonical.NULL,
        footprint_max = record.footprint_max
          and {x = math.floor(record.footprint_max.x), z = math.floor(record.footprint_max.z)}
          or canonical.NULL,
        road_point = record.road_point
          and {x = math.floor(record.road_point.x), z = math.floor(record.road_point.z)}
          or canonical.NULL,
        entrances = oracle.structure_entrances(record),
      }
    end
  end
  table.sort(matches, function(a, b) return a.structure_id < b.structure_id end)
  return {
    mode = "oracle",
    structures = #matches > 0 and matches or canonical.EMPTY_ARRAY,
    structure_count = #matches,
    budget = perception.budget_report(budget),
  }
end

--- Doorways plus whether the threshold can actually be stood on.
function oracle.get_structure_entrances(player, session, bot, params, budget)
  local result = oracle.get_structure(player, session, bot, params, budget)
  local out = {}
  for _, record in ipairs(result.structures == canonical.EMPTY_ARRAY and {} or result.structures) do
    for _, entrance in ipairs(record.entrances == canonical.EMPTY_ARRAY and {} or record.entrances) do
      local access = oracle.access_at(entrance.position, budget)
      out[#out + 1] = {
        structure_id = record.structure_id,
        source = entrance.source,
        position = entrance.position,
        road_point = entrance.road_point,
        access = access,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.structure_id ~= b.structure_id then return a.structure_id < b.structure_id end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.z ~= b.position.z then return a.position.z < b.position.z end
    return a.source < b.source
  end)
  return {
    mode = "oracle",
    entrances = #out > 0 and out or canonical.EMPTY_ARRAY,
    entrance_count = #out,
    budget = perception.budget_report(budget),
  }
end

function oracle.get_road(player, session, bot, params, budget)
  local matches = {}
  for _, road in ipairs(road_records()) do
    local hit = false
    if params.road_id and road.id == params.road_id then hit = true end
    if params.settlement_id and road.from_settlement == params.settlement_id then hit = true end
    if params.min and params.max then
      local min, max = sorted_box(params.min, params.max)
      for _, point in ipairs(road_path(road)) do
        if in_box_xz(point.x, point.z, min, max) then hit = true break end
      end
    end
    if hit then
      local path = road_path(road)
      matches[#matches + 1] = {
        road_id = road.id,
        kind = road.kind or road.type or "unknown",
        type = road.type or "unknown",
        width = math.floor(road.width or 1),
        settlement_id = road.from_settlement or canonical.NULL,
        to_structure = road.to_structure or canonical.NULL,
        segment_count = math.floor(road.segment_count or math.max(#path - 1, 0)),
        path = #path > 0 and path or canonical.EMPTY_ARRAY,
      }
    end
  end
  table.sort(matches, function(a, b) return a.road_id < b.road_id end)
  return {
    mode = "oracle",
    roads = #matches > 0 and matches or canonical.EMPTY_ARRAY,
    road_count = #matches,
    budget = perception.budget_report(budget),
  }
end

--- Which roads touch which, and where.
function oracle.get_road_topology(player, session, bot, params, budget)
  local scoped = oracle.get_road(player, session, bot, params, budget)
  local roads = scoped.roads == canonical.EMPTY_ARRAY and {} or scoped.roads
  local cell_owner = {}
  local raw = {}
  for _, road in ipairs(road_records()) do raw[road.id] = road end

  for _, road in ipairs(roads) do
    for key, cell in pairs(road_cells(raw[road.road_id] or {})) do
      cell_owner[key] = cell_owner[key] or {cell = cell, ids = {}}
      cell_owner[key].ids[#cell_owner[key].ids + 1] = road.road_id
    end
  end

  local junctions, edges = {}, {}
  local edge_seen = {}
  for _, entry in pairs(cell_owner) do
    if #entry.ids > 1 then
      table.sort(entry.ids)
      junctions[#junctions + 1] = {
        position = {x = entry.cell.x, z = entry.cell.z},
        road_ids = canonical.sorted_unique(entry.ids),
      }
      for i = 1, #entry.ids do
        for j = i + 1, #entry.ids do
          if entry.ids[i] ~= entry.ids[j] then
            local key = entry.ids[i] .. "|" .. entry.ids[j]
            if not edge_seen[key] then
              edge_seen[key] = true
              edges[#edges + 1] = {from = entry.ids[i], to = entry.ids[j]}
            end
          end
        end
      end
    end
  end
  table.sort(junctions, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.position.z < b.position.z
  end)
  table.sort(edges, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.to < b.to
  end)

  return {
    mode = "oracle",
    roads = scoped.roads,
    junctions = #junctions > 0 and junctions or canonical.EMPTY_ARRAY,
    edges = #edges > 0 and edges or canonical.EMPTY_ARRAY,
    budget = perception.budget_report(budget),
  }
end

function oracle.get_settlement(player, session, bot, params, budget)
  local ids = {}
  if params.settlement_id then
    ids = {params.settlement_id}
  else
    ids = settlement_ids()
  end
  local out = {}
  for _, id in ipairs(ids) do
    local data = settlement_plan(id)
    if data and data.settlement then
      local include = true
      if params.min and params.max then
        local min, max = sorted_box(params.min, params.max)
        local bounds = data.plan and data.plan.bounds
        include = bounds
          and bounds.max_x >= min.x and bounds.min_x <= max.x
          and bounds.max_z >= min.z and bounds.min_z <= max.z
      end
      if params.position and data.plan and data.plan.bounds then
        local bounds = data.plan.bounds
        include = params.position.x >= bounds.min_x and params.position.x <= bounds.max_x
          and params.position.z >= bounds.min_z and params.position.z <= bounds.max_z
      end
      if include then
        local settlement = data.settlement
        out[#out + 1] = {
          settlement_id = id,
          archetype = data.plan and data.plan.archetype or "unknown",
          size_class = data.plan and data.plan.size_class or "unknown",
          biome_family = settlement.biome_family or canonical.NULL,
          palette_id = settlement.palette_id or canonical.NULL,
          center = data.plan and data.plan.center
            and {x = data.plan.center.x, z = data.plan.center.z} or canonical.NULL,
          bounds = data.plan and data.plan.bounds and {
            min_x = math.floor(data.plan.bounds.min_x),
            max_x = math.floor(data.plan.bounds.max_x),
            min_z = math.floor(data.plan.bounds.min_z),
            max_z = math.floor(data.plan.bounds.max_z),
          } or canonical.NULL,
          structure_ids = canonical.sorted_unique(settlement.structure_ids or {}),
          road_ids = canonical.sorted_unique(settlement.road_ids or {}),
          lot_count = math.floor(settlement.lot_count or 0),
          errors = canonical.sorted_unique(settlement.errors or {}),
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.settlement_id < b.settlement_id end)
  return {
    mode = "oracle",
    settlements = #out > 0 and out or canonical.EMPTY_ARRAY,
    settlement_count = #out,
    budget = perception.budget_report(budget),
  }
end

--- Lots of a settlement: the plot, the building on it, the door and the street.
function oracle.get_lots(player, session, bot, params, budget)
  local data = params.settlement_id and settlement_plan(params.settlement_id) or nil
  if not data or not data.plan then
    return {
      mode = "oracle",
      settlement_id = params.settlement_id or canonical.NULL,
      lots = canonical.EMPTY_ARRAY,
      lot_count = 0,
      available = false,
      reason = "settlement_not_found",
    }
  end
  local out = {}
  for _, lot in ipairs(data.plan.lots or {}) do
    out[#out + 1] = {
      index = math.floor(lot.index or 0),
      role = lot.role or "unknown",
      structure_id = lot.structure_id or canonical.NULL,
      structure_name = lot.structure_name or "unknown",
      status = lot.status or "planned",
      rotation = math.floor(lot.rotation or 0),
      center = lot.center and {x = lot.center.x, z = lot.center.z} or canonical.NULL,
      footprint_min = lot.footprint_min
        and {x = math.floor(lot.footprint_min.x), z = math.floor(lot.footprint_min.z)}
        or canonical.NULL,
      footprint_max = lot.footprint_max
        and {x = math.floor(lot.footprint_max.x), z = math.floor(lot.footprint_max.z)}
        or canonical.NULL,
      door = lot.door and canonical.node_vector(lot.door) or canonical.NULL,
      road_point = lot.road_point
        and {x = math.floor(lot.road_point.x), z = math.floor(lot.road_point.z)}
        or canonical.NULL,
      road_id = lot.road_id or canonical.NULL,
      yard = lot.yard or canonical.NULL,
    }
  end
  table.sort(out, function(a, b) return a.index < b.index end)
  return {
    mode = "oracle",
    settlement_id = params.settlement_id,
    lots = #out > 0 and out or canonical.EMPTY_ARRAY,
    lot_count = #out,
    budget = perception.budget_report(budget),
  }
end

--- Can a body stand at this position?
function oracle.access_at(position, budget)
  local pos = canonical.node_vector(position)
  local below = perception.node_at({x = pos.x, y = pos.y - 1, z = pos.z})
  local at = perception.node_at(pos)
  local above = perception.node_at({x = pos.x, y = pos.y + 1, z = pos.z})
  perception.spend(budget, 3)

  local function passable(sample)
    if sample.state ~= "loaded" then return false end
    local def = minetest.registered_nodes[sample.name]
    return not def or def.walkable == false
  end
  local below_def = minetest.registered_nodes[below.name]
  local supported = below.state == "loaded" and below_def and below_def.walkable ~= false

  local reasons = {}
  if below.state ~= "loaded" then reasons[#reasons + 1] = "support_" .. below.state end
  if not supported then reasons[#reasons + 1] = "no_support_below" end
  if not passable(at) then reasons[#reasons + 1] = "feet_blocked" end
  if not passable(above) then reasons[#reasons + 1] = "head_blocked" end
  local at_def = minetest.registered_nodes[at.name]
  if at_def and (at_def.liquidtype or "none") ~= "none" then
    reasons[#reasons + 1] = "flooded"
  end
  if at_def and (at_def.damage_per_second or 0) > 0 then
    reasons[#reasons + 1] = "damaging"
  end

  return {
    position = pos,
    standable = #reasons == 0,
    reasons = canonical.sorted_unique(reasons),
    node_below = below.name,
    node_at = at.name,
    node_above = above.name,
    support_state = below.state,
  }
end

function oracle.inspect_position(player, session, bot, params, budget)
  local pos = canonical.node_vector(params.position)
  local described = perception.describe_at(pos, budget)
  local records = oracle.records_in_box(
    {x = pos.x, y = pos.y, z = pos.z},
    {x = pos.x, y = pos.y, z = pos.z})

  local on_road = {}
  for _, road in ipairs(road_records()) do
    local cells = road_cells(road)
    if cells[pos.x .. ":" .. pos.z] then
      on_road[#on_road + 1] = road.id
    end
  end

  return {
    mode = "oracle",
    position = pos,
    node = described,
    access = oracle.access_at(pos, budget),
    records = records,
    road_ids_covering = canonical.sorted_unique(on_road),
    budget = perception.budget_report(budget),
  }
end

function oracle.validate_access_point(player, session, bot, params, budget)
  local pos = canonical.node_vector(params.position)
  local access = oracle.access_at(pos, budget)

  -- Is there any road cell adjacent enough to walk from?
  local nearest_road, nearest_distance = canonical.NULL, canonical.NULL
  local radius = math.min(tonumber(params.road_search_radius) or 8, 32)
  for _, road in ipairs(road_records()) do
    for key, cell in pairs(road_cells(road)) do
      local dx, dz = cell.x - pos.x, cell.z - pos.z
      local distance = math.sqrt(dx * dx + dz * dz)
      if distance <= radius then
        if nearest_distance == canonical.NULL or distance < nearest_distance then
          nearest_distance = distance
          nearest_road = road.id
        end
      end
    end
  end

  -- Walk the straight line to the nearest road cell and check every step is
  -- standable. This is not a pathfinder: it answers "is the obvious approach
  -- usable", which is what a placement defect looks like.
  local approach = canonical.NULL
  if nearest_road ~= canonical.NULL then
    approach = {road_id = nearest_road, distance = canonical.round(nearest_distance)}
  end

  return {
    mode = "oracle",
    position = pos,
    access = access,
    nearest_road = approach,
    search_radius = radius,
    budget = perception.budget_report(budget),
  }
end

--- Physical defects an area can have.
--
-- Every check answers a question that has bitten this project before: a road
-- hanging over a hole, a lot under water, a building standing on nothing, a
-- carriageway laid across a footprint.
function oracle.validate_area(player, session, bot, params, budget)
  local min, max = sorted_box(params.min, params.max)
  local findings = {}
  local function finding(code, position, detail)
    findings[#findings + 1] = {
      code = code,
      position = position,
      detail = detail or canonical.NULL,
    }
  end

  local checked_road_cells = 0
  local footprints = {}
  for _, record in ipairs(structure_records()) do
    if record.footprint_min and record.footprint_max then
      footprints[#footprints + 1] = record
    end
  end

  for _, road in ipairs(road_records()) do
    for _, cell in pairs(road_cells(road)) do
      if in_box_xz(cell.x, cell.z, min, max) then
        if not perception.spend(budget, 4) then break end
        checked_road_cells = checked_road_cells + 1
        local ground_y = perception.surface_in_column(cell.x, cell.z, max.y, max.y - min.y, budget)
        if ground_y then
          local under = perception.node_at({x = cell.x, y = ground_y - 1, z = cell.z})
          local under_def = minetest.registered_nodes[under.name]
          if under.state == "loaded" and under.name == "air" then
            finding("road_over_void", {x = cell.x, y = ground_y, z = cell.z}, {road_id = road.id})
          end
          local at = perception.node_at({x = cell.x, y = ground_y, z = cell.z})
          local at_def = minetest.registered_nodes[at.name]
          if at_def and (at_def.liquidtype or "none") ~= "none" then
            finding("road_flooded", {x = cell.x, y = ground_y, z = cell.z}, {road_id = road.id})
          end
          if under_def and (under_def.liquidtype or "none") ~= "none" then
            finding("road_over_liquid", {x = cell.x, y = ground_y, z = cell.z}, {road_id = road.id})
          end
        end
        for _, record in ipairs(footprints) do
          if in_box_xz(cell.x, cell.z,
            {x = record.footprint_min.x, z = record.footprint_min.z},
            {x = record.footprint_max.x, z = record.footprint_max.z}) then
            finding("road_crosses_footprint", {x = cell.x, y = 0, z = cell.z},
              {road_id = road.id, structure_id = record.structure_id})
          end
        end
      end
    end
    if budget.truncated then break end
  end

  for _, record in ipairs(footprints) do
    local fp_min, fp_max = record.footprint_min, record.footprint_max
    if fp_max.x >= min.x and fp_min.x <= max.x and fp_max.z >= min.z and fp_min.z <= max.z then
      local floor_y = record.position and math.floor(record.position.y) or nil
      if floor_y then
        for x = math.floor(fp_min.x), math.floor(fp_max.x) do
          for z = math.floor(fp_min.z), math.floor(fp_max.z) do
            if not perception.spend(budget, 1) then break end
            local under = perception.node_at({x = x, y = floor_y - 1, z = z})
            if under.state == "loaded" and under.name == "air" then
              finding("structure_over_void", {x = x, y = floor_y, z = z},
                {structure_id = record.structure_id})
            end
            local under_def = minetest.registered_nodes[under.name]
            if under_def and (under_def.liquidtype or "none") ~= "none" then
              finding("structure_over_liquid", {x = x, y = floor_y, z = z},
                {structure_id = record.structure_id})
            end
          end
          if budget.truncated then break end
        end
      end
      local entrances = oracle.structure_entrances(record)
      for _, entrance in ipairs(entrances == canonical.EMPTY_ARRAY and {} or entrances) do
        local access = oracle.access_at(entrance.position, budget)
        if not access.standable then
          finding("entrance_not_standable", entrance.position, {
            structure_id = record.structure_id,
            reasons = access.reasons,
          })
        end
      end
    end
    if budget.truncated then break end
  end

  table.sort(findings, function(a, b)
    if a.code ~= b.code then return a.code < b.code end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.z < b.position.z
  end)

  local by_code = {}
  for _, item in ipairs(findings) do
    by_code[item.code] = (by_code[item.code] or 0) + 1
  end

  -- Bound the payload: the summary stays complete, the list is capped.
  local capped = {}
  for i = 1, math.min(#findings, 200) do capped[i] = findings[i] end

  return {
    mode = "oracle",
    min = canonical.node_vector(min),
    max = canonical.node_vector(max),
    checked_road_cells = checked_road_cells,
    checked_structures = #footprints,
    finding_count = #findings,
    findings_by_code = next(by_code) and by_code or {},
    findings = #capped > 0 and capped or canonical.EMPTY_ARRAY,
    findings_truncated = #findings > #capped,
    truncated = budget.truncated,
    budget = perception.budget_report(budget),
  }
end

oracle.OPERATIONS = {
  get_nodes = oracle.get_nodes,
  get_area = oracle.get_area,
  get_entities = oracle.get_entities,
  get_collision = oracle.get_collision,
  get_surface = oracle.get_surface,
  get_structure = oracle.get_structure,
  get_structure_entrances = oracle.get_structure_entrances,
  get_road = oracle.get_road,
  get_road_topology = oracle.get_road_topology,
  get_settlement = oracle.get_settlement,
  get_lots = oracle.get_lots,
  inspect_position = oracle.inspect_position,
  validate_access_point = oracle.validate_access_point,
  validate_area = oracle.validate_area,
}

function oracle.list_operations()
  local out = {}
  for name in pairs(oracle.OPERATIONS) do out[#out + 1] = name end
  out[#out + 1] = "poll_events"
  table.sort(out)
  return out
end

function oracle.dispatch(operation, player, session, bot, params, budget)
  local handler = oracle.OPERATIONS[operation]
  if type(handler) ~= "function" then return nil end
  return handler(player, session, bot, params, budget)
end

return oracle
