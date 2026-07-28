-- Bounded ecological survey and deterministic physical site selection.

local ecology = {}
local choice = perfectworld.core.choice
local deep_copy = perfectworld.core.deep_copy

local SITE_RADIUS = 40
local SURVEY_RADIUS = 24
local SURVEY_STEP = 6
local OFFSETS = {
  {x = 40, z = 0},
  {x = 28, z = 28},
  {x = 0, z = 40},
  {x = -28, z = 28},
  {x = -40, z = 0},
  {x = -28, z = -28},
  {x = 0, z = -40},
  {x = 28, z = -28},
}

local function seed_key(candidate)
  return table.concat({
    "pwecology",
    candidate.world_seed_override or perfectworld.world_seed_string,
    "g3",
    tostring(candidate.id),
    perfectworld.core.coord_tag(candidate.rx or 0),
    perfectworld.core.coord_tag(candidate.rz or 0),
  }, "|")
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function ecology.enumerate_sites(candidate)
  local rx = candidate.rx or math.floor(candidate.x / perfectworld.REGION_SIZE)
  local rz = candidate.rz or math.floor(candidate.z / perfectworld.REGION_SIZE)
  local margin = perfectworld.planner.REGION_MARGIN or 80
  local min_x = rx * perfectworld.REGION_SIZE + margin
  local max_x = (rx + 1) * perfectworld.REGION_SIZE - margin - 1
  local min_z = rz * perfectworld.REGION_SIZE + margin
  local max_z = (rz + 1) * perfectworld.REGION_SIZE - margin - 1
  local rotation = choice.index(seed_key(candidate), "ecology:site_rotation", #OFFSETS) - 1

  local function site(id, x, z)
    return {
      id = id,
      x = clamp(math.floor(x + 0.5), min_x, max_x),
      z = clamp(math.floor(z + 0.5), min_z, max_z),
    }
  end

  local sites = {site("center", candidate.x, candidate.z)}
  for index = 1, #OFFSETS do
    local offset = OFFSETS[((index + rotation - 1) % #OFFSETS) + 1]
    sites[#sites + 1] = site("ring_" .. index,
      candidate.x + offset.x, candidate.z + offset.z)
  end
  return sites
end

local function distance(a, b)
  local dx = a.x - b.x
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function ecology.survey_site(site, terrain, environment)
  local columns = {}
  local column_by_key = {}
  local counts = {
    buildable = 0,
    soil = 0,
    liquid = 0,
    tree = 0,
    stone = 0,
  }
  local land_heights = {}

  for dx = -SURVEY_RADIUS, SURVEY_RADIUS, SURVEY_STEP do
    for dz = -SURVEY_RADIUS, SURVEY_RADIUS, SURVEY_STEP do
      local x, z = site.x + dx, site.z + dz
      local column = terrain.sample_column(x, z)
      if column then
        column = deep_copy(column)
        column.x, column.z = x, z
        columns[#columns + 1] = column
        column_by_key[x .. ":" .. z] = column
        if column.buildable then counts.buildable = counts.buildable + 1 end
        if column.soil then counts.soil = counts.soil + 1 end
        if column.liquid then counts.liquid = counts.liquid + 1 end
        if column.tree then counts.tree = counts.tree + 1 end
        if column.stone then counts.stone = counts.stone + 1 end
        if not column.liquid and column.y then
          land_heights[#land_heights + 1] = column.y
        end
      end
    end
  end

  local shore_anchor
  local shore_land_anchor
  local shore_distance
  local stone_anchor
  local stone_distance
  for _, column in ipairs(columns) do
    if column.liquid then
      local closest_land
      local closest_land_distance
      for _, land in ipairs(columns) do
        if land.buildable then
          local apart = distance(column, land)
          if apart <= SURVEY_STEP * math.sqrt(2) + 0.01
            and (not closest_land_distance or apart < closest_land_distance) then
            closest_land = land
            closest_land_distance = apart
          end
        end
      end
      local from_center = distance(site, column)
      if closest_land and (not shore_distance or from_center < shore_distance) then
        shore_distance = from_center
        shore_anchor = {x = column.x, y = column.y, z = column.z}
        shore_land_anchor = {x = closest_land.x, y = closest_land.y, z = closest_land.z}
      end
    end
    if column.stone then
      local from_center = distance(site, column)
      if not stone_distance or from_center < stone_distance then
        stone_distance = from_center
        stone_anchor = {x = column.x, y = column.y, z = column.z}
      end
    end
  end

  local minimum_y, maximum_y, sum_y = nil, nil, 0
  for _, y in ipairs(land_heights) do
    minimum_y = minimum_y and math.min(minimum_y, y) or y
    maximum_y = maximum_y and math.max(maximum_y, y) or y
    sum_y = sum_y + y
  end
  local average_y = #land_heights > 0 and sum_y / #land_heights or 0
  local slope_sum, slope_count = 0, 0
  for _, column in ipairs(columns) do
    if not column.liquid and column.y then
      for _, offset in ipairs({
        {x = SURVEY_STEP, z = 0},
        {x = 0, z = SURVEY_STEP},
      }) do
        local neighbour = column_by_key[
          (column.x + offset.x) .. ":" .. (column.z + offset.z)]
        if neighbour and not neighbour.liquid and neighbour.y then
          slope_sum = slope_sum + math.abs(neighbour.y - column.y)
          slope_count = slope_count + 1
        end
      end
    end
  end
  local local_slope = slope_count > 0 and slope_sum / slope_count or 0
  local sample_count = #columns
  local humidity = tonumber(environment.humidity) or 0
  if humidity > 1 then humidity = humidity / 100 end

  local direction
  if shore_anchor and shore_land_anchor then
    direction = {
      x = shore_anchor.x - shore_land_anchor.x,
      z = shore_anchor.z - shore_land_anchor.z,
    }
  end

  return {
    survey_version = 1,
    site_id = site.id,
    sample_count = sample_count,
    buildable_ratio = sample_count > 0 and counts.buildable / sample_count or 0,
    soil_ratio = sample_count > 0 and counts.soil / sample_count or 0,
    water_ratio = sample_count > 0 and counts.liquid / sample_count or 0,
    tree_ratio = sample_count > 0 and counts.tree / sample_count or 0,
    exposed_stone_ratio = sample_count > 0 and counts.stone / sample_count or 0,
    roughness = local_slope,
    average_slope = local_slope,
    elevation_range = minimum_y and maximum_y and maximum_y - minimum_y or 0,
    shore_distance = shore_distance,
    shore_anchor = shore_anchor,
    shore_land_anchor = shore_land_anchor,
    shore_direction = direction,
    stone_anchor = stone_anchor,
    elevation = average_y,
    biome_name = environment.biome_name or "unknown",
    biome_family = environment.biome_family or "temperate",
    heat = environment.heat or 50,
    humidity = humidity,
  }
end

function ecology.select_site(candidate, terrain, environment_provider)
  local pairs = {}
  local key = seed_key(candidate)
  local rx = candidate.rx or math.floor(candidate.x / perfectworld.REGION_SIZE)
  local rz = candidate.rz or math.floor(candidate.z / perfectworld.REGION_SIZE)
  local margin = perfectworld.planner.REGION_MARGIN or 80
  local min_x = rx * perfectworld.REGION_SIZE + margin
  local max_x = (rx + 1) * perfectworld.REGION_SIZE - margin - 1
  local min_z = rz * perfectworld.REGION_SIZE + margin
  local max_z = (rz + 1) * perfectworld.REGION_SIZE - margin - 1

  local function inside_region(site)
    return site.x >= min_x and site.x <= max_x
      and site.z >= min_z and site.z <= max_z
  end

  for _, site in ipairs(ecology.enumerate_sites(candidate)) do
    local center_column = terrain.sample_column(site.x, site.z)
    local environment = environment_provider(site, center_column) or {}
    local evidence = ecology.survey_site(site, terrain, environment)
    local ranked = perfectworld.settlements.evaluate_specializations(evidence)
    local scores = {}
    for _, item in ipairs(ranked) do
      scores[item.id] = {score = item.score, viable = item.viable, reasons = item.reasons}
    end
    for _, item in ipairs(ranked) do
      local selected_site = deep_copy(site)
      local center_is_land = center_column and not center_column.liquid
      -- A shoreline survey may be centred one sample step into the water.
      -- Move only fishing villages to the already measured adjacent land
      -- anchor; this adds no scan and keeps the road origin out of the sea.
      if item.id == "fishing" and not center_is_land
        and evidence.shore_land_anchor then
        selected_site.x = evidence.shore_land_anchor.x
        selected_site.z = evidence.shore_land_anchor.z
        center_is_land = true
      end
      if item.viable and center_is_land and inside_region(selected_site) then
        pairs[#pairs + 1] = {
          site = selected_site,
          survey_site = deep_copy(site),
          evidence = evidence,
          environment = deep_copy(environment),
          specialization = item.id,
          specialization_score = item.score,
          specialization_scores = scores,
          definition = item.definition,
          tie = choice.unit(key, "ecology:pair:" .. site.id .. ":" .. item.id),
        }
        break
      end
    end
  end

  table.sort(pairs, function(a, b)
    if a.specialization_score ~= b.specialization_score then
      return a.specialization_score > b.specialization_score
    end
    if a.tie ~= b.tie then return a.tie > b.tie end
    if a.site.id ~= b.site.id then return a.site.id < b.site.id end
    return a.specialization < b.specialization
  end)

  if not pairs[1] then return nil, "no_suitable_ecological_site" end
  return pairs[1]
end

return ecology
