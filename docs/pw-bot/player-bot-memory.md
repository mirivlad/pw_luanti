# Memory and beliefs

The bot knows exactly what it has been told it saw, and nothing else. Everything
in this document follows from that.

## The two layers

**Memory** is what was observed, with a confidence and a timestamp. It is
bounded, it decays, and it survives a restart.

**Beliefs** are what memory implies right now: which columns are walkable, where
the hazards are, where the edge of knowledge is. Beliefs are rebuilt from scratch
every tick and are never persisted. Deriving them fresh is cheap, and it means
beliefs can never drift out of step with memory.

## What is remembered

| Store | Key | Holds |
|-------|-----|-------|
| `cells` | `"x:z"` | One surface column: `ground_y`, walkable, water, hazard, head clearance, node name, semantic tags, confidence, first/last seen tick, times seen |
| `features` | `"feature@x:y:z"` | A recognised thing at a place: door, road surface, ladder, boat, … |
| `entities` | `"kind@x:y:z"` | An object, keyed by *what and roughly where* |
| `visited` | `"x:z"` | Every column the bot has actually occupied |

Objects are deliberately **not** keyed by the bridge's `observation_id`. That id
is valid only for the current bridge session, and memory has to outlive a
reconnection; persisting one would be persisting a dangling handle.

All keys round coordinates half-up (`node_round`), so a player standing at
x = −2.4 keys to the same column an observation taught at x = −2.

## Where each fact comes from, and what it is worth

Confidence separates standing on a block from glimpsing it twelve nodes away.
Both are knowledge; only one is knowledge a route should lean on without
hesitating.

| Source | Confidence | Why |
|--------|-----------|-----|
| `self_state.node_under` | `1.0` | Standing on a block is the strongest evidence there is |
| `tactile.space_at_feet_ahead` | `0.95` | Contact, not sight — and it works while the head points elsewhere |
| `surface_profile.samples` | `0.85 − 0.04 × step`, floor `0.3` | Step one is almost underfoot; step twelve is a glimpse |
| `visible_features` | — | Recorded as features, not as ground |
| `rays` (walkable hit within 6 nodes, above the remembered floor) | — | Sets `blocked_above`; a ray hit is not a surface |

Nothing is inferred about places an observation did not mention. An unmentioned
column stays unknown, and unknown is precisely what drives the bot to go and
look.

## Contradictions are counted, not hidden

If the same column is learned at a different `ground_y`, `stats.contradictions`
goes up and the better-supported belief wins. The world moved, or the earlier
look was wrong. Either way the bot's belief was, and a bot that silently
overwrites its own mistakes cannot be debugged.

## Staleness is reported, not corrected

After `memory_stale_ticks` (default 600) without being seen again, an entry
reports `stale = true` and still offers its remembered position. Memory says when
it last looked. It does not claim the door is still there.

## Bounds and eviction

Every store has a ceiling (`memory_max_cells` 4096, `memory_max_features` 512,
`memory_max_entities` 128), each clamped against a hard limit that a config file
cannot raise.

Eviction is least-recently-seen, run once per `integrate` in a single pass:
collect the last-seen ticks, sort, compute a cutoff that keeps 85 % of the limit,
drop everything older. Scanning for the single oldest entry on each insert would
be quadratic over a session; one sweep is not. It is an approximate LRU, and the
approximation is stated rather than papered over. `stats.cells_evicted` says how
much was forgotten.

## Beliefs

```lua
is_standable(cell)   -- walkable, not blocked above, head_clearance >= 2
is_traversable(cell) -- standable, and not water, and not a hazard
can_step(from, to)   -- traversable, climb <= route_max_step_up,
                     -- drop <= route_max_step_down
```

Water is standable and not traversable: a body fits, but this bot has no reason
to wade. A hazard is the same distinction with a sharper edge.

### The frontier

A frontier cell is one the bot can stand in that touches at least one column it
has never seen. That is the edge of its knowledge, and the only place where
walking teaches it anything. The middle of a fully known plateau is not a
frontier: nothing is learned by standing there.

Frontier order is sorted deterministically, so a decision never depends on Lua's
hash walk. `frontier_targets` returns at most `HARD.max_frontier_targets` (12)
per tick.

`exploration_ratio` is visited columns over traversable columns — *walked*, not
*seen*. Having looked at a plaza is not having explored it.

## Persistence

Memory is stored in mod storage under `pw_player_bot_memory_v1:<player>`, one
entry per bot, written on stop and on server shutdown.

| Persisted | Not persisted |
|-----------|---------------|
| remembered cells | beliefs (rebuilt every tick) |
| remembered features and their visited flag | drives |
| remembered objects, without observation ids | the current intent |
| visited columns | bridge observation ids |
| statistics | stuck counters and failed-route counts |

The right-hand column is enforced by a test that greps the raw storage string for
each forbidden key. Anything tied to a bridge session, or to a decision the bot
has not made yet, is state that must not survive a restart pretending to be
knowledge.

Unreadable or corrupt storage is refused outright: the bot starts knowing
nothing rather than starting with a half-parsed picture of somewhere it has
never been.
