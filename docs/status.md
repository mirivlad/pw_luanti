# Project Status

**Date:** 2026-07-27
**Test baseline:** 112 total | 112 PASS | 0 FAIL | 0 SKIP | 0 ERROR

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
| `pw_tests` | ✅ Complete | 112 tests across core, planner, structures, variation, fingerprints, village, diversity |
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

## Known Test Issues

None. 112 PASS, 0 FAIL, 0 SKIP, 0 ERROR.

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
