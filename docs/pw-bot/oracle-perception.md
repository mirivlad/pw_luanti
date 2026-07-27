# Oracle perception

`oracle` mode answers exactly, within configured limits. It exists for the test
kit, for a coding agent, and for finding physical defects in generated villages
— the questions where an approximation of what a player could see is exactly the
wrong tool.

**It still only reads.** No node is placed, no player is moved, no door is
opened, and no map block is generated on demand. Oracle changes how much may be
*known*; it changes nothing about what may be *done*.

## Who gets it

Nobody, by default. A mode is granted by the server: through
`pw_bot_bridge.autoregister` in the configuration, by an administrator holding
`pw_bot_admin`, or by the test harness through the trusted server actor. A bot
cannot promote itself, and there is no protocol operation that would let it try.

## What it is for

* the TestKit
* a coding agent inspecting generated output
* generator diagnostics
* checking villages, roads, lots and entrances
* checking future ports and docks
* checking future routes
* finding physical defects

## Operations

### Raw world

| Operation | Answers |
|-----------|---------|
| `get_nodes` | every node in a box, with `include_air` and `include_unloaded` |
| `get_area` | a composite: `nodes`, `collision`, `semantics`, `entities`, `surface`, `records` |
| `get_entities` | objects in a box, regardless of occlusion |
| `get_collision` | full normalised properties for a position or a small box |
| `get_surface` | per column: ground height, the standable level, clearance, liquid |
| `inspect_position` | one position, in full, plus which records cover it |

```json
{
  "protocol": "pw_bot_bridge/v1",
  "request_id": "req-1001",
  "operation": "get_area",
  "parameters": {
    "min": {"x": 100, "y": 50, "z": 100},
    "max": {"x": 120, "y": 75, "z": 120},
    "include": ["nodes", "collision", "semantics"]
  }
}
```

`get_surface` reports `ground_y` (the exact topmost surface) and `standable_y`
(the highest level with room to stand) separately, because an overhang is a
surface with no standing room under it, and a diagnostic needs both.

### PerfectWorld records

| Operation | Answers |
|-----------|---------|
| `get_settlement` | settlement records, bounds, structure and road ids, recorded errors |
| `get_lots` | plots: footprint, role, building, rotation, door, street |
| `get_structure` | placed structures: footprint, rotation, position, entrances |
| `get_structure_entrances` | doorways plus whether each threshold can be stood in |
| `get_road` | road records and their full paths |
| `get_road_topology` | roads, junction cells, and which roads meet at each |

Entrances come from two independent sources and the answer says which one
spoke: `settlement_plan` (the threshold the builder actually laid) and
`structure_connector` (the structure definition's road connector, rotated by the
placed rotation). Reporting both, and labelling them, keeps a diagnostic honest
about what it actually knows.

### Verdicts

| Operation | Answers |
|-----------|---------|
| `validate_access_point` | can a body stand here, why not if not, and the nearest road |
| `validate_area` | physical defects across an area |

`validate_area` codes:

| Code | Question it answers |
|------|---------------------|
| `road_over_void` | does the road hang in the air? |
| `road_over_liquid` | is the road laid over water? |
| `road_flooded` | is the road surface itself a liquid? |
| `road_crosses_footprint` | does a carriageway run through a building's plot? |
| `structure_over_void` | does the building stand on nothing? |
| `structure_over_liquid` | is the plot flooded? |
| `entrance_not_standable` | can a walker occupy the doorway? with reasons |

`access` verdicts name their reasons rather than returning a bare boolean:
`no_support_below`, `feet_blocked`, `head_blocked`, `flooded`, `damaging`,
`support_not_loaded`, `support_ignore`.

## Questions a future test bot can answer with this

Together the operations above are enough to determine, without a pathfinder:

* where a road runs, and how wide
* where a lot begins and ends
* where the approach to a door is
* where the door is
* whether the threshold can be stood in
* whether there is a step, and how high
* whether the road follows the ground or hangs above it
* whether a plot is flooded
* whether a structure stands over void
* whether a road crosses a footprint
* where a boat is
* which harbour it belongs to, once harbours exist

A full pathfinder is deliberately out of scope for this stage. The bridge
provides the facts; routing them is `pw_bot`'s work.

## Scope is mandatory

Every oracle operation must state a scope: a box, a `settlement_id`, a
`structure_id`, a `road_id` or a `position`. A `get_road` with none of them is
`invalid_request`, not "every road in the world".

## Limits

| Limit | Default | Ceiling |
|-------|---------|---------|
| box extent | 128 nodes (2 × `oracle_max_radius`) | 512 |
| node count | 32768 | 262144 |
| `get_collision` box | 4096 nodes | — |
| entities per response | 64 | — |
| response size | 256 KB | 4 MB |
| wall clock per request | 40 ms | — |

Exceeding an area limit is `area_too_large`, with the measured `volume` or
`extent` and the limit that stopped it. Exhausting the per-request node or time
budget is not an error: the response carries `truncated: true` and
`budget.truncated_reason`, so a partial answer is never mistaken for a complete
one.

An area request costs `1 + min(volume, oracle_max_nodes) / 4096` rate-limit
tokens, so a legal maximum request costs 9 of the default burst of 20.

## Loaded, unloaded, ignore, unknown

Oracle mode is where this distinction matters most, and it is never blurred:

```json
{"counts": {"air": 120, "solid": 45, "not_loaded": 0, "ignore": 0, "unknown": 0}}
```

A position the server has not loaded is reported as `not_loaded`. The bridge
does **not** generate it to find out, and reads the map only through
`minetest.get_node_or_nil`, which never triggers emerge. Asking about an
unvisited region gives you an honest "no data", which is itself a useful
diagnostic answer.
