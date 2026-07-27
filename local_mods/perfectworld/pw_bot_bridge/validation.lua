-- pw_bot_bridge/validation.lua
--
-- Everything a request must survive before any map is touched.
--
-- Validation is deliberately the only place that decides an operation is
-- allowed. A provider never asks "am I in oracle mode?" — by the time it runs,
-- that question has already been answered here, once, in one place.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local protocol = B.impl.protocol
local permissions = B.impl.permissions
local registry = B.impl.registry
local settings = B.impl.settings
local player_perception = B.impl.player_perception
local oracle = B.impl.oracle_perception
local validation = {}
B.impl.validation = validation

validation.MAX_REQUEST_ID_LENGTH = 64
validation.RECENT_REQUEST_IDS = 256

--- Operations, by the mode that may run them.
--
-- Oracle is a superset in capability but not in shape: an oracle bot still gets
-- the player-perception operations, because a diagnostic run often wants to
-- compare what the bot could see with what is really there.
local function operations_for(mode)
  if mode == "oracle" then
    local out = {}
    for _, name in ipairs(player_perception.list_operations()) do out[#out + 1] = name end
    for _, name in ipairs(oracle.list_operations()) do out[#out + 1] = name end
    return canonical.sorted_unique(out)
  end
  return canonical.sorted_unique(player_perception.list_operations())
end

validation.operations_for = operations_for

local function is_allowed(mode, operation)
  for _, name in ipairs(operations_for(mode)) do
    if name == operation then return true end
  end
  return false
end

validation.is_allowed = is_allowed

--- Every operation this build knows about, in any mode. Used to tell
--- "unknown operation" from "operation you may not run", which are different
--- failures and deserve different codes.
local function is_known_operation(operation)
  return is_allowed("oracle", operation)
end

-- === Primitive checks ===

local COORD_LIMIT = 31000   -- Luanti's own map edge

local function check_vector(value, label)
  if type(value) ~= "table" then
    return nil, label .. "_missing"
  end
  local out = {}
  for _, axis in ipairs({"x", "y", "z"}) do
    local n = tonumber(value[axis])
    if not n or n ~= n then return nil, label .. "_" .. axis .. "_not_a_number" end
    if n < -COORD_LIMIT or n > COORD_LIMIT then return nil, label .. "_" .. axis .. "_out_of_world" end
    out[axis] = n
  end
  return out
end

validation.check_vector = check_vector

local function check_node_vector(value, label)
  local vector, err = check_vector(value, label)
  if not vector then return nil, err end
  return {
    x = math.floor(vector.x + 0.5),
    y = math.floor(vector.y + 0.5),
    z = math.floor(vector.z + 0.5),
  }
end

validation.check_node_vector = check_node_vector

-- === Rate limiting ===
--
-- A token bucket per bot. Sustained rate and burst both come from the bot's
-- limits, so an administrator can slow one noisy bot without touching the
-- server-wide setting.

function validation.check_rate(bot, session, cost)
  cost = cost or 1
  local rate = bot.limits.max_requests_per_second or settings.max_requests_per_second
  local burst = bot.limits.max_request_burst or settings.max_request_burst
  local now = minetest.get_us_time()
  if not session.rate_tokens then
    session.rate_tokens = burst
    session.rate_checked_us = now
  end
  local elapsed = math.max(0, (now - session.rate_checked_us) / 1000000)
  session.rate_checked_us = now
  session.rate_tokens = math.min(burst, session.rate_tokens + elapsed * rate)
  if session.rate_tokens < cost then
    local wait = (cost - session.rate_tokens) / rate
    return false, {
      tokens_available = canonical.round(session.rate_tokens),
      cost = cost,
      rate_per_second = rate,
      burst = burst,
      retry_after_seconds = canonical.round(wait),
    }
  end
  session.rate_tokens = session.rate_tokens - cost
  return true
end

--- What a request costs in tokens.
--
-- Reading one node is cheap; reading a chunk of the map is not, and the price
-- has to reflect that or a rate limit does nothing useful. The price is capped
-- by the largest area the bot is *allowed* to ask for, so an oversized request
-- is refused as area_too_large — its real fault — rather than as rate_limited.
function validation.request_cost(operation, params, limits)
  if params and type(params.min) == "table" and type(params.max) == "table" then
    local ok, volume = pcall(oracle.volume, params.min, params.max)
    if ok and volume then
      local ceiling = (limits and limits.oracle_max_nodes) or settings.oracle_max_nodes
      return 1 + math.floor(math.min(volume, ceiling) / 4096)
    end
    return 1
  end
  if operation == "observe" or operation:sub(1, 5) == "scan_"
    or operation == "find_visible_feature" then
    return 2
  end
  return 1
end

-- === Duplicate and stale request ids ===
--
-- Only the external transport needs this: a file left behind by a crashed
-- runtime must not be executed twice just because it reappeared.

function validation.note_request_id(session, request_id)
  session.recent_request_ids = session.recent_request_ids or {}
  session.recent_request_order = session.recent_request_order or {}
  if session.recent_request_ids[request_id] then
    return false
  end
  session.recent_request_ids[request_id] = true
  local order = session.recent_request_order
  order[#order + 1] = request_id
  if #order > validation.RECENT_REQUEST_IDS then
    local oldest = table.remove(order, 1)
    session.recent_request_ids[oldest] = nil
  end
  return true
end

-- === Request normalisation ===

--- Turn whatever the caller handed us into a canonical request table.
--
-- Accepts both the full envelope and the bare `{operation = ..., ...}` shape
-- the Lua API is convenient with. Returns request, error_code, detail.
function validation.normalize(player_name, raw)
  if type(raw) ~= "table" then
    return nil, "invalid_request", {reason = "request_must_be_a_table"}
  end

  local declared = raw.protocol or raw.version
  if declared ~= nil then
    if type(declared) ~= "string" or not protocol.ACCEPTED[declared] then
      return nil, "unsupported_protocol", {
        requested = tostring(declared),
        supported = {protocol.ID},
      }
    end
  end

  local request_id = raw.request_id
  if request_id ~= nil then
    if type(request_id) ~= "string" and type(request_id) ~= "number" then
      return nil, "invalid_request", {reason = "request_id_must_be_a_string"}
    end
    request_id = tostring(request_id)
    if #request_id > validation.MAX_REQUEST_ID_LENGTH then
      return nil, "invalid_request", {reason = "request_id_too_long"}
    end
    if not request_id:match("^[A-Za-z0-9_%-%.:]+$") then
      return nil, "invalid_request", {reason = "request_id_has_illegal_characters"}
    end
  else
    request_id = ""
  end

  -- A request may name a player, but it may never name a *different* player:
  -- that is how one bot would read another's oracle data.
  if raw.player_name ~= nil then
    if type(raw.player_name) ~= "string" or raw.player_name ~= player_name then
      return nil, "permission_denied", {reason = "player_name_mismatch"}
    end
  end

  local operation = raw.operation
  if type(operation) ~= "string" or operation == "" then
    return nil, "invalid_request", {reason = "operation_missing"}
  end
  if not operation:match("^[a-z_]+$") then
    return nil, "invalid_request", {reason = "operation_has_illegal_characters"}
  end

  local params = raw.parameters or raw.params
  if params == nil then
    -- Tolerate the flat shape: everything that is not an envelope field is a
    -- parameter. It keeps hand-written requests readable.
    params = {}
    for key, value in pairs(raw) do
      if key ~= "protocol" and key ~= "version" and key ~= "request_id"
        and key ~= "player_name" and key ~= "operation" then
        params[key] = value
      end
    end
  elseif type(params) ~= "table" then
    return nil, "invalid_request", {reason = "parameters_must_be_a_table"}
  end

  return {
    protocol = protocol.ID,
    request_id = request_id,
    player_name = player_name,
    operation = operation,
    parameters = params,
  }
end

-- === Parameter validation per operation ===

local function require_area(params, limits, mode)
  local min, err = check_node_vector(params.min, "min")
  if not min then return nil, "invalid_request", {reason = err} end
  local max, err2 = check_node_vector(params.max, "max")
  if not max then return nil, "invalid_request", {reason = err2} end
  local a, b = oracle.sorted_box(min, max)
  local extent = math.max(b.x - a.x, b.y - a.y, b.z - a.z) + 1
  if extent > limits.oracle_max_radius * 2 then
    return nil, "area_too_large", {
      extent = extent,
      max_extent = limits.oracle_max_radius * 2,
    }
  end
  local volume = oracle.volume(a, b)
  if volume > limits.oracle_max_nodes then
    return nil, "area_too_large", {
      volume = volume,
      max_nodes = limits.oracle_max_nodes,
    }
  end
  params.min, params.max = a, b
  return true
end

local AREA_OPERATIONS = {
  get_nodes = true, get_area = true, get_entities = true,
  get_surface = true, validate_area = true,
}

local POSITION_OPERATIONS = {
  inspect_position = true, validate_access_point = true,
}

--- Check the parameters of an operation that has already passed the mode gate.
function validation.check_parameters(request, bot, mode)
  local operation = request.operation
  local params = request.parameters
  local limits = bot.limits

  if AREA_OPERATIONS[operation] then
    local ok, code, detail = require_area(params, limits, mode)
    if not ok then return nil, code, detail end
  end

  if POSITION_OPERATIONS[operation] then
    local position, err = check_node_vector(params.position, "position")
    if not position then return nil, "invalid_request", {reason = err} end
    params.position = position
  end

  if operation == "get_collision" then
    if params.position ~= nil then
      local position, err = check_node_vector(params.position, "position")
      if not position then return nil, "invalid_request", {reason = err} end
      params.position = position
    else
      local ok, code, detail = require_area(params, limits, mode)
      if not ok then return nil, code, detail end
      if oracle.volume(params.min, params.max) > 4096 then
        return nil, "area_too_large", {volume = oracle.volume(params.min, params.max), max_nodes = 4096}
      end
    end
  end

  if operation == "get_structure" or operation == "get_structure_entrances" then
    if params.structure_id == nil and params.settlement_id == nil and params.position == nil then
      return nil, "invalid_request", {reason = "scope_required_structure_id_settlement_id_or_position"}
    end
    if params.position ~= nil then
      local position, err = check_node_vector(params.position, "position")
      if not position then return nil, "invalid_request", {reason = err} end
      params.position = position
    end
  end

  if operation == "get_road" or operation == "get_road_topology" then
    if params.road_id == nil and params.settlement_id == nil
      and (params.min == nil or params.max == nil) then
      return nil, "invalid_request", {reason = "scope_required_road_id_settlement_id_or_area"}
    end
    if params.min ~= nil and params.max ~= nil then
      local ok, code, detail = require_area(params, limits, mode)
      if not ok then return nil, code, detail end
    end
  end

  if operation == "get_lots" then
    if type(params.settlement_id) ~= "string" then
      return nil, "invalid_request", {reason = "settlement_id_required"}
    end
  end

  for _, key in ipairs({"structure_id", "settlement_id", "road_id"}) do
    local value = params[key]
    if value ~= nil then
      if type(value) ~= "string" or #value > 128 or not value:match("^[A-Za-z0-9_%-:%.]+$") then
        return nil, "invalid_request", {reason = key .. "_invalid"}
      end
    end
  end

  if params.profile ~= nil then
    if not player_perception.is_profile(params.profile) then
      return nil, "invalid_request", {
        reason = "unknown_profile",
        known = player_perception.list_profiles(),
      }
    end
  end

  if operation == "find_visible_feature" and params.feature ~= nil then
    if type(params.feature) ~= "string" then
      return nil, "invalid_request", {reason = "feature_must_be_a_string"}
    end
    if not B.impl.semantics.is_known_feature(params.feature) then
      return nil, "invalid_request", {
        reason = "unknown_feature",
        known = B.impl.semantics.FEATURES,
      }
    end
  end

  if operation == "find_visible_entity" then
    for _, key in ipairs({"kind", "tag"}) do
      if params[key] ~= nil and type(params[key]) ~= "string" then
        return nil, "invalid_request", {reason = key .. "_must_be_a_string"}
      end
    end
  end

  if params.include ~= nil then
    if type(params.include) ~= "table" then
      return nil, "invalid_request", {reason = "include_must_be_an_array"}
    end
    local allowed = {
      nodes = true, collision = true, semantics = true,
      entities = true, surface = true, records = true,
    }
    for _, name in ipairs(params.include) do
      if not allowed[name] then
        return nil, "invalid_request", {reason = "unknown_include:" .. tostring(name)}
      end
    end
  end

  return true
end

-- === The whole gate ===

--- Resolve a request into everything a provider needs, or into an error code.
--
-- Returns context, error_code, detail. Context carries the bot record, the
-- session, the player object and the validated request.
function validation.resolve(player_name, raw, options)
  options = options or {}

  if not settings.enabled then
    return nil, "bridge_disabled", {}
  end

  if not registry.is_valid_player_name(player_name) then
    return nil, "invalid_request", {reason = "invalid_player_name"}
  end

  local request, code, detail = validation.normalize(player_name, raw)
  if not request then return nil, code, detail end

  local bot = registry.raw(player_name)
  if not bot then
    return nil, "bot_not_registered", {player_name = player_name}
  end
  if not bot.enabled then
    return nil, "operation_not_allowed", {reason = "bot_disabled"}
  end

  local mode = bot.mode
  if not permissions.is_valid_mode(mode) then
    return nil, "internal_error", {reason = "registered_mode_is_not_valid"}
  end

  if request.operation ~= "poll_events" and not is_allowed(mode, request.operation) then
    if is_known_operation(request.operation) then
      return nil, "operation_not_allowed", {
        operation = request.operation,
        mode = mode,
        message = request.operation .. " is unavailable in " .. mode .. " mode",
        allowed = operations_for(mode),
      }
    end
    return nil, "unsupported_operation", {
      operation = request.operation,
      supported = operations_for(mode),
    }
  end

  local session = registry.get_session(player_name, true)

  if options.enforce_unique_request_id and request.request_id ~= "" then
    if not validation.note_request_id(session, request.request_id) then
      return nil, "invalid_request", {reason = "duplicate_request_id"}
    end
  end

  -- Rate limiting happens in two bites. One token is charged up front, so a
  -- flood of malformed requests is still throttled; the rest of the price is
  -- charged once the parameters are known to be legal, so an illegal request
  -- gets the code that names its actual fault.
  local ok, rate_detail = validation.check_rate(bot, session, 1)
  if not ok then
    session.requests_rejected = session.requests_rejected + 1
    return nil, "rate_limited", rate_detail
  end

  -- Parameters are a property of the request alone, so they are judged before
  -- anything about the player is consulted.
  local checked, param_code, param_detail = validation.check_parameters(request, bot, mode)
  if not checked then
    return nil, param_code, param_detail
  end

  local remaining = validation.request_cost(request.operation, request.parameters, bot.limits) - 1
  if remaining > 0 then
    local rest_ok, rest_detail = validation.check_rate(bot, session, remaining)
    if not rest_ok then
      session.requests_rejected = session.requests_rejected + 1
      return nil, "rate_limited", rest_detail
    end
  end

  local player = minetest.get_player_by_name(player_name)
  if not player and not options.skip_player_check then
    return nil, "player_not_connected", {player_name = player_name}
  end

  return {
    request = request,
    bot = bot,
    mode = mode,
    session = session,
    player = player,
  }
end

--- Limits a caller may inspect without running anything.
function validation.limits_for(player_name)
  local bot = registry.raw(player_name)
  if not bot then return nil end
  return {
    player_name = player_name,
    mode = bot.mode,
    limits = perfectworld.core.deep_copy(bot.limits),
    hard_limits = {
      request_budget_us = settings.HARD.request_budget_us,
      tactile_radius = settings.HARD.tactile_radius,
      surface_profile_length = settings.HARD.surface_profile_length,
      max_entities = settings.HARD.max_entities,
    },
    allowed_operations = operations_for(bot.mode),
    ray_profiles = player_perception.list_profiles(),
  }
end

return validation
