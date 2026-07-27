# `pw_player_bot/v1` — the intent document

An intent is the output of `pw_player_bot` and the input of a future controller
that drives a real Luanti client.

It is declarative on purpose. It says "walk to this cell", never "hold the
forward key for 400 ms". Keystrokes are the controller's business, and describing
them here would tie the brain to one particular way of pressing them.

```
protocol:                pw_player_bot/v1
implementation_version:  0.1.0
```

## Getting one

```lua
local document = pw_player_bot.get_intent(player_name)   -- table, or nil
local json     = pw_player_bot.get_intent_json(player_name)
local ok, err  = pw_player_bot.validate_intent(document)
```

`/pw_player_bot_think <player>` runs one decision now and writes the document to
a world artifact; `pw_player_bot.log_intents = true` writes every one.

## Shape

```json
{
  "protocol": "pw_player_bot/v1",
  "intent_id": "intent-pwbot-42",
  "player_name": "pwbot",
  "issued_tick": 42,
  "issued_at": 1785000000,
  "goal": {
    "kind": "explore_frontier",
    "score": 0.61,
    "target": {"x": 118, "y": 11, "z": -64},
    "feature": null,
    "note": "walk to the edge of what is known"
  },
  "alternatives": [
    {"kind": "approach_feature", "score": 0.44, "reason": "distance=9.2 feature=door interest=0.55*1.00"}
  ],
  "rationale": [
    "dominant_need=curiosity(0.58)",
    "frontier=17",
    "traversable_known=31"
  ],
  "plan": {
    "kind": "route",
    "route": [{"x": 115, "y": 11, "z": -60}, {"x": 118, "y": 11, "z": -64}],
    "route_length": 2,
    "steps": [
      {"action": "face", "yaw": 3.927, "pitch": 0.0},
      {"action": "follow_route", "route": [...], "length": 2},
      {"action": "observe", "profile": "navigation"}
    ],
    "reason": "planned over remembered cells only"
  },
  "constraints": {
    "max_step_up": 1,
    "max_step_down": 3,
    "avoid": ["hazard", "lava", "water"],
    "route_is_belief_only": true
  },
  "expires_after_ticks": 10,
  "executed_by": "a future pw_player_bot runtime driving a real Luanti client; neither pw_player_bot nor pw_bot_bridge performs any action"
}
```

## Fields

| Field | Meaning |
|-------|---------|
| `intent_id` | Unique within a server run. Not stable across a restart |
| `issued_tick` | The brain's own tick counter, not a server step |
| `goal.score` | The winning utility score, rounded to 3 decimals |
| `goal.target` | Node-aligned position, or `null` for goals that do not go anywhere |
| `alternatives` | Up to four runners-up with their scores and reasons |
| `rationale` | Sorted, de-duplicated reasons: drive reasons, scoring contributions, the dominant need, and anything that could not be planned |
| `plan.kind` | `route`, `look`, or `none` |
| `plan.route` | Simplified waypoints — collinear cells removed |
| `plan.route_length` | Waypoint count, `0` when there is no route |
| `plan.steps` | The action sequence, in order |
| `constraints.route_is_belief_only` | Always `true`, and the most important line in the document |
| `expires_after_ticks` | After this the controller should ask for a new intent |

Empty arrays serialise as `[]` and absent values as `null`, via the bridge's
canonical encoder. Numbers are rounded half-away-from-zero to three decimals, so
two runs producing the same decision produce byte-identical JSON.

## Actions

Every action is something a human player does with a keyboard, a mouse and their
own eyes. None of them can be performed server-side, which is the property that
keeps the boundary honest.

| Action | Fields | Means |
|--------|--------|-------|
| `face` | `yaw`, `pitch` | Turn the head. Yaw 0 looks along +Z and grows anticlockwise |
| `walk_to` | `position` | Walk to a position on foot |
| `follow_route` | `route`, `length` | Walk a sequence of positions in order |
| `jump_to` | `position` | Jump up to a position one step higher |
| `interact` | `position` or object | Right-click |
| `observe` | `profile` | Look around: request a wider or narrower observation |
| `wait` | `ticks` | Hold still |
| `stop` | — | Do nothing further until the next intent |

A controller that meets an action it does not know must refuse the intent rather
than skip the step. `intent.validate` does exactly this, returning
`unknown_action:<name>`.

## What a controller may assume

- The route crosses **only columns the bot has personally observed**. It is not a
  path through the real world; it is a path through the bot's belief about the
  world, and it can be wrong wherever the belief is.
- Steps are in execution order, and the last step of an exploration or approach
  plan is an `observe` — arriving was only half of it.
- `max_step_up` and `max_step_down` bound every transition in the route.
- Nothing in the document has been done. Not one step. The brain wrote it and
  stopped.

## What a controller must not assume

- That the target exists. It existed when it was seen, and `rationale` says how
  long ago.
- That the route is still walkable. Another player may have dug it out.
- That an `intent_id` survives a restart, or that the numbering is dense.

## Validation

```lua
local ok, reason = pw_player_bot.validate_intent(document)
```

Rejects: `not_a_table`, `wrong_protocol`, `missing_intent_id`, `missing_goal`,
`missing_plan`, `unknown_action:<name>`. Any future controller is better off
failing loudly than acting on nonsense.

## Versioning

`pw_player_bot/v1` is additive: new optional fields and new goal kinds may
appear. Removing a field, changing the meaning of one, or removing an action is a
new protocol id. `pw_player_bot.get_capabilities()` reports what this build
actually supports, so a controller can read it instead of assuming.
