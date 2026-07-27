-- pw_bot_bridge/protocol.lua
--
-- The wire contract. Everything that leaves the bridge — through the Lua API,
-- a chatcommand or the external transport — is wrapped in the same envelope,
-- and every failure is one of a closed set of codes.

local B = pw_bot_bridge
local canonical = B.impl.canonical
local protocol = {}
B.impl.protocol = protocol

protocol.NAME = "pw_bot_bridge"
protocol.MAJOR = 1
protocol.ID = "pw_bot_bridge/v1"

-- Implementation version of the mod itself. The protocol id above is what a
-- client negotiates against; this one only tells a human which build answered.
protocol.IMPLEMENTATION_VERSION = "1.0.0"

--- Protocol ids this build accepts on an incoming request.
protocol.ACCEPTED = {
  ["pw_bot_bridge/v1"] = true,
}

-- The closed error-code set. A caller may branch on `code`; `message` is for
-- humans and may change.
protocol.ERRORS = {
  invalid_request = "the request is not a well-formed bridge request",
  unsupported_protocol = "the request names a protocol this bridge does not speak",
  bot_not_registered = "no bot is registered under that player name",
  player_not_connected = "the registered player is not connected",
  permission_denied = "the caller may not do that",
  operation_not_allowed = "the operation is not available in the current mode",
  rate_limited = "the bot exceeded its request rate",
  area_too_large = "the requested area exceeds the configured limit",
  out_of_range = "the requested position is outside the permitted range",
  map_not_loaded = "the server has not loaded that part of the map",
  unknown_node = "the node name is not registered on this server",
  unsupported_operation = "no such operation in this protocol version",
  response_too_large = "the canonical response exceeds the configured size limit",
  bridge_disabled = "the bridge is disabled by server configuration",
  internal_error = "the bridge failed to answer",
}

function protocol.is_error_code(code)
  return protocol.ERRORS[code] ~= nil
end

function protocol.list_error_codes()
  local codes = {}
  for code in pairs(protocol.ERRORS) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  return codes
end

--- Build an error envelope.
-- `details` is a plain table of scalars; nothing derived from a Lua error
-- object, a traceback or a filesystem path ever reaches it.
function protocol.error(request_id, code, message, details)
  if not protocol.ERRORS[code] then
    code = "internal_error"
  end
  return {
    protocol = protocol.ID,
    request_id = tostring(request_id or ""),
    ok = false,
    error = {
      code = code,
      message = tostring(message or protocol.ERRORS[code]),
      details = details or {},
    },
  }
end

--- Build a success envelope.
function protocol.ok(request_id, mode, sequence, data)
  return {
    protocol = protocol.ID,
    request_id = tostring(request_id or ""),
    ok = true,
    mode = tostring(mode or ""),
    sequence = math.floor(sequence or 0),
    data = data or {},
  }
end

--- Encode an envelope to canonical JSON, refusing oversized answers.
-- The size check lives here so that no transport can be talked into writing an
-- unbounded file, and so the Lua API and the spool agree on the limit.
function protocol.encode(envelope, max_bytes)
  local text = canonical.encode(envelope)
  if max_bytes and #text > max_bytes then
    local replacement = protocol.error(envelope.request_id, "response_too_large",
      protocol.ERRORS.response_too_large,
      {size_bytes = #text, limit_bytes = max_bytes})
    return canonical.encode(replacement), replacement
  end
  return text, envelope
end

return protocol
