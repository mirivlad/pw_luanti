# Project Status

**Date:** 2026-07-27
**Test baseline:** 114 total | 114 PASS | 0 FAIL | 0 SKIP | 0 ERROR

## Implemented Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_core` | ✅ Complete | API, composite IDs, world format lock, exact 32-bit hashing, stable variation contract |
| `pw_compat_mcl` | ✅ Complete | Material mappings, biome id/name resolution, 7 biome families, environment profiles, palettes |
| `pw_planner` | ✅ Complete | Region planning, village grammar (3 archetypes), terrain sampler, validation, diversity analysis, persistence |
| `pw_structures` | ✅ Complete | 5 registered structures, terrain analysis, palette-aware placement, plinths, rollback |
| `pw_roads` | ✅ Complete | Road persistence API, delegates to pw_planner storage |
| `pw_settlements` | ✅ Complete | Type definitions, settlement record API |
| `pw_debug` | ✅ Complete | 22 chat commands including validation, batch build, diversity analysis, screenshot support |
| `pw_tests` | ✅ Complete | 114 tests across core, planner, structures, variation, fingerprints, village, diversity |
| `luanti_testkit` | ✅ Complete | Universal test framework |
| `pw_remote_control` | ✅ Complete | JSON remote control |

## Skeleton Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_population` | 🟡 Skeleton | Table declared, no functionality |

## Village Generation System (v2)

Biome-aware, multi-archetype settlement pipeline. See
`docs/perfectworld-architecture.md` for the full contracts.

- **Environment profiles**: 7 biome families via `pw_compat_mcl.get_environment()`
- **3 archetypes**: linear, compact, hillside, with a documented hillside fallback
- **Grammar pipeline**: emerge → environment → profile → roads → lots → structures → materialize
- **Material palettes**: applied to foundations, walls, roofs, floors and paths
- **Stable variation**: independent labelled hash decisions, not a PRNG stream
- **Three fingerprints**: exact plan, structural, road graph
- **Physical validation**: 15 checks against the record *and* the real world
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

## Known Test Issues

None. 114 PASS, 0 FAIL, 0 SKIP, 0 ERROR.

The only ERROR lines in a clean server log come from
`world_format_lock_detects_incompatible_changes`, which feeds `pw_core` a
mismatched lock record on purpose, and from Mineclonia's own redstone event
queue. Neither is a PerfectWorld fault.

## Known Visual Defects

Found by reviewing 21 screenshots of 7 settlements; none of them break the
physical contract, all of them are honest limitations of the current build.

| Defect | Cause | Effect |
|--------|-------|--------|
| Streets are ragged: holes, offset blocks, stepped edges | `place_road_strip` writes one node per column at that column's own surface height, and skips columns whose surface is water | A street reads as a street but not as a built road surface |
| Buildings inside one village look like the same box at different sizes | Only four structures exist, all flat-roofed rectangles from one generator | A village reads as a settlement, but not as a place with distinct buildings |
| The `rocky` palette is monochrome | stone walls + stone roof + gravel path on stone terrain | Rocky villages are legible in silhouette only |
| Many `hillside` settlements stand on flat ground | The hillside fallback fires whenever a flat archetype finds no viable layout, which is common on the `carpathian` mapgen | On flat ground hillside is visually indistinguishable from linear |

Fix directions, in order of visual return: give the road builder a smoothed
profile and let it bridge one-block gaps; add roof shapes and a second wall
material per palette; give `rocky` a contrasting roof.

## Missing Systems

- NPCs and villagers
- Economy and trading
- Roads between settlements (only local village roads and driveways)
- Bridges and tunnels
- Global route pathfinding
- Building interiors beyond minimal
- Save migration between planner versions

## Immediate Technical Tasks

- Integrate `pw_settlements` type definitions into `pw_planner`
  (replace the hardcoded candidate-type weights)
- Add a save migration framework for world format changes
- Widen the structure catalogue: five structures limits how different two
  villages of the same archetype can look

## Supported Platforms

- Linux with Docker
- Luanti 5.16.1 server and client
- Mineclonia game
- Xvfb for headless testing and screenshots
