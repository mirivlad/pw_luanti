# Project Status

**Date:** 2026-07-28
**Test baseline:** 309 total | 307 PASS | 2 FAIL | 0 SKIP | 0 ERROR
(148 in `perfectworld`, 4 in `player`, 89 in `pw_bot_bridge`,
62 in `pw_player_bot`, 6 in `smoke`)

Measured on `master` after the ecological-villages merge.

## Implemented Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_core` | ✅ Complete | API, composite IDs, world format lock, exact 32-bit hashing, stable variation contract |
| `pw_compat_mcl` | ✅ Complete | Material mappings, biome and ecological node classification, 7 families, environment profiles, palettes and abstract decor materials |
| `pw_planner` | ✅ Implemented | Region planning, grammar v3, bounded ecological survey, 3 archetypes, exact local roads, transactional worksites, real-world validation and cached persistence reads |
| `pw_structures` | ✅ Complete | 10 registered structures, including fishery, sawmill and mine workshop; palette-aware placement, bounded terrain prep and rollback |
| `pw_roads` | ✅ Implemented | Shared exact-width raster, persistence facade and canonical road cells |
| `pw_settlements` | ✅ Implemented | Four specialization definitions, scoring and normalized legacy/current settlement records |
| `pw_debug` | ✅ Complete | 22 chat commands including validation, batch build, diversity analysis, screenshot support |
| `pw_bot_bridge` | ✅ Implemented | Server-side perception: `player`/`oracle` modes, stable `pw_bot_bridge/v1`, normalized oracle settlement records, semantic registry and bounded transport; player-mode contract unchanged |
| `pw_player_bot` | ✅ Complete | Bounded memory, beliefs, navigation over remembered ground, needs, goals and `pw_player_bot/v1`. Decides only — never acts |
| `pw_tests` | ✅ Complete | 143 PerfectWorld tests across core, planner, structures, ecology, worksites, roads, variation, fingerprints, village and diversity |
| `luanti_testkit` | ✅ Complete | Universal test framework |
| `pw_remote_control` | ✅ Complete | JSON remote control |

## Skeleton Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_population` | 🟡 Skeleton | Table declared, no functionality |

## Village Generation System (grammar v3)

Resource-aware, multi-archetype physical settlement pipeline. See
`docs/perfectworld-architecture.md` for the full contracts.

- **Bounded site selection**: exactly 9 sites and at most 81 surface columns
  per site
- **Four specializations**: fishing, farming, forestry and mining require
  physical water/soil/tree/stone evidence rather than a random or biome-only
  label
- **Grammar contract**: at least 2 dwellings, the specialization's production
  building and its required field/dock/forestry yard/minehead
- **3 archetypes**: linear, compact, hillside, with a documented hillside fallback
- **Grammar pipeline**: emerge → ecological survey → specialization → roads →
  required lots → optional lots → structures → exact roads → transactional
  worksite → reachability
- **Material palettes**: applied to foundations, walls, roofs, floors and paths
- **Stable variation**: independent labelled hash decisions, not a PRNG stream
- **Three fingerprints**: exact plan, structural, road graph
- **Physical validation**: checks records, required roles/worksites, exact
  collisions, doors and nodes in the real world
- **Diversity analysis**: >= 100 deterministic inputs, full metric set

## Resolved in This Cycle

| Defect | Impact |
|--------|--------|
| LCG lost 9 bits per step to double rounding | Generator collapsed to a 10466-long cycle; replaced with exact hash-based choices |
| `get_biome_data` returns a numeric id, resolver indexed `registered_biomes` by name | Every biome in the world resolved to `temperate`; the palette system was dead |
| Material palettes computed but never passed to a generator | Every village was built out of oak regardless of biome |
| Wells declare only rotation 0, planner picked from `{0,90,180,270}` | 3 of 4 wells failed to place |
| Road width applied along +x regardless of heading | North-south streets were one block wide |
| Roads materialized before structures | Terrain preparation buried the streets it had just laid |
| Fixed lot setback smaller than building footprints | Dominant rejection reason; lots could not clear the carriageway |
| Lot terrain check used a different area and slope limit than placement | Settlements landed in `partial` for lots the placer then rejected |
| Villages materialized inline from `on_generated` | Planned against terrain that did not exist yet and burned the candidate |
| `minetest.load_area` does not generate | Plans near the edge of the generated world produced zero lots |
| Downhill footprint corners sat above open air | Buildings floated on slopes; foundations now carry down as a bounded plinth |
| Settlement bounds hardcoded to ±50 | Did not contain the settlement |
| `complete` status ignored required roles and unbuilt lots | Contract now enforced and validated |
| Driveways were drawn but never recorded | Nothing proved a lot was reachable |
| Single fingerprint quantised coordinates by 2 | One-block differences were invisible |
| Frozen ocean passed every buildability check | A village with a full crossroads was materialized on the sea |
| Road polylines were never checked against terrain | Streets ran off clifftops, down rock faces and into water |
| Screenshot helper matched the xvfb-run wrapper shell | Captured the desktop instead of the game |
| Village role was effectively biome-flavoured variation | Nine bounded physical surveys now choose fishing/farming/forestry/mining from measured resources |
| Tree crowns hid the actual ground and a 6-node lattice missed trunks | Canopy is tree evidence, while structure and paving analysis continue to true ground |
| Fishing centres and streets could point into the water | The centre moves to measured shore land and the main street runs tangent to the shore |
| Every consumer interpreted road width independently | One exact raster now drives planning, placement, validation, worksite collision and oracle diagnostics |
| Production was only a label on a building | Every complete grammar-v3 village requires a physical transactional worksite |
| A frozen shore passed ecological selection but failed dock placement | The dock consumes the same open/frozen-water surface contract as the survey |
| Oracle settlement reads repeatedly parsed the entire storage map | Decoded storage maps are cached between writes; a 500-record oracle integration went from 8+ minutes to an immediate PASS |

## Known Test Issues

The two FAILs are an existing test-configuration contradiction, not planner
regressions:

- `pw_bot_bridge.integration_transport_follows_its_setting`
- `pw_bot_bridge.transport_is_off_by_default_and_needs_no_insecure_environment`

Both expect `pw_bot_bridge.external_transport=false`, while the local
development file `config/luanti.conf` explicitly sets it to `true`. Configuration
was not changed during this cycle. All 143 `perfectworld` tests and all 62
`pw_player_bot` tests pass.

Expected log noise remains: the world-format test deliberately feeds `pw_core`
an incompatible lock, terrain rollback fixtures provoke
`CONTENT_IGNORE` diagnostics in unloaded test cells, Mineclonia can overflow
its redstone event queue after the destructive fixture suite, and the client
reports unsupported translation `.po` files. No `LuaError`, `AsyncErr`, fatal
error or stack traceback was observed.

## Buildings

Modelled on the vanilla plains village houses
([Minecraft Wiki, Village/Structure/Blueprints](https://minecraft.wiki/w/Village/Structure/Blueprints)):
cobble plinth, timber corner posts, plank infill, glass-pane windows on every
wall, a pitched roof of stairs with a slab ridge and one-block eaves, and a
porch step at the door.

Ten structures: four dwelling shapes, a barn, a farmstead, a well, a fishery, a
sawmill and a mine workshop. Each biome family carries its own wood and stone —
oak, birch, spruce, acacia, dark oak, jungle — so two villages in different
biomes can use different materials.

Every door is checked with the engine's pathfinder from the street, on foot,
with a walker's limits. Unreachable lots are rejected at plan time; anything
that still cannot be reached gets a stepped way cut to it and, failing that,
keeps the settlement out of `complete`.

## Known Visual Defects

Reviewed through a real visible Luanti client. Complete farming, forestry and
mining records were validated against the world and inspected from overview and
worksite cameras.

| Defect | Cause | Effect |
|--------|-------|--------|
| Streets are patchy where the ground undulates | The carriageway is one node per column at a smoothed height; cells whose surface is water are skipped | The street reads as a street, but the edges are ragged |
| 3 of 11 settlements have one door the pathfinder cannot reach | The approach check is per-lot; it cannot see a neighbour that will later be built across the only route | Those settlements stay `partial`, which is the honest status |
| Most settlements come out `hillside` on this mapgen | The hillside fallback fires whenever a flat archetype finds no viable layout, which is common on `carpathian` | On flat ground hillside looks like linear |
| No complete fishing village was found inside valid world coordinates in this seed's acceptance sample | Viable shore geometry must fit two houses, a fishery and a dock without using water or a cliff | Fishery and dock components pass physical tests, but full real-world fishing composition still needs a deterministic acceptance fixture |
| `/pw_village_batch` accepts radii beyond the engine's usable coordinate range | The development command enumerates arbitrary region coordinates and does not clamp to `mapgen_limit` | It can write non-visualizable diagnostic records; normal mapgen does not generate those regions |
| House interiors are close to empty | A dwelling places a bed and a chest and nothing else | A village reads as a shell from the inside |

Fixed: roof stairs pointed downhill, so every course rose at its outer edge and
dropped at its inner one and the roof read as a row of combs from the gable end.
`roof_stairs_rise_towards_the_ridge` now measures orientation; nothing did
before.

Fix directions: furnish interiors, add a valid-coordinate deterministic fishing
acceptance seed, order lots by approach quality before accepting them, clamp
debug batch radius, and widen carriageway smoothing to bridge one-block gaps.

## PW Bot: measured on the obstacle course

The third part exists. `pw_bot_runtime` drives a real client through XTEST; the
course in `pw_debug/bot_course.lua` gives it deliberate obstacles, half of which
it is meant to fail. Run it with `scripts/pw-bot-course.sh build` then
`pw-bot-runtime scenario course`.

**The course passes end to end.** Every step behaves as expected.

| Step | Verdict |
|------|---------|
| `walk_straight`, `turn_corner`, `step_up`, `climb_stairs` | reached — the body walks, turns, climbs a kerb and takes stairs |
| `open_door` | reached — `door_acacia_t_1` → `_t_2`, closed to open, empty hand, crosshair on the door |
| `enter_room`, `leave_room` | reached — through the doorway it opened, and out the far side |
| the five obstacles that must fail | all `blocked`, and no longer by an unopened door |

Everything physical the bot does goes through XTEST into a real client. Nothing
teleports it after the start line.

### What was wrong, and how it was found

Four defects, each of which alone stopped every interaction, and all four found
by measuring rather than reasoning:

1. **The pointer warp destroyed the aim.** The runtime aimed, then warped the
   pointer to the window centre, then pressed. Luanti turns the head from
   *relative* pointer motion and never grabs the pointer on a bare Xvfb, so the
   warp arrived as a large mouse movement between aiming and pressing.
2. **The "empty" hotbar slot held a block.** Twice guessed, twice wrong —
   `players.sqlite` has snowballs in slots 1 and 2 and oak wood in 5. The
   runtime now asks the bridge what is in hand instead of assuming.
3. **The crosshair position was read from the wrong field.** `inspect_target`
   reports it on the *target*, with the node nested inside; the code looked in
   the node, got null on every hit, and called a correct aim a miss.
4. **Aiming once at the named node pointed at the floor.** A door is named by
   its lower node, which from the doorstep is a node below eye level a node
   away — the ray hit the floor at the bot's feet. Aiming is now closed-loop
   against what the crosshair reports.

Ruled out along the way, with evidence rather than argument: the client does
read `client.conf` and its bindings are live (moving `keymap_forward` to a
non-default key stops the bot walking); `keymap_place` is a setting Luanti
recognises and `SYSTEM_SCANCODE_21` is R (it normalises `KEY_KEY_R` to exactly
that); the place action reaches the server (`pwbot places node …` in the server
log); and the course's door is a working door (`/pw_bot_course door` calls its
`on_rightclick` server-side, and puts it back afterwards).

### What the course does not yet prove

The five obstacles that must fail stand in series, and the runtime walks in
straight lines. All five report `blocked by mcl_trees:wood_oak` — the two-node
wall of the *first* of them. Only that first obstacle is genuinely under test;
the other four sit behind a wall the bot cannot pass. Better than being stopped
by an unopened door, and still not proof.

Interaction is also tested against one door and nothing else. Chests, gates,
levers and buttons go through the same path but have never been tried.

## Missing Systems

- The acting PW Bot client layer remains outside this world-generation cycle;
  `pw_bot_bridge` only perceives and `pw_player_bot` only decides — see
  [docs/pw-bot/](pw-bot/README.md)
- NPCs and villagers
- Production simulation, inventories, economy and trading
- Roads between settlements (local village streets and driveways exist)
- Bridges and tunnels
- Global route pathfinding
- Building interiors beyond minimal
- Save migration between planner versions

## Immediate Technical Tasks

- Add a deterministic, in-range complete fishing-village acceptance fixture
- Clamp `/pw_village_batch` and other world-debug enumeration to the engine
  `mapgen_limit`
- Shard settlement/road persistence: decoded reads are now cached, but every
  write still serializes the whole growing JSON map
- Integrate the remaining legacy settlement type weights into the specialization
  definitions
- Add a save migration framework for world format changes
- Widen the structure catalogue and add more specialization-specific decor

## Supported Platforms

- Linux with Docker
- Luanti 5.16.1 server and client
- Mineclonia game
- Xvfb for headless testing and screenshots
