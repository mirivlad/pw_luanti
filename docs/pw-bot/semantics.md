# Semantics

One place knows what a node means. Node-name checks scattered through a
perception layer rot the moment a game renames something, and they are
impossible to test.

## Five kinds of fact, kept apart

| Kind | Example | Where it comes from |
|------|---------|---------------------|
| node properties | `walkable`, `climbable`, `drawtype` | the engine's node definition |
| PerfectWorld role | `road_surface`, `farmland` | this project's own materials |
| interaction kind | `door`, `gate`, `container` | game conventions |
| navigation relevance | `navigation_obstacle`, `navigation_support`, `passable` | derived |
| hazard relevance | `hazard`, `lava`, `fall_hazard` | derived |

They are separate because conflating them produces wrong answers. A slab is
`walkable` and fills half a voxel. A fence is `walkable` and is taller than one.
Glass is `walkable` and see-through. "Occupies a voxel", "walkable", "collision
geometry", "selection geometry" and "visual transparency" are five different
properties and the bridge reports each of them separately.

## Node description

```json
{
  "name": "mcl_doors:door_oak_b_1",
  "param2": 0,
  "registered": true,
  "properties": {
    "walkable": true,
    "pointable": true,
    "diggable": true,
    "climbable": false,
    "buildable_to": false,
    "liquid_type": "none",
    "damage_per_second": 0,
    "light_source": 0,
    "drawtype": "nodebox",
    "paramtype": "light",
    "paramtype2": "facedir",
    "blocks_sight": false,
    "attenuates_sight": false
  },
  "selection_box_type": "fixed",
  "selection_boxes": [[-0.5, -0.5, -0.5, 0.5, 0.5, -0.313]],
  "collision_box_type": "fixed",
  "collision_boxes": [[-0.5, -0.5, -0.5, 0.5, 0.5, -0.313]],
  "groups": [{"name": "door_bottom", "value": 1}, {"name": "handy", "value": 1}],
  "semantics": ["door", "door_closed", "interactable", "navigation_obstacle",
                "navigation_support", "pointable", "structure_entrance"]
}
```

Groups are an array of `{name, value}` pairs, never a map: a Lua map would
serialise in hash order and the response would stop being canonical.

Box handling covers `regular`, `fixed`, `leveled`, `wallmounted` and `connected`
node boxes. For a connected box only the `fixed` part is reported, because that
is the only piece that is true regardless of what stands next to the node — the
rest depends on neighbours and would be a guess.

## What blocks sight

The engine's own notion of "light passes through me" is `paramtype == "light"`,
and it is the only definition-driven signal available server side. So:

* `blocks_sight` — the node stops a sight line
* `attenuates_sight` — light passes but the node is a solid-looking shape
  (glass, leaves): the ray continues and says it was dimmed

Leaves set `paramtype = "light"`, so the bridge treats them as see-through even
though a human eye would disagree. That divergence is real, documented in
[limitations.md](limitations.md), and not papered over with a name check.

An unregistered node is treated as opaque and as an obstacle. Assuming an
unknown thing is empty space is the dangerous direction to be wrong in.

## Door and gate state, read from the real convention

Mineclonia stores a door's open flag in node **metadata** (`is_open`) and
exposes `mcl_doors.is_open(pos)`. The `_b_1` / `_b_2` name suffix is the
*mirroring variant*, not the state — so a substring check would be wrong roughly
half the time. The bridge calls the game's own helper when it has a position,
and falls back to geometry only when it does not.

A fence gate is a different node when open, and that node is `walkable = false`.
That is what `gate_open` / `gate_closed` is read from.

The unit tests assert both facts directly, including that the `_1` and `_2`
variants of a door do not describe as open and closed.

## Built-in adapters

Registered from `minetest.register_on_mods_loaded`, so the definitions are
complete when they are read.

| Source | Signal | Tags |
|--------|--------|------|
| Mineclonia doors | groups `door_bottom`, `door_top` | `door`, `interactable`, `structure_entrance`, plus state |
| Mineclonia gates | group `fence_gate` | `gate`, `interactable`, plus state |
| Mineclonia fences | group `fence` | `fence`, `navigation_obstacle` |
| Mineclonia stairs | group `stair` | `stair`, `navigation_support` |
| Mineclonia slabs | group `slab` | `slab`, `navigation_support` |
| Mineclonia trapdoors | group `trapdoor` | `trapdoor`, `interactable` |
| liquids | groups `water`, `lava` and `liquidtype` | `liquid`, `water` / `lava`, `hazard` |
| farmland | group `soil` | `farmland` |
| glass, walls, beds, containers | groups | `glass`, `wall`, `bed`, `container` |
| ladders and vines | `climbable = true` | `climbable`, `ladder` |
| PerfectWorld roads | `perfectworld.compat.get_material("road")` | `road_surface`, `ground`, `navigation_support` |
| PerfectWorld paths | every family palette's `path` | `path_surface`, `ground`, `navigation_support` |
| boats | `mcl_boats:boat`, `mcl_boats:chest_boat` | `vehicle`, `boat`, `interactable` |

Road and path materials are collected from `pw_compat_mcl` rather than
hard-coded, so a palette change there follows through here without an edit.

The `dock` tag is registered and currently unused: harbours do not exist yet.
When they do, the tag is already part of the protocol's feature vocabulary.

## Registering your own

```lua
pw_bot_bridge.register_node_semantics("pw_ports:pier_deck", {"dock", "ground", "road_surface"})
pw_bot_bridge.register_group_semantics("pw_mooring", {"dock"})
pw_bot_bridge.register_entity_semantics("pw_ports:ferry", {"vehicle", "boat"})
```

Call from `minetest.register_on_mods_loaded`. Registered tags are merged with the
derived ones and returned sorted and de-duplicated. Registering clears the
resolver's cache, so a late registration takes effect immediately.

**Never add a node-name check somewhere else instead.** A future coding agent
that needs the bridge to understand a new material registers it here; that is
the whole point of the module existing.

## Features

`find_visible_feature` accepts a closed set, sorted:

```
boat, climbable, container, door, farmland, fence, gate, hazard, ladder,
liquid, path_surface, road_surface, shore, slab, stair, structure_entrance,
vehicle, water
```

An unknown feature name is `invalid_request` with the known list attached, so a
client can discover the vocabulary from a mistake.
