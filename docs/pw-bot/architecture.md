# Architecture

## Why the bridge lives inside PerfectWorld

PW Bot is not a general-purpose Luanti bot that happens to be tested here. It is
part of PerfectWorld, shipped with PerfectWorld, and versioned with it, for
three reasons that a separate project could not satisfy.

**It needs PerfectWorld's own vocabulary.** A generic bot sees
`mcl_core:coarse_dirt`. This one needs to see *road surface*, *lot*,
*structure entrance*, *settlement bounds* — concepts that only exist because
`pw_planner`, `pw_roads` and `pw_structures` created them. Those records live in
this repository's mod storage and change with this repository's planner version.

**It is the project's own measuring instrument.** Half of what the bridge is for
is finding out whether a generated village is physically sound: whether a road
hangs over a hole, whether a doorway can be stood in, whether a building floats.
That is a PerfectWorld test, and it belongs with the code it tests.

**Its correctness is defined by this world.** "Can a walker get from the street
to that door" depends on how this project lays streets and places doors. A bot
maintained elsewhere would drift out of step with the generator on the first
change to either.

So the bridge is a module of the modpack, next to `pw_debug` and `pw_tests`, and
`pw_bot` will be too.

## Why a server mod does not drive the player

The bridge could move the player. `player:set_pos()` is one call away. It must
not, and the reason is not squeamishness.

A server-side mod that teleports a player is testing the server's idea of the
world. A real client walking with real inputs is testing the world as a player
actually meets it: collision boxes, step height, the door that turns out to be
one node too high, the road that looks continuous on a map and is not. Every
interesting defect this project has found lived in that gap. Closing the gap by
having the server move the player would delete exactly the information the bot
exists to gather.

So the split is absolute:

```
perception   the server may compute        -> pw_bot_bridge
action       only a real client may take   -> a future runtime driving a real client
```

`oracle` mode does not weaken this. It widens what may be *known*; it changes
nothing about what may be *done*.

## Perception and action

| | Perception | Action |
|-|-----------|--------|
| Who | `pw_bot_bridge` (this mod) | a future runtime, driving a real Luanti client |
| Reads the map | yes | — |
| Writes the map | never | through normal gameplay only |
| Moves the player | never | yes, by pressing keys |
| Turns the head | never | yes |
| Opens a door | never | yes, by right-clicking it |
| Decides anything | never | that is `pw_bot`'s job |

The mod contains no call that moves, turns, attaches, damages or teleports a
player, and none that writes a node. `scripts/smoke-test.sh` enforces that with
a grep, so the rule survives future edits.

## The layers

```
PerfectWorld world state
        |
        v
pw_bot_bridge  (this mod)
        |
        v
player / oracle observation
        |
        v
future pw_bot memory and logic        <- not implemented
        |
        v
future real-client controller          <- not implemented
        |
        v
real Luanti client actions
```

Only the first three rows exist.

## Request flow

Every channel — the Lua API, a chatcommand, the external file spool — funnels
into one path, so there is exactly one place where a mode is enforced and one
place where a response is shaped.

```
bot registration            registry.lua      persisted: name, mode, limits
        |
        v
permission resolution       permissions.lua   pw_bot_admin, no self escalation
        |
        v
request validation          validation.lua    protocol, operation, parameters,
        |                                      area limits, rate limit
        v
   +----+----+
   |         |
player     oracle           player_perception.lua / oracle_perception.lua
provider   provider
   |         |
   +----+----+
        |
        v
semantic enrichment         semantics.lua     one registry, no scattered name checks
        |
        v
canonical response          canonical.lua     sorted keys, rounded numbers
        |
        v
Lua API  /  external transport
```

## Modules

| File | Responsibility |
|------|----------------|
| `init.lua` | Wiring and load order. No logic. |
| `canonical.lua` | Deterministic values and JSON: sorted keys, documented rounding |
| `protocol.lua` | Envelope, protocol id, closed error-code set |
| `permissions.lua` | The `pw_bot_admin` privilege, valid modes, escalation guards |
| `settings.lua` | Every tunable, each with a hard ceiling |
| `registry.lua` | Bot records, persistence, ephemeral sessions |
| `semantics.lua` | The semantic registry and normalised node properties |
| `perception.lua` | Rays, line of sight, field of view, surfaces, budgets |
| `entities.lua` | Opaque object ids and visibility filtering |
| `events.lua` | The bounded per-bot event queue and its sources |
| `player_perception.lua` | Proprioception, tactile probe, ray fans, features, surface strip |
| `oracle_perception.lua` | Exact area, collision, structure, road and settlement queries |
| `validation.lua` | The single gate: what is allowed, and how much of it |
| `capabilities.lua` | The runtime capability document |
| `api.lua` | The public, versioned Lua API |
| `transport.lua` | Optional local file spool, off by default |
| `commands.lua` | Administrative chatcommands |
| `tests/` | TestKit suite: units, scenes, integration |

## What the bridge is allowed to remember

The bridge is senses, not memory. It holds:

* the registration and its limits (persisted)
* the current session: an id, a sequence counter, a polling cursor
* opaque entity ids valid for that session
* a bounded event queue and a dropped-event counter
* a rate-limit bucket
* capability metadata

It does not hold a map of the explored world, goals, plans, routes,
preferences, a life history, or any opinion about where to go. All of that
belongs to `pw_bot`, and keeping it out of the bridge is what will let the bot
be rewritten without touching the senses.

## Extension points prepared for `pw_bot`

* `pw_bot_bridge.register_node_semantics` / `register_group_semantics` /
  `register_entity_semantics` — teach the bridge about new materials without
  editing it.
* `pw_bot_bridge.emit_event` — let a PerfectWorld subsystem tell a bot that
  something changed.
* Reserved mode names `player_debug`, `oracle_local`, `oracle_world` — declared
  in the capability document, rejected by v1, so nobody reuses them.
* `transport.lua` is an interface with one implementation; a second one can be
  added without touching a provider.
* Per-bot limit overrides, so several bots can coexist at different budgets.
