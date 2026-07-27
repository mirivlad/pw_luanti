# Development Guide

## Architecture Overview

See `docs/perfectworld-architecture.md` for the detailed design document.

### Dependency Graph

```
pw_core  ←  (root, no dependencies)
  ↑
  ├── pw_compat_mcl  (depends: pw_core)
  ├── pw_planner     (depends: pw_core, opt: pw_structures)
  ├── pw_structures  (depends: pw_core, opt: pw_compat_mcl)
  ├── pw_roads       (depends: pw_core, pw_planner)
  ├── pw_settlements (depends: pw_core) [skeleton]
  ├── pw_population  (depends: pw_core) [skeleton]
  ├── pw_debug       (depends: pw_core, opt: pw_planner, pw_structures)
  ├── pw_bot_bridge  (depends: pw_core, opt: pw_compat_mcl, pw_planner,
  │                    pw_structures, pw_roads, pw_settlements, luanti_testkit)
  ├── pw_player_bot  (depends: pw_core, pw_bot_bridge, opt: pw_compat_mcl,
  │                    pw_planner, luanti_testkit)
  └── pw_tests       (depends: luanti_testkit, pw_core, pw_planner, pw_structures, pw_compat_mcl)

luanti_testkit  ←  (no game dependencies)
pw_remote_control  ←  (standalone)
```

### Key Abstractions

**Region** — 1024×1024 logical unit. Source of truth for planning.

**Settlement Candidate** — proposed location with type (farm/hamlet/village),
priority, structure assignment, rotation. Created by `plan_region()`, materialized
by `materialize_chunk()`.

**Structure** — registered building definition. Has:
- `size`, `origin` — dimensions
- `terrain` — slope/cut/fill constraints
- `connectors` — road attachment points
- `placement` — lua generator or schematic

**Road** — persisted polyline between connectors. Stored under `pw_roads` key
in mod_storage.

**Bot bridge** — `pw_bot_bridge` gives a future PW Bot programmatic senses, and
gives the test kit an exact instrument for inspecting what the generator built.
It observes and explains; it never moves a player, turns a head, opens a door or
writes a node. Two modes: `player` (a deterministic server-side approximation of
what a player could know, bounded by position, look direction, FOV, range and
line of sight) and `oracle` (exact data within limits, for tests and
diagnostics). See [docs/pw-bot/](pw-bot/README.md).

When a subsystem introduces a new material or object that the bot should
understand, register it centrally:

```lua
pw_bot_bridge.register_node_semantics("pw_ports:pier_deck", {"dock", "road_surface"})
```

Never add a node-name check inside the perception code instead.

**Bot brain** — `pw_player_bot` is the decision half. It asks the bridge, in
player mode only, what its player can perceive; keeps a bounded, decaying,
persisted memory of the answers; derives beliefs about what is walkable and
where the edge of its knowledge lies; turns its condition into five needs;
scores seven kinds of goal against them; plans a route across remembered
columns only; and writes an intent document. It decides and stops — moving,
turning and interacting belong to a future runtime driving a real client, which
does not exist. It never reads the map directly and never calls `math.random`;
`scripts/smoke-test.sh` enforces both. See
[docs/pw-bot/player-bot.md](pw-bot/player-bot.md).

A subsystem that adds something the bot should walk over to look at registers
its interest rather than editing `goals.lua`:

```lua
pw_player_bot.set_feature_interest("dock", 0.7)
```

### Determinism Rules

Plans depend ONLY on:
- `world_seed` (from map_meta.txt)
- Region coordinates (rx, rz)
- `planner_version`
- `region_size`

Use `perfectworld.core.choice` for every planning decision:

```lua
local choice = perfectworld.core.choice
local seed_key = perfectworld.planner.village_seed_key(candidate)

profile.archetype = choice.weighted(seed_key, "archetype", weights)
lot.rotation      = choice.pick(seed_key, "lot:" .. i .. ":rotation", def.rotations)
```

Each decision is an independent hash of `(seed_key, label)`, so adding a new
decision never shifts the existing ones. Labels must be stable strings —
changing one moves every existing world's layout.

Do NOT use:
- `math.random()`
- a sequential PRNG of any kind (see the LCG post-mortem in
  `docs/perfectworld-architecture.md`: double rounding collapsed the previous
  one to a 10466-long cycle)
- Wall-clock time
- Player positions
- Order of chunk generation

### Integer arithmetic

Lua numbers here are IEEE-754 doubles and only exact up to `2^53`. Any product
above that silently loses low bits. Use `perfectworld.core.mul32` for 32-bit
multiplication and keep hand-written arithmetic below `2^53`.

### Idempotency Rules

- `plan_region(rx, rz)` returns the same plan every call
- `materialize_chunk(minp, maxp)` checks `is_placed()` before placing
- `save_road()` overwrites, doesn't duplicate
- World format lock prevents silent corruption on config changes

## Adding a Structure

```lua
perfectworld.structures.register("pw_my_building_v1", {
  version = 1,
  size = {x = 7, y = 5, z = 7},
  origin = {x = 3, y = 0, z = 3},
  categories = {"residential"},
  allowed_settlement_types = {"hamlet", "village"},
  rotations = {0, 90, 180, 270},
  terrain = {
    max_slope = 3,
    max_cut_depth = 2,
    max_fill_height = 2,
    foundation_depth = 2,
    clearance_height = 5,
  },
  connectors = {
    {type = "road", side = "south", offset = 0},
  },
  placement = {
    type = "lua",
    generator = function(context, def)
      -- Place nodes using minetest.set_node()
      -- context.pos = origin in world coords
      -- context.rotation = 0/90/180/270
      -- Use: perfectworld.compat.get_material("wall")
    end,
  },
})
```

## Running the Test Suite

```bash
scripts/run-testkit.sh
```

Starts the test server, connects `pwbot`, grants privileges, triggers the full
run and prints the report summary. `--keep` reuses a running server;
`--no-client` skips the client. To re-print the latest report:

```bash
python3 scripts/report-summary.py
```

## Adding a Test

1. Create file `local_mods/perfectworld/pw_tests/tests/my_feature.lua`
2. Register tests:

```lua
local T = luanti_testkit

T.register_test("perfectworld", "my_feature_works", function(ctx)
  -- Test logic
  ctx.assert.equal(2 + 2, 4, "basic math")
end)
```

3. The file is auto-loaded by `pw_tests/init.lua` (add to `test_files` list there)

## Smoke Tests

```bash
bash scripts/smoke-test.sh
```

Checks: file existence, no aliveworld references, basic structure.

## Before Commit

```bash
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
git diff --check
bash scripts/smoke-test.sh
# If Lua changed: full test suite
scripts/run-testkit.sh
```

Lua syntax can be checked without a server:

```bash
docker run --rm --entrypoint luajit -v "$PWD/local_mods:/m" perfectworld-luanti \
  -e "local f,e=loadfile('/m/perfectworld/pw_planner/init.lua') print(f and 'OK' or e)"
```

## Mod Storage Keys

| Key | Module | Content |
|-----|--------|---------|
| `pw_world_format_lock` | pw_core | Format version, planner version, region size, seed fingerprint |
| `pw_placed_settlements` | pw_planner | Set of placed settlement IDs |
| `pw_materialized_structures` | pw_planner | Structure materialization records |
| `pw_settlement_plans` | pw_planner | Village layout plans |
| `pw_roads` | pw_planner | Road records |

## Node Safety

Before placing/removing nodes:
- Check `minetest.is_protected(pos, player_name)`
- Classify existing node: air, vegetation, leaves, trunk, snow, liquid, solid
- Never replace nodes with metadata/inventory
- Use `perfectworld.compat.is_replaceable(name)` for safe removal
