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

### Determinism Rules

Plans depend ONLY on:
- `world_seed` (from map_meta.txt)
- Region coordinates (rx, rz)
- `planner_version`
- `region_size`

Do NOT use:
- `math.random()` — use `det_prng(seed)`
- Wall-clock time
- Player positions
- Order of chunk generation

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
python3 -m py_compile scripts/install-content.py
git diff --check
bash scripts/smoke-test.sh
# If Lua changed: full test suite
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
