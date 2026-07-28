# Limitations

Stated plainly, because a perception layer that overclaims is worse than one
that reports less.

## Not implemented

`pw_bot_runtime` executes intents through a real client: it walks, turns, climbs
stairs, and opens doors, fence gates and trapdoors, all measured against the
obstacle course in `pw_debug/bot_course.lua`. None of the following is built:

* **errands** — no goal goes somewhere in order to do something. `interact` is
  in the intent vocabulary and the runtime performs it; no goal emits it, so in
  a normal closed-loop run the bot explores and never uses anything
* building, crafting, fighting, trading, NPCs
* any LLM integration
* computer vision, screenshot analysis

The body is also the most fragile layer. It depends on frame rate, key hold
duration, X11 focus, the client's key bindings, the hotbar's contents and this
particular Luanti version — a press too short is lost between frames, and one
too long opens a door and closes it again. It is a real body for experiments,
not a portable client. What keeps it honest is that every action is checked
against the bridge afterwards rather than assumed to have worked.

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

## No pathfinding in the bridge

The bridge answers "where is the road, where is the door, can the threshold be
stood in". It does not answer "how do I get there". Routing lives in
`pw_player_bot`, over remembered cells only.

## The brain: what it cannot do

* **It never acts.** No movement, no turning, no interaction, no node change. It
  writes an intent and stops. Nothing reads that intent yet.
* **It routes over belief, not over the world.** A route crosses only columns the
  bot personally observed. Where the belief is wrong — because someone dug a
  hole, or because a glimpse was misread — the route is wrong with it. The usual
  answer to "why did it not go there" is `goal_not_remembered`: it has never seen
  the way.
* **Memory is approximate.** Eviction is a one-pass approximate LRU, not an exact
  one. Staleness is reported, never corrected: memory says when it last looked,
  not what is there now.
* **It has no goals beyond seven.** Explore, approach, retreat, leave liquid,
  look, unstick, stand still. No errands, no schedule, no social behaviour, no
  long-horizon plan. There is no task queue and no notion of a day.
* **It has no model of other agents.** Objects are remembered as things at
  places. It does not predict, avoid or cooperate with anything that moves.
* **Interaction is in the vocabulary and unused.** `interact` and `jump_to` exist
  as actions a controller must understand; no goal in this version emits them.
* **Tested with one bot.** The design is per-bot throughout, but several have not
  been run.

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
