# Protocol `pw_bot_bridge/v1`

One envelope, one closed set of error codes, one canonical encoding. Every
channel — the Lua API, the chatcommands, the external file spool — speaks it.

## Envelope

Request:

```json
{
  "protocol": "pw_bot_bridge/v1",
  "request_id": "req-000001",
  "player_name": "pwbot",
  "operation": "observe",
  "parameters": {"profile": "navigation"}
}
```

* `protocol` — optional on the Lua API, required in practice for anything that
  wants version checking. An unknown value is `unsupported_protocol`.
  `version` is accepted as an alias.
* `request_id` — optional, `[A-Za-z0-9_-.:]`, at most 64 characters. Echoed back.
* `player_name` — optional. If present it must equal the bot being addressed;
  naming a different player is `permission_denied`. The external transport
  ignores the field entirely and uses the directory the file arrived in.
* `operation` — required, `[a-z_]` only.
* `parameters` — optional table. A flat request, with parameters at the top
  level, is also accepted.

Success:

```json
{
  "protocol": "pw_bot_bridge/v1",
  "request_id": "req-000001",
  "ok": true,
  "sequence": 42,
  "mode": "player",
  "data": {}
}
```

Failure:

```json
{
  "protocol": "pw_bot_bridge/v1",
  "request_id": "req-000001",
  "ok": false,
  "error": {
    "code": "operation_not_allowed",
    "message": "get_area is unavailable in player mode",
    "details": {"operation": "get_area", "mode": "player", "allowed": ["observe", "..."]}
  }
}
```

`code` is stable and may be branched on. `message` is for humans and may change.
`details` carries scalars and short arrays only — never a Lua error object, a
traceback, or a server filesystem path.

## Error codes

| Code | Meaning |
|------|---------|
| `invalid_request` | not a well-formed request; `details.reason` says which part |
| `unsupported_protocol` | the request names a protocol this build does not speak |
| `bot_not_registered` | no bot is registered under that player name |
| `player_not_connected` | the registered player is not connected |
| `permission_denied` | the caller may not do that |
| `operation_not_allowed` | the operation exists but not in this mode, or the bot is disabled |
| `rate_limited` | the bot exceeded its request rate; `details.retry_after_seconds` |
| `area_too_large` | the area exceeds the configured extent or node count |
| `out_of_range` | the position is outside the permitted range |
| `map_not_loaded` | the server has no data for that part of the map |
| `unknown_node` | the node name is not registered on this server |
| `unsupported_operation` | no such operation in this protocol version |
| `response_too_large` | the canonical response exceeds the size limit |
| `bridge_disabled` | the bridge is switched off in the server configuration |
| `internal_error` | a bug in the bridge; the detail is in the server log, not here |

## Operations

### Both modes

| Operation | Parameters | Answers |
|-----------|-----------|---------|
| `observe` | `profile` | the full composite observation |
| `scan_forward` `scan_left` `scan_right` `scan_up` `scan_down` | `profile` | the same channels, narrowed to a sub-sector of the field of view |
| `inspect_target` | `max_distance` | what the crosshair points at |
| `find_visible_entity` | `kind`, `tag` | visible objects, optionally filtered |
| `find_visible_feature` | `feature` | recognised features in view |
| `get_self_state` | — | proprioception only |
| `poll_events` | `after`, `max`, `reset_dropped` | the event queue |

A scan never turns the player. It restricts the reported sector to part of the
field of view that is already permitted; the real turn will be made later by a
real client.

### Oracle mode only

| Operation | Scope | Answers |
|-----------|-------|---------|
| `get_nodes` | `min`, `max` | every node in a box |
| `get_area` | `min`, `max`, `include` | a composite: nodes, collision, semantics, entities, surface, PerfectWorld records |
| `get_entities` | `min`, `max` | objects in a box, regardless of occlusion |
| `get_collision` | `position` or `min`/`max` | full normalised node properties |
| `get_surface` | `min`, `max` | ground height, standability, clearance per column |
| `get_structure` | `structure_id`, `settlement_id` or `position` | placed structures and their entrances |
| `get_structure_entrances` | same | doorways plus whether each can be stood in |
| `get_road` | `road_id`, `settlement_id` or `min`/`max` | road records and their paths |
| `get_road_topology` | same | roads plus junctions and which roads meet |
| `get_settlement` | `settlement_id`, `position` or `min`/`max` | settlement records and bounds |
| `get_lots` | `settlement_id` | plots, buildings, doors, streets |
| `inspect_position` | `position` | node, standability, and which records cover it |
| `validate_access_point` | `position`, `road_search_radius` | can a body stand here, and what is the nearest road |
| `validate_area` | `min`, `max` | physical defects (see below) |

`include` for `get_area` accepts `nodes`, `collision`, `semantics`, `entities`,
`surface`, `records`.

Every oracle operation must state a scope. A `get_road` with no `road_id`, no
`settlement_id` and no box is `invalid_request`, not "all roads everywhere".

### `validate_area` findings

| Code | Meaning |
|------|---------|
| `road_over_void` | a road cell with air beneath it |
| `road_over_liquid` | a road cell laid over water |
| `road_flooded` | the road surface itself is a liquid |
| `road_crosses_footprint` | a carriageway runs through a building's plot |
| `structure_over_void` | a building floor with nothing under it |
| `structure_over_liquid` | a building floor over water |
| `entrance_not_standable` | a doorway a body cannot occupy, with reasons |

Findings are sorted by code then position, summarised by code, and capped at 200
entries with `findings_truncated` set — the count is always complete even when
the list is not.

### Refused in player mode

An arbitrary area query is the thing `player` mode exists to prevent:

```json
{"operation": "get_nodes", "min": {"x": -100, "y": 0, "z": -100}, "max": {"x": 100, "y": 100, "z": 100}}
```

```json
{"ok": false, "error": {"code": "operation_not_allowed",
  "message": "get_nodes is unavailable in player mode"}}
```

There is no operation in either mode that changes a mode, a registration or a
privilege. That is not a check that could be forgotten; those operations do not
exist.

## Determinism

The same world state and the same request produce byte-identical canonical JSON,
except for fields documented as volatile: `timestamp`, `sequence`, `request_id`,
`budget`, and session-scoped `observation_id` values.

Guaranteed:

* object keys sorted lexicographically
* arrays in producer order, and every producer order is itself defined:
  rays by `ray_id`, entities by distance then id, tags and groups sorted,
  nodes in `y`, `z`, `x` order, findings by code then position
* groups emitted as an array of `{name, value}` pairs, never as a map, so hash
  order cannot leak in
* all non-integer numbers rounded half away from zero to **3 decimal places**,
  then formatted without trailing zeros; integers print without a decimal point
* no dependence on Lua table iteration order anywhere in a response

`pw_bot_bridge.encode_canonical(value)` gives a consumer the same encoder.

## Limits

| Setting | Default | Hard ceiling |
|---------|---------|--------------|
| `pw_bot_bridge.player_view_distance` | 48 | 128 |
| `pw_bot_bridge.player_horizontal_fov` | 100° | 180° |
| `pw_bot_bridge.player_vertical_fov` | 80° | 170° |
| `pw_bot_bridge.oracle_max_radius` | 64 | 256 |
| `pw_bot_bridge.oracle_max_nodes` | 32768 | 262144 |
| `pw_bot_bridge.max_requests_per_second` | 10 | 100 |
| `pw_bot_bridge.max_request_burst` | 20 | 200 |
| `pw_bot_bridge.event_queue_size` | 256 | 4096 |
| `pw_bot_bridge.max_response_bytes` | 262144 | 4194304 |

Per-request budgets, not configurable: 40 ms of wall clock, a node allowance
scaled to the mode, at most 64 entities, a tactile radius of 2, and a surface
strip of 12.

Rate limiting is a token bucket per bot. One token is charged before the request
is parsed, so a flood of malformed requests is still throttled; the rest of the
price is charged once the parameters are known to be legal, so an oversized area
is refused as `area_too_large` rather than as `rate_limited`. An area request
costs `1 + min(volume, oracle_max_nodes) / 4096` tokens.

Observation is request-driven. Nothing scans the map on a global step. The only
background work is a throttled sampler that, at `event_tick_interval` (0.5 s by
default), looks at each registered and connected bot's own state and the objects
within its view distance.

## Loaded, unloaded, ignore, unknown

These are four different answers and the protocol keeps them apart:

| State | Meaning |
|-------|---------|
| `loaded` | real map data |
| `not_loaded` | the server has no data there; **nothing is generated to find out** |
| `ignore` | the block exists and this node is the ignore placeholder |
| `unknown` | a real node whose name no mod on this server registered |

`get_nodes` counts all four. A ray that reaches unloaded map stops there with
`hit_type: "unloaded"` rather than claiming to see through it.

## Persistence

**Persisted** (mod storage, key `pw_bot_bridge_registry_v1`): player name, mode,
enabled flag, who registered it, when, and per-bot limit overrides.

**Not persisted**: sessions, sequence numbers, event queues, dropped counters,
observation ids, rate-limit buckets, cached observations, spool files.

After a restart the registry is read back verbatim and every bot gets a new
session: a fresh session id, `sequence` restarting at 1 on the first response,
an empty event queue, and an entity id space in which yesterday's ids address
nothing. Request files left in the spool from a previous session are moved to
`rejected/` with the reason recorded, never executed.

Storage that is malformed or of an unknown version is refused whole rather than
half-applied: a bot silently returning in the wrong mode is worse than a bot
that is not registered.
