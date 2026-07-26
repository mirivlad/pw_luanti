# MIGRATION.md

## Origin

PerfectWorld was extracted from the [AliveWorld](https://git.mirv.top/mirivlad)
monorepo on 2026-07-27.

## What was migrated

- All `pw_*` modules from `local_mods/perfectworld/` modpack
- `pw_remote_control` standalone mod
- `luanti_testkit` universal test framework
- `Dockerfile` for Luanti server build
- `docker-compose.yml` and `docker-compose.test.yml`
- `scripts/`: build-image.sh, install-content.py, sync-local-mods.sh,
  run-test-client.sh, run-test-ui.sh, smoke-test.sh
- Documentation: `perfectworld-architecture.md`
- Configuration: `luanti.conf`, `world.mt.example`

## What was intentionally NOT migrated

- All `aliveworld_*` game modules (events, rumors, chronicle, GPS, tracking,
  claims, sites, routes, settlement simulation, materialization)
- AliveWorld world data, mod storage, logs, screenshots
- Secrets, passwords, API keys
- Git history from the original monorepo
- `ALIVEWORLD_AUDIT.md`

## Cleanup performed

- `luanti_testkit/mod.conf`: removed `optional_depends` on `aliveworld_*` mods
- `luanti_testkit/api.lua`: replaced AliveWorld example in help text
- `luanti_testkit/suites.lua`: replaced AliveWorld example in comment
- `pw_debug/init.lua`: replaced hardcoded `"awbot"` player name with
  `perfectworld.test_player` setting (default: `"pwbot"`)
- `pw_tests/init.lua`: replaced hardcoded `"awbot"` with configurable name
- `pw_remote_control/init.lua`: removed default `"awbot"` player fallback
- `perfectworld/README.md`: removed AliveWorld references
- All container names, world names, and paths updated to PerfectWorld

AliveWorld remains a separate frozen project.
