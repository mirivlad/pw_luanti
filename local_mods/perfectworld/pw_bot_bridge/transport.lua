-- pw_bot_bridge/transport.lua
--
-- A local, file-based request/response spool for a future external runtime.
--
-- The runtime that will eventually drive a real Luanti client lives outside the
-- server process and needs a way to ask the bridge questions. It must not need
-- an open port, an HTTP service or an insecure Lua environment, so v1 is a
-- directory of JSON files inside the world path:
--
--   <worldpath>/pw_bot_bridge/
--     requests/<player>/    written by the runtime, consumed by the bridge
--     responses/<player>/   written by the bridge, consumed by the runtime
--     events/<player>/      a refreshed snapshot of the pending event queue
--     state/                capability and status documents
--     rejected/             requests the bridge refused, with the reason
--
-- Security posture:
--   * off by default; a server operator must set pw_bot_bridge.external_transport
--   * only registered bots get directories, and only the bridge creates them
--   * a file name must match a strict pattern and can never contain a separator
--     or a parent reference, so no path built here escapes the spool root
--   * responses go out through minetest.safe_file_write, which writes a
--     temporary file and renames it, so a reader never sees a half-written
--     document
--   * request ids are remembered, so a file left behind by a crashed runtime is
--     not executed twice
--   * everything is bounded: file size, request count per tick, response size
--
-- What this cannot do: it cannot defend against a symlink planted inside the
-- world directory by something that already has write access there, because the
-- Lua sandbox exposes no lstat. That is an OS-level concern and is documented
-- in docs/pw-bot/security.md rather than pretended away.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local protocol = B.impl.protocol
local registry = B.impl.registry
local settings = B.impl.settings
local events = B.impl.events
local transport = {}
B.impl.transport = transport

transport.ROOT_NAME = "pw_bot_bridge"
transport.MAX_REQUESTS_PER_TICK = 8
transport.MAX_EVENTS_MIRRORED = 64

local FILE_PATTERN = "^[A-Za-z0-9_%-%.]+%.json$"

local worldpath = minetest.get_worldpath()
local root = worldpath .. "/" .. transport.ROOT_NAME

local running = false
local accumulator = 0
local ticks = 0

-- === Capability probe ===
--
-- The mod does not assume which filesystem primitives the sandbox grants; it
-- checks, and reports honestly if something it wanted is missing.

local function probe()
  return {
    mkdir = type(minetest.mkdir) == "function",
    dir_list = type(minetest.get_dir_list) == "function",
    safe_file_write = type(minetest.safe_file_write) == "function",
    io_open = type(io) == "table" and type(io.open) == "function",
    os_remove = type(os) == "table" and type(os.remove) == "function",
    os_rename = type(os) == "table" and type(os.rename) == "function",
  }
end

transport.probe = probe

--- Can the spool actually be run here?
function transport.available()
  local caps = probe()
  local missing = {}
  for _, name in ipairs({"mkdir", "dir_list", "safe_file_write", "io_open", "os_remove"}) do
    if not caps[name] then missing[#missing + 1] = name end
  end
  if #missing > 0 then
    return false, missing, caps
  end
  return true, nil, caps
end

-- === Path handling ===

local function safe_component(name)
  if type(name) ~= "string" or name == "" then return nil end
  if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
  if name:find("..", 1, true) then return nil end
  return name
end

transport.safe_component = safe_component

--- Build a path inside the spool. Every component is validated; a component
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

-- === Filesystem helpers ===

local function mkdir(path)
  if not path then return false end
  local ok = pcall(minetest.mkdir, path)
  return ok
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

local function write_file(path, content)
  local ok = pcall(minetest.safe_file_write, path, content)
  if not ok then
    minetest.log("warning", "[pw_bot_bridge] transport could not write a spool file")
    return false
  end
  return true
end

local function remove_file(path)
  pcall(os.remove, path)
end

local function list_files(path)
  local ok, entries = pcall(minetest.get_dir_list, path, false)
  if not ok or type(entries) ~= "table" then return {} end
  table.sort(entries)
  return entries
end

-- === Layout ===

function transport.ensure_layout()
  mkdir(root)
  for _, dir in ipairs({"requests", "responses", "events", "state", "rejected"}) do
    mkdir(root .. "/" .. dir)
  end
  for _, name in ipairs(registry.list_names()) do
    for _, dir in ipairs({"requests", "responses", "events"}) do
      mkdir(transport.path(dir, name))
    end
  end
  return true
end

--- A bot that is registered while the transport runs needs its directories.
function transport.ensure_bot(player_name)
  if not running then return false end
  if not registry.is_valid_player_name(player_name) then return false end
  for _, dir in ipairs({"requests", "responses", "events"}) do
    mkdir(transport.path(dir, player_name))
  end
  return true
end

--- Move anything left in the request directories out of the way at startup.
--
-- A request file that survived a restart describes a world that no longer
-- exists: its session is gone, its entity ids mean nothing, and running it
-- would answer a question nobody is still asking.
function transport.sweep_stale()
  local swept = 0
  for _, name in ipairs(registry.list_names()) do
    local dir = transport.path("requests", name)
    if dir then
      for _, file in ipairs(list_files(dir)) do
        if transport.is_valid_file_name(file) then
          local source = dir .. "/" .. file
          local content = read_file(source, settings.transport_max_request_bytes)
          local target = transport.path("rejected", name .. "." .. file)
          if target then
            write_file(target, canonical.encode({
              reason = "stale_request_from_previous_session",
              player_name = name,
              file = file,
              recovered_bytes = content and #content or 0,
            }))
          end
        end
        remove_file(dir .. "/" .. file)
        swept = swept + 1
      end
    end
  end
  if swept > 0 then
    minetest.log("action", "[pw_bot_bridge] transport swept " .. swept .. " stale request files")
  end
  return swept
end

-- === Request processing ===

local function reject(player_name, file, code, detail)
  local target = transport.path("rejected", player_name .. "." .. file)
  if target then
    write_file(target, canonical.encode({
      protocol = protocol.ID,
      player_name = player_name,
      file = file,
      error = {code = code, details = detail or {}},
    }))
  end
end

local function respond(player_name, request_id, envelope)
  local name = request_id
  if name == "" or not transport.is_valid_file_name(name .. ".json") then
    name = "response-" .. tostring(minetest.get_us_time())
  end
  local target = transport.path("responses", player_name, name .. ".json")
  if not target then return false end
  local bot = registry.raw(player_name)
  local limit = (bot and bot.limits and bot.limits.max_response_bytes) or settings.max_response_bytes
  local text = protocol.encode(envelope, limit)
  return write_file(target, text)
end

local function process_one(player_name, file)
  local dir = transport.path("requests", player_name)
  if not dir then return end
  local path = dir .. "/" .. file

  local content, read_error = read_file(path, settings.transport_max_request_bytes)
  remove_file(path)
  if not content then
    reject(player_name, file, "invalid_request", {reason = read_error})
    return
  end

  local decoded, decode_error = canonical.decode(content)
  if not decoded or type(decoded) ~= "table" then
    reject(player_name, file, "invalid_request", {reason = decode_error or "malformed_json"})
    return
  end

  -- The transport never trusts the file about who it is. The player name comes
  -- from the directory the file was found in, and a mismatch is a rejection.
  if decoded.player_name ~= nil and decoded.player_name ~= player_name then
    reject(player_name, file, "permission_denied", {reason = "player_name_mismatch"})
    return
  end
  decoded.player_name = player_name

  -- A protocol operation can never administer the bridge: set_mode, register
  -- and friends simply do not exist out here. That is what makes self
  -- escalation structurally impossible rather than merely checked.
  local envelope = B.observe(player_name, decoded, {enforce_unique_request_id = true})
  respond(player_name, tostring(decoded.request_id or ""), envelope)
end

--- Refresh the event mirror so a runtime can watch without polling the bridge.
local function mirror_events(player_name)
  local session = registry.get_session(player_name, true)
  local snapshot = events.poll(player_name, {
    after = math.max(0, session.event_sequence - transport.MAX_EVENTS_MIRRORED),
    max = transport.MAX_EVENTS_MIRRORED,
  })
  local target = transport.path("events", player_name, "pending.json")
  if not target then return end
  write_file(target, canonical.encode({
    protocol = protocol.ID,
    player_name = player_name,
    session_id = session.session_id,
    generated_at = os.time(),
    note = "read-only mirror; the authoritative cursor advances only through poll_events",
    events = snapshot.events,
    dropped = snapshot.dropped,
    queue_size = snapshot.queue_size,
    queue_capacity = snapshot.queue_capacity,
  }))
end

local function write_state()
  local target = transport.path("state", "bridge.json")
  if not target then return end
  local bots = {}
  for _, name in ipairs(registry.list_names()) do
    local info = B.get_session_info(name)
    bots[#bots + 1] = {
      player_name = name,
      mode = registry.raw(name).mode,
      enabled = registry.raw(name).enabled,
      connected = info and info.connected or false,
      session_id = info and info.session_id or canonical.NULL,
    }
  end
  write_file(target, canonical.encode({
    protocol = protocol.ID,
    generated_at = os.time(),
    capabilities = B.get_capabilities(),
    bots = #bots > 0 and bots or canonical.EMPTY_ARRAY,
  }))
end

-- === Lifecycle ===

function transport.is_running()
  return running
end

function transport.start(actor)
  if actor ~= nil then
    local allowed, reason = B.impl.permissions.can_administer(actor)
    if not allowed then return false, "permission_denied", reason end
  end
  if running then return true, {already_running = true} end
  local ok, missing = transport.available()
  if not ok then
    minetest.log("error", "[pw_bot_bridge] transport unavailable, missing: "
      .. table.concat(missing, ","))
    return false, "unavailable", missing
  end
  transport.ensure_layout()
  transport.sweep_stale()
  running = true
  write_state()
  minetest.log("action", "[pw_bot_bridge] external transport started")
  return true, {root = transport.ROOT_NAME}
end

function transport.stop(actor)
  if actor ~= nil then
    local allowed, reason = B.impl.permissions.can_administer(actor)
    if not allowed then return false, "permission_denied", reason end
  end
  running = false
  minetest.log("action", "[pw_bot_bridge] external transport stopped")
  return true
end

function transport.status()
  local ok, missing, caps = transport.available()
  return {
    enabled_by_setting = settings.external_transport,
    running = running,
    available = ok,
    missing_primitives = missing and canonical.sorted_unique(missing) or canonical.EMPTY_ARRAY,
    primitives = caps,
    requires_insecure_environment = false,
    root = transport.ROOT_NAME,
    poll_interval = settings.transport_poll_interval,
    max_request_bytes = settings.transport_max_request_bytes,
    max_requests_per_tick = transport.MAX_REQUESTS_PER_TICK,
  }
end

--- One poll pass. Exposed so a test can drive it without waiting for a tick.
function transport.tick()
  if not running then return 0 end
  ticks = ticks + 1
  local processed = 0
  for _, name in ipairs(registry.list_names()) do
    local bot = registry.raw(name)
    if bot and bot.enabled then
      local dir = transport.path("requests", name)
      if dir then
        for _, file in ipairs(list_files(dir)) do
          if processed >= transport.MAX_REQUESTS_PER_TICK then break end
          if transport.is_valid_file_name(file) then
            processed = processed + 1
            local ok, err = pcall(process_one, name, file)
            if not ok then
              minetest.log("error", "[pw_bot_bridge] transport failed on a request: " .. tostring(err))
              reject(name, file, "internal_error", {})
            end
          else
            -- Anything that is not a plain .json name never gets opened.
            reject(name, "unnamed", "invalid_request", {reason = "illegal_file_name"})
            remove_file(dir .. "/" .. file)
          end
        end
      end
      pcall(mirror_events, name)
    end
  end
  if ticks % 25 == 0 then
    pcall(write_state)
  end
  return processed
end

minetest.register_globalstep(function(dtime)
  if not settings.enabled then return end
  if not settings.external_transport then
    if running then transport.stop(nil) end
    return
  end
  if not running then
    transport.start(nil)
    if not running then
      -- Do not retry on every step if the sandbox cannot support the spool.
      settings.external_transport = false
      return
    end
  end
  accumulator = accumulator + dtime
  if accumulator < settings.transport_poll_interval then return end
  accumulator = 0
  local ok, err = pcall(transport.tick)
  if not ok then
    minetest.log("error", "[pw_bot_bridge] transport tick failed: " .. tostring(err))
  end
end)

return transport
