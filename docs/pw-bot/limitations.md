# Limitations

Stated plainly, because a perception layer that overclaims is worse than one
that reports less.

## Not implemented

PW Bot does not exist. None of this is built:

* client control of any kind
* Xvfb, Xephyr, a `--visible` mode
* movement, navigation, route planning
* bot memory
* utility AI, behaviour, decision making
* building, NPCs
* any LLM integration
* computer vision, screenshot analysis

What exists is `pw_bot_bridge`: the server-side senses, and nothing else.

## Screenshots are not vision

A screenshot is not the bot's perception and is not planned to become it. The
bridge reads the server's world state. Screenshots stay what they are in this
project today: a diagnostic artifact produced for a human to look at.

## Player mode is an approximation, not a screen

The server does not reproduce a client's frame. It cannot.

| Known to the server | Not known to the server |
|---------------------|-------------------------|
| position, yaw, pitch | the client's FOV setting |
| loaded nodes | which mapblocks the client actually received |
| tracked objects | what the renderer drew |
| line-of-sight geometry | occlusion culling decisions |
| node definitions | texture pack, transparency, shaders |

`player` mode is therefore defined as a *deterministic server-side approximation
of the programmatic perception available to a player, bounded by position, look
direction, field of view, view distance and line of sight*. That definition is
testable. "What is on the screen" would not be.

Concretely:

* the field of view is a server setting (100° × 80° by default), not the
  client's
* the view distance is a server setting (48 nodes), not the client's render
  distance
* the loaded area is not the drawn area

## What blocks sight, and where that diverges

Occlusion uses the engine's own light-transparency signal, `paramtype == "light"`.
This is right for stone, glass and air. It is **wrong for leaves**: leaves set
`paramtype = "light"`, so the bridge treats a tree canopy as see-through where a
human eye would not.

The alternative would be a hard-coded list of node names, which is exactly the
failure mode the semantic registry exists to prevent. The divergence is accepted
and recorded rather than patched over. A node whose visual density matters can be
registered explicitly if it becomes a problem in practice.

Nodes that pass light but are plainly visible — a closed door, a pane of glass, a
ladder — are reported in each ray's `passed_nodes`, up to four per ray. Beyond
that cap a ray reports only its terminal hit.

## Derived values

Luanti exposes no server-side ground flag for players. `on_ground` is inferred
from the node under the feet and the vertical velocity, and the response says so
in `on_ground_source`. A consumer that needs certainty should not trust it
blindly.

Fields the server API genuinely cannot answer are reported as
`{"available": false, "reason": "unsupported_by_server_api"}` rather than
guessed.

## Selection box, collision box and voxel occupancy are three things

The bridge reports them separately and never conflates them. For a `connected`
node box only the `fixed` part is reported, because the rest depends on
neighbouring nodes and anything else would be a guess.

## Surfaces

A downward column scan cannot distinguish the roof of a covered passage from a
ledge of the same height, because they are the same shape. The bridge reports
both readings: `ground_y` (the highest place with room to stand) and `top_y` /
`standable_y` (the highest solid node). Which one matters is the consumer's call.

Liquids count as surfaces. Reporting the stone under the water would hide the one
fact a walker most needs.

## Budgets truncate

A request that exhausts its node or time budget returns a partial answer with
`truncated: true` and `budget.truncated_reason`. The wide feature sweep is built
last, so what degrades first is the least essential channel; proprioception, the
tactile probe and the surface strip are built first and are effectively never
truncated. A partial answer is always labelled — it is never presented as
complete.

`validate_area` caps its finding *list* at 200 entries, but `finding_count` and
`findings_by_code` remain complete.

## Feature search is a sweep, not an index

`find_visible_feature` casts a dense fan across the permitted sector and reports
what it strikes. A feature small enough to fall between rays can be missed. It is
a perception primitive, not a database query — which is the honest shape for
something claiming to model sight.

## No pathfinding

The bridge answers "where is the road, where is the door, can the threshold be
stood in". It does not answer "how do I get there". Routing belongs to `pw_bot`.

## Persistence boundary

Registrations survive a restart. Sessions, sequence numbers, event queues,
observation ids and rate-limit state do not, by design. An `observation_id` from
before a restart or a reconnection addresses nothing, and a consumer that cached
one must discard it when the session id changes.

## Events are sampled, not continuous

The background sampler runs at `event_tick_interval` (0.5 s by default). A
change that appears and disappears inside one interval is not observed. This is
deliberate: an event per server step would be both useless and expensive.

The queue is bounded. On overflow the oldest events are dropped and counted in
`dropped` — a consumer can always tell that it missed something, but not what.

## Transport

The file spool is local, off by default, and needs no insecure environment. It
cannot defend against a symlink planted inside the world directory by something
that already has write access there, because the Lua sandbox exposes no `lstat`.
That is an OS-level concern, described in [security.md](security.md).

The spool is an interface for a cooperating local runtime. It is not a privilege
boundary against the local machine.

## Scale

Tested with one registered bot. The design is per-bot throughout — registry,
session, queue, rate bucket, limits — so several should work, but "should" is
not "tested", and that is the honest word for it.
