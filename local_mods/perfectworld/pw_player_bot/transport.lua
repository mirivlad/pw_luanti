-- pw_player_bot/transport.lua
--
-- The channel between the brain and the runtime that drives a real client.
--
-- The brain decides and the runtime acts, and they are different processes: the
-- brain lives inside the server, the runtime lives outside it and presses keys.
-- Something has to carry an intent across that gap and carry back what actually
-- happened when a real body tried to do it.
--
--   <worldpath>/pw_player_bot/
--     intents/<bot>/     written by the brain, claimed by the runtime
--     results/<bot>/     written by the runtime, ingested by the brain
--     state/             brain status, so a runtime can see it is ready
--     rejected/          results the brain refused, with the reason
--
-- Why a directory of files and not a socket: the same reasons the bridge chose
-- one. No open port, no HTTP service, no insecure Lua environment, and a
-- transcript a human can read after the fact. The spool is an interface for a
-- cooperating local runtime, not a privilege boundary against the local machine.
--
-- The result half is what makes this more than an outbox. A key press is not an
-- action; walking is. An intent is finished when the world says so, and the
-- runtime is the only thing that can report the difference between "I pressed
-- forward" and "I arrived".

local P = pw_player_bot
local bridge = pw_bot_bridge
local canonical = bridge.impl.canonical
local settings = P.impl.settings
local intent = P.impl.intent
local transport = {}
P.impl.transport = transport

transport.ROOT_NAME = "pw_player_bot"
transport.MAX_RESULTS_PER_TICK = 8
transport.MAX_RESULT_BYTES = 65536

local FILE_PATTERN = "^[A-Za-z0-9_%-%.]+%.json$"

local worldpath = minetest.get_worldpath()
local root = worldpath .. "/" .. transport.ROOT_NAME

local running = false
local accumulator = 0

-- Intent ids this brain has already seen a result for. A runtime that crashes
-- after writing a result and re-writes it on restart must not be able to make
-- the brain count the same failure twice.
local ingested = {}
local ingested_order = {}
transport.MAX_INGESTED_REMEMBERED = 512

-- === Paths ===

local function safe_component(name)
  if type(name) ~= "string" or name == "" then return nil end
  if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
  if name:find("..", 1, true) then return nil end
  return name
end

transport.safe_component = safe_component

--- Build a path inside the spool. Every component is validated, so a component
--- that fails validation yields nil rather than a path that might escape.
function transport.path(...)
  local parts = {root}
  for _, component in ipairs({...}) do
    local safe = safe_component(component)
    if not safe then return nil end
    parts[#parts + 1] = safe
  end
  return table.concat(parts, "/")
end

function transport.is_valid_file_name(name)
  if not safe_component(name) then return false end
  return name:match(FILE_PATTERN) ~= nil
end

function transport.root_path()
  return root
end

-- === Filesystem ===

local function mkdir(path)
  if not path then return false end
  return (pcall(minetest.mkdir, path))
end

local function write_file(path, content)
  if not path then return false end
  local ok = pcall(minetest.safe_file_write, path, content)
  if not ok then
    minetest.log("warning", "[pw_player_bot] transport could not write " .. tostring(path))
    return false
  end
  return true
end

local function read_file(path, max_bytes)
  local handle = io.open(path, "rb")
  if not handle then return nil, "unreadable" end
  local content = handle:read(max_bytes + 1)
  handle:close()
  if not content then return nil, "empty" end
  if #content > max_bytes then return nil, "too_large" end
  return content
end

local function remove_file(path)
  if path then pcall(os.remove, path) end
end

local function list_files(path)
  local ok, entries = pcall(minetest.get_dir_list, path, false)
  if not ok or type(entries) ~= "table" then return {} end
  table.sort(entries)
  return entries
end

transport.list_files = list_files

--- Can the spool run here at all? The mod checks rather than assumes, and says
--- so honestly when a primitive it wanted is missing.
function transport.available()
  local caps = {
    mkdir = type(minetest.mkdir) == "function",
    dir_list = type(minetest.get_dir_list) == "function",
    safe_file_write = type(minetest.safe_file_write) == "function",
    io_open = type(io) == "table" and type(io.open) == "function",
    os_remove = type(os) == "table" and type(os.remove) == "function",
  }
  local missing = {}
  for _, name in ipairs({"mkdir", "dir_list", "safe_file_write", "io_open", "os_remove"}) do
    if not caps[name] then missing[#missing + 1] = name end
  end
  if #missing > 0 then return false, missing, caps end
  return true, nil, caps
end

-- === Layout ===

function transport.ensure_layout()
  mkdir(root)
  for _, dir in ipairs({"intents", "results", "state", "rejected"}) do
    mkdir(root .. "/" .. dir)
  end
  return true
end

function transport.ensure_bot(player_name)
  if not safe_component(player_name) then return false end
  mkdir(root)
  for _, dir in ipairs({"intents", "results"}) do
    mkdir(root .. "/" .. dir)
    mkdir(transport.path(dir, player_name))
  end
  return true
end

--- Clear intents left by a previous server run.
--
-- An intent from before a restart describes a world the brain no longer
-- believes in: its memory tick is gone, its route was planned over columns that
-- may have been evicted, and the bot may not even be standing where it was.
-- Executing one would be acting on a decision nobody is still making.
function transport.sweep_stale()
  local swept = 0
  for _, dir in ipairs({"intents", "results"}) do
    local base = root .. "/" .. dir
    for _, bot in ipairs(list_files(base)) do
      local bot_dir = transport.path(dir, bot)
      if bot_dir then
        for _, file in ipairs(list_files(bot_dir)) do
          if transport.is_valid_file_name(file) then
            remove_file(bot_dir .. "/" .. file)
            swept = swept + 1
          end
        end
      end
    end
  end
  if swept > 0 then
    minetest.log("action", "[pw_player_bot] transport swept " .. swept
      .. " stale spool files from a previous run")
  end
  return swept
end

--- Keep a bot's directory bounded. The runtime is expected to claim intents; if
--- it is not running, they must not accumulate without limit.
local function prune(dir, keep)
  local files = list_files(dir)
  local excess = #files - keep
  if excess <= 0 then return 0 end
  -- list_files sorts by name, and names carry a monotonic counter, so the
  -- oldest sort first.
  for index = 1, excess do
    remove_file(dir .. "/" .. files[index])
  end
  return excess
end

transport.prune = prune

-- === Publishing an intent ===

--- Write one intent for the runtime to claim.
function transport.publish_intent(player_name, document)
  if not running then return false, "transport_not_running" end
  if type(document) ~= "table" then return false, "not_a_table" end
  local ok, reason = intent.validate(document)
  if not ok then return false, reason end

  transport.ensure_bot(player_name)
  local dir = transport.path("intents", player_name)
  if not dir then return false, "unsafe_player_name" end

  local file = document.intent_id
  if not transport.is_valid_file_name(file .. ".json") then
    return false, "unsafe_intent_id"
  end

  if not write_file(dir .. "/" .. file .. ".json", canonical.encode(document)) then
    return false, "write_failed"
  end
  prune(dir, settings.transport_max_pending_intents)
  return true
end

--- Publish what the brain currently is, so a runtime can wait for readiness
--- instead of guessing.
function transport.publish_state(player_name)
  if not running then return false end
  local status = P.get_status(player_name)
  if not status then return false end
  local path = transport.path("state", player_name .. ".json")
  if not path then return false end
  return write_file(path, canonical.encode({
    protocol = intent.PROTOCOL,
    implementation_version = intent.IMPLEMENTATION_VERSION,
    player_name = player_name,
    thinking = status.thinking,
    ticks = status.ticks,
    memory_cells = status.memory.cells,
    beliefs_ready = status.beliefs ~= canonical.NULL,
    last_intent_id = status.last_intent ~= canonical.NULL
      and status.last_intent.intent_id or canonical.NULL,
    published_at = os.time(),
  }))
end

-- === Ingesting a result ===

--- Outcomes the brain understands. A runtime that reports something outside
--- this set is telling the brain a word it does not know, which is worse than
--- telling it nothing, so the result is rejected rather than guessed at.
transport.STATUSES = {
  reached = "the target was reached and confirmed by observation",
  blocked = "something physically stopped the body",
  timeout = "the intent ran out of time",
  no_progress = "the body stopped making ground",
  fell = "the body lost height it did not mean to lose",
  entered_liquid = "the body ended up in liquid",
  lost_ground = "the body is no longer on the ground it planned over",
  blocked_head = "there is no room for the head",
  client_disconnected = "the client left the server",
  bridge_unavailable = "perception was unavailable during execution",
  brain_cancelled = "the brain withdrew the intent",
  operator_stopped = "a human stopped the run",
  unknown = "the runtime could not tell",
}

function transport.is_known_status(name)
  return transport.STATUSES[name] ~= nil
end

--- Statuses that mean the plan itself did not work out. These feed the brain's
--- failure history, which is what makes it try something else rather than
--- re-issuing the same doomed route forever.
local FAILURE_STATUSES = {
  blocked = true, timeout = true, no_progress = true,
  lost_ground = true, blocked_head = true,
}

transport.FAILURE_STATUSES = FAILURE_STATUSES

local function remember_ingested(intent_id)
  if ingested[intent_id] then return false end
  ingested[intent_id] = true
  ingested_order[#ingested_order + 1] = intent_id
  if #ingested_order > transport.MAX_INGESTED_REMEMBERED then
    local oldest = table.remove(ingested_order, 1)
    ingested[oldest] = nil
  end
  return true
end

function transport.was_ingested(intent_id)
  return ingested[intent_id] == true
end

function transport._test_reset_ingested()
  ingested, ingested_order = {}, {}
end

--- Validate a result document before letting it touch the brain.
function transport.validate_result(document)
  if type(document) ~= "table" then return false, "not_a_table" end
  if document.protocol ~= intent.PROTOCOL then return false, "wrong_protocol" end
  if type(document.intent_id) ~= "string" or document.intent_id == "" then
    return false, "missing_intent_id"
  end
  if type(document.status) ~= "string" then return false, "missing_status" end
  if not transport.is_known_status(document.status) then
    return false, "unknown_status:" .. document.status
  end
  if document.ok ~= true and document.ok ~= false then return false, "missing_ok" end
  return true
end

--- Fold one execution result into the brain.
--
-- This is the half of the loop the brain could never have on its own. It knows
-- what it decided; only the runtime knows whether a real body could do it.
function transport.ingest_result(player_name, document)
  local ok, reason = transport.validate_result(document)
  if not ok then return false, reason end
  if not remember_ingested(document.intent_id) then
    return false, "already_ingested"
  end

  local mind = P.impl.brain.get(player_name)
  if not mind then return false, "not_started" end

  mind.last_execution = {
    intent_id = document.intent_id,
    status = document.status,
    ok = document.ok == true,
    reason = document.reason or canonical.NULL,
    final_position = document.final_position or canonical.NULL,
    distance_remaining = document.distance_remaining or canonical.NULL,
    ingested_tick = mind.ticks,
  }
  mind.stats.results_ingested = (mind.stats.results_ingested or 0) + 1

  if document.ok == true and document.status == "reached" then
    mind.history = P.impl.needs.note_route_success(mind.history)
    mind.stats.results_reached = (mind.stats.results_reached or 0) + 1
  elseif FAILURE_STATUSES[document.status] then
    mind.history = P.impl.needs.note_route_failure(mind.history)
    -- The body tried and did not get there. That is exactly the condition the
    -- stuck counter exists to notice, and noticing it is what eventually
    -- promotes the unstick goal over walking into the same wall again.
    mind.history.stuck_ticks = math.min((mind.history.stuck_ticks or 0) + 1, 10)
    mind.stats.results_failed = (mind.stats.results_failed or 0) + 1
  end

  -- Whatever happened, the intent is finished. Expiring it here is what makes
  -- the brain reconsider on its next tick instead of sitting on a plan the
  -- world has already answered.
  if mind.last_intent and mind.last_intent.intent_id == document.intent_id then
    mind.intent_age = settings.intent_ttl_ticks
  end

  return true, mind.last_execution
end

--- Read every result waiting for every bot the brain is thinking for.
function transport.poll_results()
  if not running then return 0 end
  local handled = 0
  for _, player_name in ipairs(P.impl.brain.list()) do
    local dir = transport.path("results", player_name)
    if dir then
      for _, file in ipairs(list_files(dir)) do
        if handled >= transport.MAX_RESULTS_PER_TICK then break end
        local full = dir .. "/" .. file
        if transport.is_valid_file_name(file) then
          local content = read_file(full, transport.MAX_RESULT_BYTES)
          local document = content and canonical.decode(content) or nil
          local ok, reason
          if document then
            ok, reason = transport.ingest_result(player_name, document)
          else
            ok, reason = false, "malformed_json"
          end
          if not ok then
            local target = transport.path("rejected", player_name .. "." .. file)
            write_file(target, canonical.encode({
              protocol = intent.PROTOCOL,
              player_name = player_name,
              file = file,
              reason = tostring(reason),
              rejected_at = os.time(),
            }))
          end
          handled = handled + 1
        end
        remove_file(full)
      end
    end
  end
  return handled
end

-- === Lifecycle ===

function transport.is_running()
  return running
end

function transport.start()
  local ok, missing = transport.available()
  if not ok then
    return false, "unavailable", missing
  end
  transport.ensure_layout()
  transport.sweep_stale()
  for _, name in ipairs(P.impl.brain.list()) do
    transport.ensure_bot(name)
  end
  running = true
  minetest.log("action", "[pw_player_bot] intent transport started at " .. root)
  return true
end

function transport.stop()
  running = false
  minetest.log("action", "[pw_player_bot] intent transport stopped")
  return true
end

function transport.status()
  local available, missing = transport.available()
  return {
    protocol = intent.PROTOCOL,
    running = running,
    setting = settings.intent_transport,
    available = available,
    missing = missing and canonical.sorted_unique(missing) or canonical.EMPTY_ARRAY,
    root = root,
    poll_interval = settings.transport_poll_interval,
    max_pending_intents = settings.transport_max_pending_intents,
    statuses = (function()
      local out = {}
      for name in pairs(transport.STATUSES) do out[#out + 1] = name end
      table.sort(out)
      return out
    end)(),
  }
end

-- The spool polls on its own timer rather than inside the decision tick,
-- because a result arriving is not a reason to think and thinking is not a
-- reason to check the disk.
minetest.register_globalstep(function(dtime)
  if not running then return end
  accumulator = accumulator + dtime
  if accumulator < settings.transport_poll_interval then return end
  accumulator = 0
  local ok, err = pcall(transport.poll_results)
  if not ok then
    minetest.log("error", "[pw_player_bot] transport poll failed: " .. tostring(err))
  end
end)

minetest.register_on_mods_loaded(function()
  if settings.intent_transport then
    local ok, code, detail = transport.start()
    if not ok then
      minetest.log("warning", "[pw_player_bot] intent transport could not start: "
        .. tostring(code) .. " " .. minetest.write_json(detail or {}))
    end
  end
end)

return transport
