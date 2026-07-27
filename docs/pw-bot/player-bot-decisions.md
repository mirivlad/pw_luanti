# Needs, goals and choosing

How the bot gets from "here is what I believe" to "here is what I am going to
do".

The three layers are kept apart on purpose. Needs know nothing about goals;
goals do not decide their own importance; the utility layer knows nothing about
how a goal is planned. That separation is what lets a new goal be added without
re-tuning every existing one.

## Needs

Five drives, each a number in `[0, 1]` with a stated reason. The reason is not
decoration: an intent that says `curiosity=0.82` is debuggable, and one that says
`score=0.71` is not.

| Need | Rises when |
|------|-----------|
| `safety` | Standing in liquid (0.6), health below 20, health falling (0.85), a remembered hazard within 6 nodes, not on the ground (0.3) |
| `recovery` | The bot was asked to move and did not (`stuck_ticks / 5`), or routes keep failing |
| `orientation` | Little is known: `1 − traversable / 24` |
| `curiosity` | There is a frontier: `0.25 + (1 − explored) × 0.45`, so at most 0.7 |
| `interest` | Something recognised has not been approached: `0.2 + min(unvisited, 8) / 20`, so at most 0.6 |

Curiosity and interest top out below safety by construction. Wanting to see what
is over there should never be able to outbid not catching fire.

### The fear gate

Above `FEAR_THRESHOLD = 0.5`, safety stops being one drive among equals and
starts suppressing the others:

```lua
suppression = 1 - safety
curiosity, interest, orientation  *=  suppression
```

Without this, a bot on six health beside a lava flow can still be talked into
sightseeing by a sufficiently interesting doorway — which is not a bot anybody
would believe. Fear does not merely outrank curiosity; it changes what the bot is
capable of caring about.

`recovery` is deliberately left unsuppressed: being stuck *while* in danger is
exactly when getting unstuck matters most.

## Goals

Seven kinds. Each declares which drives it answers, proposes concrete instances
from beliefs, and knows how to build its own plan.

| Kind | Answers | Plan |
|------|---------|------|
| `stand_still` | — | `stop`. Doing nothing is a legitimate answer and gets a record like any other |
| `look_around` | orientation, recovery | `face` a quarter turn, `observe`, `wait` |
| `explore_frontier` | curiosity, orientation | Route to a frontier cell, then `observe` |
| `approach_feature` | interest | Route to the cell *beside* the feature, then `face` it and `observe` in detail |
| `retreat_from_hazard` | safety | Route to remembered ground at least 6 nodes from the hazard |
| `leave_liquid` | safety | Same, back onto dry ground |
| `unstick` | recovery | `face` the opposite way and `observe` in detail |

A door is not somewhere to stand, which is why `approach_feature` routes to
`navigation.approach_cell` and turns to face the door on arrival.

Candidate generation is bounded: however much the bot remembers, one tick scores
at most `HARD.max_candidates` (24) options, of which at most 12 are frontier
cells and at most 8 are features.

## Scoring

```
score = clamp01( Σ (weight[need] × drive[need]) × quality )
```

No goal has an intrinsic priority. A door outranks a frontier only when interest
outranks curiosity, which is a statement about the bot's condition rather than
about doors.

### Weights

| Goal | Weights |
|------|---------|
| `look_around` | orientation 0.9, recovery 0.4, curiosity 0.25 |
| `explore_frontier` | curiosity 1.0, orientation 0.5 |
| `approach_feature` | interest 1.0, curiosity 0.2 |
| `retreat_from_hazard` | safety 1.0 |
| `leave_liquid` | safety 0.95 |
| `unstick` | recovery 1.0 |
| `stand_still` | none — it is the floor, at `IDLE_SCORE = 0.05` |

### Quality

Everything about a candidate other than which drive it serves.

- **Distance** decays as `1 / (1 + d / 24)` rather than being cut off. A cliff
  produces a bot that ignores an interesting thing 25 blocks away and sprints to
  one 24 blocks away; a curve produces one that prefers near things without being
  blind to far ones.
- **Frontier**: `0.6 + 0.4 × min(unknown_neighbours, 8) / 8`, halved-ish (×0.6)
  if the bot has already stood there. More unknown neighbours means more is
  learned by going.
- **Feature**: multiplied by `FEATURE_INTEREST` — `structure_entrance` 1.0,
  `door` 0.95, `boat` 0.8, `road_surface` 0.6 down to `water` 0.15 — and ×0.7 if
  the sighting is stale. A future module registers its own features through
  `P.set_feature_interest` rather than editing `goals.lua`.
- **Looking around** is held down (×0.8) because it is cheap and always
  possible, and would otherwise win constantly. It earns its keep through
  orientation.

### Ties

Equal scores are common and genuinely equivalent — two frontier cells at the same
distance with the same unknown count are the same offer twice. Picking by table
order would make the choice depend on Lua's hash walk, so the tie breaks on

```lua
perfectworld.core.choice.unit("pw_player_bot:" .. player, label .. "#" .. tick)
```

Same state, same choice, every time; different across ticks, so the bot does not
lock onto one of two equal options forever. `math.random` is never called, and
the smoke test fails the build if it appears.

## Planning, and the goals that do not survive it

Candidates are planned in score order, and only the chosen one is planned:
planning is the expensive half, and scoring already said which one is worth it.
A goal that cannot be planned is a wish, so it is dropped, the failure is
recorded in `rationale` as `unplannable=<kind>:<reason>`, and the next candidate
gets its turn.

The most common reason is `goal_not_remembered` — the bot has never seen the way
there. That is the answer to "why did it not go?" far more often than any bug is.

## Reading a decision

`/pw_player_bot_explain <player>` prints the whole scoring table, deciding
nothing, and writes the full document to a world artifact. Every intent also
carries the runners-up in `alternatives`: a bot whose decisions cannot be
second-guessed is a bot nobody can debug, and the runner-up is usually the most
informative line in the record.
