# Testing the bridge and the brain

Both mods register their own TestKit suite — `pw_bot_bridge` and
`pw_player_bot` — so a normal `pw_test_all` run covers them and the project keeps
one baseline number.

```bash
scripts/run-testkit.sh
```

Current: **258 total | 258 PASS | 0 FAIL | 0 SKIP | 0 ERROR**, of which 86 are
bridge tests and 54 are brain tests.

## Layout

```
local_mods/perfectworld/pw_bot_bridge/tests/
├── init.lua           registers the suite, loads the rest
├── support.lua        scratch bot, scene building, snapshot and restore
├── unit_core.lua      registry, permissions, capabilities, validation, canonical JSON
├── unit_semantics.lua the semantic registry and normalised node properties
├── unit_events.lua    the bounded queue, cursor, overflow
├── unit_transport.lua path safety, round trip, malformed input
├── scenes.lua         scenes A–E against the real world
└── integration.lua    end to end on a live server with a live player

local_mods/perfectworld/pw_player_bot/tests/
├── init.lua           registers the suite, loads the rest
├── support.lua        synthetic observations and hand-built memories
├── unit_memory.lua    what is learned, bounded, decayed, persisted, and what is not
├── unit_navigation.lua routing over remembered ground only
├── unit_decisions.lua needs, goals, utility, intent documents
└── integration.lua    the brain end to end against the real bridge
```

## Integration tests use a real server

They are not mock tests, and mocks would not be an acceptable substitute here.
The interesting failures live in the gap between what the server believes and
what a client meets; a mock reproduces the belief and loses the gap.

Everything that needs the connected test player SKIPs with a stated reason when
that player is absent, rather than passing vacuously.

## Scenes

Each scene is assembled in the air 30 nodes above the connected test player, so
the blocks are certainly loaded and no generated terrain is disturbed, and each
is put back exactly as it was. Capture and restore go through a voxel
manipulator: thousands of `set_node` calls would be slow and would fill
Mineclonia's redstone queue, which would make the project's log scan meaningless.

The harness places the player and turns their head, because that is what a real
client would do and something has to stand in for it. Those calls live in
`support.lua`, where they are obvious, and are always undone.
`scripts/smoke-test.sh` fails if any of them appear outside `tests/`.

### Scene A — visibility wall

A floor, a marker block dead ahead, an opaque wall, a second marker directly
behind it, and an object on each side of the wall.

* `player` finds the near marker with a ray and the wall behind it
* the far marker's name appears **nowhere** in the canonical JSON of the
  observation, of a dense feature sweep, or of `inspect_target`
* exactly one of the two objects is visible, and the hidden one is rejected as
  `occluded`
* `oracle` reports both markers and both objects
* turning the head stops the near marker being reported
* two identical requests produce byte-identical responses

The leak check is deliberately blunt: if a hidden node's name appears anywhere in
the response, player mode leaked it, whatever field it hid in.

### Scene B — doorway

A path, a step up, a door in a wall, a room behind it, and a marker inside the
room.

* `player` recognises the door as a door, at the right position
* what stands inside the closed room is not reported
* the tactile channel reports the ground and the room to stand
* `oracle` identifies the door node, its state read from the game convention,
  the standability of the threshold, and everything inside the room

### Scene C — terrain

Flat ground, a pit, more flat ground, a water surface, a kerb one block high, a
ledge three blocks high, and a low ceiling over the player's own head.

* the surface profile reports slope, the gap, the water, the kerb and the ledge
* the tactile channel reports the ground under the feet and the low ceiling
  **while the player is looking straight up** — which is the point: tactile is
  not sight

### Scene D — road semantics

A road with a fork, half of it hidden behind a wall.

* `player` recognises only the visible stretch, and no reported cell lies beyond
  the wall
* `oracle` reads the whole road in the requested scope, with PerfectWorld
  semantics attached

### Scene E — entity target

A visible object, an occluded one, and one behind the player.

* exactly one is an interaction target, and the other two are rejected with
  reasons
* `inspect_target` names what the crosshair points at and says it used
  pointability
* attachment is observed: the harness attaches the player, the bridge reports it
  with an opaque id, the harness detaches, the bridge reports that too

## Integration checklist

| # | Check | Test |
|---|-------|------|
| 1 | register `pwbot` in player mode | `integration_registers_the_test_player_in_player_mode` |
| 2 | self state is complete and honest | `integration_self_state_is_complete_and_honest` |
| 3 | player observation has every channel | `integration_player_observation_has_every_perception_channel` |
| 4 | no hidden block | `scene_a_player_sees_the_near_block_and_not_the_hidden_one` |
| 5 | no hidden object | `scene_a_player_sees_the_near_entity_and_not_the_hidden_one` |
| 6 | turning changes the sector | `scene_a_turning_the_head_changes_what_is_reported` |
| 7 | oracle refused in player mode | `integration_oracle_operations_are_refused_in_player_mode` |
| 8 | administrator switches to oracle | `integration_admin_switches_mode_and_oracle_returns_exact_data` |
| 9 | oracle data matches the map node for node | same |
| 10 | switching back withholds it again | same |
| 11 | a bot cannot promote itself | `integration_bot_cannot_raise_its_own_mode` |
| 12 | event polling | `integration_event_polling_works_end_to_end` |
| 13 | restart contract | `integration_registry_survives_a_reload_and_the_session_does_not` |
| 14 | transport follows its setting | `integration_transport_follows_its_setting` |
| 15 | malformed external request does not crash | `transport_round_trips_a_request_and_refuses_a_malformed_one` |
| 16 | the full TestKit stays green | the run itself |

Number 13 is exercised in-process by persisting, forgetting and loading — the
steps a real restart performs. A genuine `docker compose restart` was also run by
hand and confirmed the same contract: modes survived, sequence numbers restarted,
event queues were empty.

## The brain's own tests

Unit tests run on hand-built memories and synthetic observations, so a claim
about scoring can be made without a world getting in the way. The integration
tests run the real brain against the real bridge and a real connected player.

| Area | What is pinned down |
|------|--------------------|
| Memory | Only what an observation reported is learned; confidence falls with distance; features and objects are separate; staleness is reported rather than corrected; the store is bounded and says how much it forgot; contradictions are counted; a restart keeps knowledge and drops session state; corrupt storage yields a bot that knows nothing rather than one that invents |
| Beliefs | Standable is not traversable; steps too high or too deep are refused; the frontier is the edge of knowledge and the middle of a known plateau is not; frontier order does not depend on Lua's hash walk; exploration counts where the bot stood, not what it saw |
| Navigation | Routes cross remembered ground only; an unknown goal and an unreachable one are different answers; water and hazards are avoided; step limits hold; a road beats bare ground; the expansion cap binds; two identical plans are identical; simplification keeps turns and drops straights; an approach lands on the doorstep, not in the door; a route faces before it walks |
| Needs | Bounded, named and explained; safety dominates when something can hurt; curiosity falls as the neighbourhood is walked; recovery rises when the bot stops moving; standing still on purpose is not being stuck |
| Utility | Danger outranks curiosity; near beats far; the edge that teaches more wins; a doorway outranks a fence; the same state produces the same choice with no randomness; every score is explained |
| Intent | Versioned and valid; the action vocabulary is closed; rejected alternatives are carried; yaw faces the way it means to go; encoding is canonical |
| The brain | Refuses to start unless the bridge granted perception; lifecycle needs authorisation; only ever asks for player-mode operations; thinks end to end against the real bridge; **never moves, turns or damages the player**; holds a fresh intent instead of dithering; survives a bridge refusal without inventing a world; memory grows across ticks and survives a restart; routes only over ground it observed; explains itself; stays inside its tick budget; capabilities declare what it does and does not do |

`brain_never_moves_turns_or_damages_the_player` is the one that matters most: it
records the player's position, look direction and health, runs a full tick, and
asserts that all three are untouched. The smoke test enforces the same rule
statically; this one enforces it at runtime.

## Chatcommands

All require `pw_bot_admin`. None prints a large document into chat; full
documents go to a runtime artifact in the world directory and chat gets a
one-screen summary.

```
/pw_bot_bridge_status
/pw_bot_bridge_register <player> [player|oracle]
/pw_bot_bridge_unregister <player>
/pw_bot_bridge_mode <player> <player|oracle>
/pw_bot_bridge_capabilities
/pw_bot_bridge_observe <player> [minimal|navigation|detailed]
/pw_bot_bridge_limits <player>
/pw_bot_bridge_events <player> [max]
/pw_bot_bridge_transport <status|start|stop>
/pw_bot_bridge_selftest
/pwbot_bridge [status|observe|events]
```

`/pwbot_bridge` is the shortcut for the project's own test player: it registers
it if needed and reports on it in one call.

The brain's commands follow the same rule and the same privilege:

```
/pw_player_bot_status [player]
/pw_player_bot_start <player>
/pw_player_bot_stop <player>
/pw_player_bot_think <player>
/pw_player_bot_explain <player>
/pw_player_bot_route <player> <x> <y> <z>
/pw_player_bot_memory <player> [forget]
/pw_player_bot_capabilities
/pwbot_brain [think|status|stop]
```

`/pwbot_brain think` is the fastest way to watch one decision: it registers the
test player with the bridge if needed, starts thinking, runs a single tick, and
prints the goal, the drives and the first few lines of the rationale.

Artifacts land in the world directory, which is gitignored:

```
pw_bot_bridge_capabilities_<stamp>.json
pw_bot_bridge_observe_<stamp>.json
pw_bot_bridge_selftest_<stamp>.json
pw_player_bot_intent_<stamp>.json
pw_player_bot_explain_<stamp>.json
pw_player_bot_memory_<stamp>.json
pw_player_bot_capabilities_<stamp>.json
```

## Driving the transport by hand

```bash
docker exec perfectworld-dev sh -c 'echo "/grant pwbot pw_bot_admin" > /proc/1/fd/0'
```

```bash
printf '{"command":"runchat","chatcmd":"pw_bot_bridge_transport","params":"start","player":"pwbot"}' > data/worlds/perfectworld/rc_cmd.json
```

```bash
printf '{"protocol":"pw_bot_bridge/v1","request_id":"ext-0001","operation":"observe","parameters":{"profile":"navigation"}}' > data/worlds/perfectworld/pw_bot_bridge/requests/pwbot/ext-0001.json
```

The response appears at
`data/worlds/perfectworld/pw_bot_bridge/responses/pwbot/ext-0001.json` within one
poll interval.

## Before you finish

```bash
bash -n scripts/*.sh
```

```bash
python3 -m py_compile scripts/*.py
```

```bash
git diff --check
```

```bash
bash scripts/smoke-test.sh
```

The smoke test checks more than file presence for these two mods. It fails if:

* either mod gains a call that moves, turns, attaches or damages a player, or
  writes a node, outside its own tests
* either mod grows a screenshot or image-pipeline dependency
* the bridge adds `request_insecure_environment()`
* `pw_player_bot` reads the map directly — `get_node`, `VoxelManip`,
  `get_objects_inside_radius` — instead of going through the bridge
* `pw_player_bot` calls `math.random`, `math.randomseed` or `PseudoRandom`

The last two are the guards that keep the brain honest. A bot that can read the
map does not need to look, and a bot that rolls dice cannot be tested.
