# Internal Lua API

The global `pw_bot_bridge` is the whole surface a future `pw_bot` mod may depend
on. It is also reachable as `perfectworld.bot_bridge`.

Everything under `pw_bot_bridge.impl` is private. It may change in any release
without a protocol version bump; do not read it from another mod.

```lua
local bridge = pw_bot_bridge
```

## Discovery

| Call | Returns |
|------|---------|
| `bridge.get_version()` | `"pw_bot_bridge/v1"` — the protocol id to negotiate against |
| `bridge.get_implementation_version()` | `"1.0.0"` — which build answered |
| `bridge.get_capabilities()` | the full capability document (see below) |
| `bridge.get_settings()` | the effective server settings |
| `bridge.reload_settings(actor)` | re-read settings; `ok, snapshot` or `false, code, reason` |

The capability document is how a client finds out what this server can do rather
than assuming. It lists the protocols, the modes, every operation per mode, the
ray profiles, the recognised features, the event types, the error codes, the
determinism rules, the persistence contract, the transport state and the limits.
It also states, in `contract.never` and `contract.not_provided`, what the bridge
will not do — including that there is no screenshot-based perception.

## Registration

```lua
bridge.register_bot(player_name, options, actor)  --> record | nil, code, reason
bridge.unregister_bot(player_name, actor)         --> true | false, code, reason
bridge.get_bot(player_name)                       --> record | nil
bridge.list_bots()                                --> array of records
bridge.get_mode(player_name)                      --> "player" | "oracle" | nil
bridge.set_mode(player_name, mode, actor)         --> true, record | false, code, reason
bridge.set_enabled(player_name, enabled, actor)   --> true, record | false, code, reason
bridge.set_limits(player_name, limits, actor)     --> true, record | false, code, reason
bridge.get_limits(player_name)                    --> limits, hard limits, allowed operations
bridge.get_session_info(player_name)              --> ephemeral session facts
```

`options` accepts `{mode, enabled, limits, note}`. A limit override may only
make a limit *smaller*; anything wider is clamped back to the server value.

`actor` is either a real player name, which must hold `pw_bot_admin`, or
`pw_bot_bridge.SERVER_ACTOR` for a trusted server-side caller such as another
PerfectWorld mod or the test harness. There is no third option: a missing actor
is a refusal, not an implicit grant.

A bot record:

```lua
{
  player_name = "pwbot",
  mode = "player",
  enabled = true,
  registered_by = "@server",
  created_at = 1785169000,
  updated_at = 1785169000,
  limits = { view_distance = 48, horizontal_fov = 100, ... },
  note = "autoregistered from server configuration",
}
```

## Observation

```lua
bridge.observe(player_name, request, options)       --> response envelope
bridge.observe_json(player_name, request, options)  --> canonical JSON, envelope
bridge.validate_request(player_name, request)       --> ok, envelope
bridge.poll_events(player_name, options)            --> response envelope
```

`observe` always returns an envelope, never raises, and never returns a Lua
error to the caller. A bug inside the bridge is logged in full on the server and
leaves as a bare `internal_error`.

`validate_request` is a dry run: it checks the protocol, the mode, the
operation, the parameters and the limits, and reports the estimated token cost,
without touching the map. It deliberately does **not** require the player to be
connected, so a client can check a request before its bot joins.

A request may be the full envelope or a flat table; both are accepted.

```lua
local envelope = bridge.observe("pwbot", {
  protocol = "pw_bot_bridge/v1",
  request_id = "req-0001",
  operation = "observe",
  parameters = {profile = "navigation"},
})

-- equivalently
local envelope = bridge.observe("pwbot", {operation = "observe", profile = "navigation"})
```

`options.enforce_unique_request_id` makes a repeated request id an error. The
external transport sets it, so a request file left behind by a crashed runtime
cannot be executed twice.

## Events

```lua
bridge.emit_event(player_name, event_type, payload, actor)  --> true, sequence | false, code
```

Available to other server-side mods so a PerfectWorld subsystem can tell a bot
that something changed. The event type must be one of the declared types;
emitting requires authorisation.

Reading events goes through `poll_events`, which is an ordinary protocol
operation available in both modes.

## Semantics

```lua
bridge.register_node_semantics(node_name, tags)
bridge.register_group_semantics(group_name, tags)
bridge.register_entity_semantics(entity_name, tags)
bridge.describe_node(node_name, param2, pos)   --> normalised description
bridge.get_node_semantics(node_name)           --> sorted tag array
```

Register from `minetest.register_on_mods_loaded` so the node definitions the
bridge reads are complete. See [semantics.md](semantics.md).

## Constants

```lua
bridge.PROTOCOL      -- "pw_bot_bridge/v1"
bridge.SERVER_ACTOR  -- "@server"
bridge.ADMIN_PRIV    -- "pw_bot_admin"
bridge.MODES         -- {"oracle", "player"}
bridge.ERROR_CODES   -- sorted array of every error code
bridge.NULL          -- the JSON null sentinel
bridge.EMPTY_ARRAY   -- the empty-array sentinel
```

`bridge.encode_canonical(value)` produces the same bytes the bridge would, which
matters when a consumer writes a report that has to compare against one.

`NULL` and `EMPTY_ARRAY` exist because Lua cannot store `nil` in a table and
cannot tell an empty array from an empty object. A field set to `bridge.NULL`
means "this exists and is empty"; a field that is absent means the schema says
it is absent.

## Worked example

```lua
minetest.register_on_mods_loaded(function()
  local bridge = pw_bot_bridge
  if not bridge or bridge.get_version() ~= "pw_bot_bridge/v1" then return end

  bridge.register_bot("pwbot", {mode = "player"}, bridge.SERVER_ACTOR)

  local envelope = bridge.observe("pwbot", {operation = "observe", profile = "navigation"})
  if not envelope.ok then
    minetest.log("warning", "observation refused: " .. envelope.error.code)
    return
  end

  local state = envelope.data.self_state
  minetest.log("action", string.format("pwbot at %.1f,%.1f,%.1f on_ground=%s",
    state.position.x, state.position.y, state.position.z, tostring(state.on_ground)))

  for _, ray in ipairs(envelope.data.rays) do
    if ray.hit_type == "node" and ray.distance < 2 then
      minetest.log("action", "obstacle on " .. ray.ray_id .. ": " .. ray.node.name)
    end
  end
end)
```

## What the API deliberately does not offer

There is no call that moves, turns, teleports, attaches or damages a player, no
call that places or removes a node, and no protocol operation that changes a
mode or a privilege. Those absences are the design, not an oversight.
