# Project Status

**Date:** 2026-07-27
**Test baseline:** 75 total | 75 PASS | 0 FAIL | 0 SKIP | 0 ERROR

## Implemented Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_core` | ✅ Complete | API, composite IDs, world format lock, seed handling |
| `pw_compat_mcl` | ✅ Complete | Material mappings, biome families (7), environment profiles, material palettes |
| `pw_planner` | ✅ Complete | Region planning, village generation (3 archetypes), grammar pipeline, persistence |
| `pw_structures` | ✅ Complete | 5 registered structures, terrain analysis, placement pipeline, rollback |
| `pw_roads` | ✅ Complete | Road persistence API, delegates to pw_planner storage |
| `pw_settlements` | ✅ Complete | Type definitions, settlement record API (get/list/get_by_candidate) |
| `pw_debug` | ✅ Complete | 16 chat commands including /pw_village_list, /pw_village_info, /pw_village_tp |
| `pw_tests` | ✅ Complete | 53 PerfectWorld tests + 10 TestKit built-in + 6 smoke + 6 player = 75 total |
| `luanti_testkit` | ✅ Complete | Universal test framework |
| `pw_remote_control` | ✅ Complete | JSON remote control |

## Skeleton Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_settlements` | 🟡 Skeleton | Types defined (farm/hamlet/village/town/city), not used by planner |
| `pw_population` | 🟡 Skeleton | Table declared, no functionality |

## New: Village Generation System (v2)

Biome-aware, multi-archetype settlement pipeline replacing the old single-template village:

- **Environment profiles**: 7 biome families via `pw_compat_mcl.get_environment()`
- **3 archetypes**: linear (shore/valley), compact (open plains), hillside (rough)
- **Grammar pipeline**: road network → lots → roles → structures → overlap filter → materialize
- **Material palettes**: different foundation, wall, roof, path per biome family
- **Deterministic PRNG**: LCG seeded by region + candidate + environment + planner version
- **Settlement records**: persisted with fingerprint, archetype, structure/road IDs
- **Debug commands**: `/pw_village_list`, `/pw_village_info`, `/pw_village_tp`

See `docs/perfectworld-architecture.md` for detailed contracts.

## Known Test Issues

None. All 75 tests pass (75 PASS, 0 FAIL, 0 SKIP, 0 ERROR).

## Fingerprint v3

Village fingerprint now includes:
- `road_graph_fingerprint` — normalized geometry (all road points relative to center, /2)
- Normalized lot positions (relative to center, /2)
- All structure variants, roles, rotations
- Archetype, biome_family, size_class

Empty settlements (lot_count=0) get `status = "failed"`, never `"complete"`.

## Missing Systems

- NPCs and villagers
- Economy and trading
- Roads between settlements (only village-to-farm local roads)
- Bridges and tunnels
- Global route pathfinding
- Slope-following building adaptation (flat terrace only)
- Building interiors beyond minimal
- Save migration between planner versions

## Known Test Issues

One known ERROR: biome_name type mismatch (numeric ID vs string) in get_biome_family — fix pending verification.

## Immediate Technical Tasks

- Fix `prepare_candidate_area` to skip or handle village candidates
- Fix terrain analysis test assertions to match actual return values
- Integrate `pw_settlements` type definitions into `pw_planner` (replace hardcoded probabilities)
- Implement basic population that spawns at materialized settlements
- Add save migration framework for world format changes

## Supported Platforms

- Linux with Docker
- Luanti 5.16.1 server and client
- Mineclonia game
- Xvfb for headless testing
