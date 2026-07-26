# Project Status

**Date:** 2026-07-27
**Test baseline:** 67 total | 67 PASS | 0 FAIL | 0 SKIP | 0 ERROR

## Implemented Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_core` | ✅ Complete | API, composite IDs, world format lock, seed handling |
| `pw_compat_mcl` | ✅ Complete | Mineclonia material mappings with fallbacks |
| `pw_planner` | ✅ Complete | Deterministic regional planning, village layout, mapgen integration |
| `pw_structures` | ✅ Complete | 5 registered structures, terrain analysis, placement pipeline, rollback |
| `pw_roads` | ✅ Complete | Road persistence API, delegates to pw_planner storage |
| `pw_debug` | ✅ Complete | 13 chat commands, screenshot system |
| `pw_tests` | ✅ Complete | 45 PerfectWorld tests + 10 TestKit built-in + 6 smoke/player |
| `luanti_testkit` | ✅ Complete | Universal test framework |
| `pw_remote_control` | ✅ Complete | JSON remote control |

## Skeleton Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_settlements` | 🟡 Skeleton | Types defined (farm/hamlet/village/town/city), not used by planner |
| `pw_population` | 🟡 Skeleton | Table declared, no functionality |

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

None. All 67 tests pass (67 PASS, 0 FAIL, 0 SKIP, 0 ERROR).

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
