# PerfectWorld Architecture

PerfectWorld is the new physical-world layer for this repository. It is
responsible for settlements, roads, buildings, farms, and later residents and
transport. AliveWorld remains frozen until PerfectWorld provides a real populated
world that AliveWorld can observe.

## Responsibility Boundary

```text
PerfectWorld
    -> physical settlements, roads, buildings, farms
    -> simulation of physical changes
    -> AliveWorld events, rumors, chronicles, quests
```

PerfectWorld does not create rumors or chronicles. AliveWorld should later read
PerfectWorld state instead of inventing abstract events first and materializing
physical evidence afterwards.

## Regional Planner

The world is divided into logical regions. The default region size is
`1024 x 1024` nodes on X/Z and can be changed with:

```text
perfectworld.region_size = 1024
```

The regional plan is the source of truth. A mapgen chunk does not make global
decisions about whether a village, road, or landmark exists. It only materializes
the part of an already determined regional plan that intersects the generated
area.

`perfectworld.planner.plan_region(rx, rz)` returns a plan with composite,
readable IDs:

```lua
{
  id = "region_v1_n2_p3",
  rx = rx,
  rz = rz,
  minp = {x = ..., y = -64, z = ...},
  maxp = {x = ..., y = 256, z = ...},
  planner_version = 1,
  settlement_candidates = {},
  landmarks = {},
  road_anchors = {},
  reserved_areas = {},
}
```

Settlement candidates are proposals, not construction promises:

```lua
{
  id = "settlement_v1_n2_p3_0",
  type = "farm" | "hamlet" | "village",
  x = ...,
  z = ...,
  priority = ...,
  connection_required = true,
  structure_name = "pw_farmstead_v1",
  structure_id = "structure_v1_settlement_v1_n2_p3_0_0",
  rotation = 90,
  status = "candidate",
}
```

## Composite IDs

Persistent PerfectWorld object IDs are deterministic compound strings, not
standalone hash values. The current format is:

```text
region_v1_<rx>_<rz>
settlement_v1_<rx>_<rz>_<index>
road_anchor_v1_<rx>_<rz>_<index>
structure_v1_<settlement_id>_<index>
```

Region coordinates use signed tags: `p0`, `p3`, `n2`. Examples:

```text
region_v1_n2_p3
region_v1_p0_n1
settlement_v1_n2_p3_0
structure_v1_settlement_v1_n2_p3_0_0
```

The hash mixer remains available for local PRNG seeds and fingerprints, but it
is not the sole identity of a persistent world object.

## World Format Lock

On startup `pw_core` stores a ModStorage lock:

```text
world_format_version
planner_version
region_size
world_seed_fingerprint
```

First launch writes the lock. Later launches compare the saved lock with the
current configuration. If `region_size`, `planner_version`,
`world_format_version`, or the world seed fingerprint changes incompatibly,
PerfectWorld logs an explicit error and disables new materialization while
leaving the server running. There is no automatic migration in Structure
Pipeline v1.

## Determinism

Plans must depend only on:

- world seed;
- region coordinates;
- planner version;
- PerfectWorld configuration.

The current seed mixer hashes those values as strings into a local 31-bit seed.
It does not use the global random generator and does not use a simple sum, so
regions such as `(0, 1)` and `(1, 0)` do not collide through commutative mixing.

The following calls must return equivalent plans:

```lua
perfectworld.planner.plan_region(0, 0)
perfectworld.planner.plan_region(0, 0)
```

Request order must not matter:

```text
plan A -> plan B
plan B -> plan A
```

## Logical Plan vs Materialization

The logical plan describes intended objects. Materialization is the physical
placement of nodes into generated map areas.

Structure Pipeline v1 materializes the first suitable settlement candidate as a
registered `pw_farmstead_v1`. This validates:

- planner-to-mapgen wiring;
- stable coordinates;
- duplicate prevention through placement records;
- chunk selection based on planned objects.

Mapgen does not know the farmstead node layout. It obtains the structure
definition from the registry and calls `perfectworld.structures.place`.

## Structures

Structures are registered through:

```lua
perfectworld.structures.register(name, definition)
perfectworld.structures.get(name)
perfectworld.structures.list()
perfectworld.structures.validate(definition)
perfectworld.structures.place(name, context)
```

Definitions allow future `.mts` schematics and current procedural Lua
generators:

```lua
{
  version = 1,
  size = {x = 15, y = 7, z = 14},
  origin = {x = 7, y = 0, z = 6},
  categories = {"settlement", "farm"},
  weight = 1,
  allowed_settlement_types = {"farm", "hamlet", "village"},
  rotations = {0, 90, 180, 270},
  terrain = {
    max_slope = 2,
    foundation_depth = 3,
    clearance_height = 8,
  },
  connectors = {
    {type = "road", side = "south", offset = 0, offset_pos = {x = 0, y = 0, z = 7}},
  },
  placement = {
    type = "lua" | "schematic",
    generator = function(context, def) end,
    schematic = "path/to/file.mts",
  },
}
```

Mineclonia nodes are resolved through `pw_compat_mcl`. Core planning code should
not depend on `mcl_*` node names.

`get()` returns a defensive copy. Invalid definitions are rejected before mapgen
uses them, so bad registrations fail with a meaningful error instead of a deep
placement crash.

## Mineclonia Compatibility

`pw_compat_mcl` exposes abstract materials via:

```lua
perfectworld.compat.get_material("wall")
perfectworld.compat.get_material("foundation")
perfectworld.compat.get_material("roof")
```

The first farmstead uses:

| Abstract material | Current Mineclonia node |
| --- | --- |
| `foundation` | `mcl_core:cobble` |
| `wall` | `mcl_core:wood` |
| `roof` | `mcl_stairs:slab_oak` |
| `floor` | `mcl_core:wood` |
| `road` | `mcl_core:coarse_dirt` |
| `fence` | `mcl_fences:fence` |
| `door` | `mcl_doors:door_oak_b_1` |
| `door_top` | `mcl_doors:door_oak_t_1` |
| `window` | `mcl_core:glass` |
| `light` | `mcl_torches:torch` |
| `bed` | `mcl_wool:white` |
| `container` | `mcl_chests:chest` |
| `garden_soil` | `mcl_farming:soil` |
| `crop` | `mcl_farming:carrot_4` |

Optional materials have documented fallbacks such as `window -> air`,
`crop -> air`, and `fence -> mcl_core:wood`. Required material lookup errors
before placement starts.

## Terrain Preparation

Placement computes the rotated footprint, scans surface heights, and rejects
missing surfaces or slopes above the structure's `terrain.max_slope`.

For `pw_farmstead_v1`, the pipeline builds a flat terrace:

- fill `foundation_depth` below the prepared floor;
- clear replaceable nodes and common plant nodes up to `clearance_height`;
- reject protected or blocked nodes;
- roll back changes if preparation or generation fails.

### Terrain Analysis Contract

`analyze_terrain(def, origin, rotation)` checks the building footprint expanded
by `modification_margin` on X/Z:

1. **Missing surface** — any column without a solid surface node → rejected.
2. **Slope too steep** — `max_y - min_y > max_slope` → rejected with `slope_too_steep`.
3. **Excessive cut** — any column with `reference_y - surface_y > max_cut_depth` → rejected with `excessive_cut`.
4. **Excessive fill** — any column with `surface_y - reference_y > max_fill_height` → rejected with `excessive_fill`.

The checks run in order: slope first, then cut, then fill. If slope exceeds
the limit, cut/fill are not evaluated. This is by design: slope is the primary
terrain fitness signal, and a sloped site requires different handling (future
slope-adaptive placement) regardless of cut/fill values.

`reference_y = max_y` across the checked area.

### Modification Margin Contract

`modification_margin` (default 1) expands the checked and modified area beyond
the building footprint on X and Z only. Y bounds are controlled by
`foundation_depth` and `clearance_height`.

- **Inside building footprint** (X/Z): full terrain modification — foundation
  fill below surface, air clearance above.
- **Inside margin zone** (footprint ± `modification_margin`): smooth blend
  transition. The `edge_blend` function produces a linear fade from 1 (fully
  inside footprint) to 0 (at distance = margin from footprint edge).
- **Beyond margin**: no modification. Nodes at distance > margin from the
  building footprint are not touched by `prepare_terrain`.

The footprint bounds and margin are inclusive: a node exactly at
`building_maxp.x + margin` is within the preparation loop and receives blend = 1
(if inside footprint) or blend ∈ (0, 1) (if in blend zone). The first node at
`building_maxp.x + margin + 1` is outside and unmodified.

`prepare_terrain` is idempotent: calling it twice on the same prepared area
produces the same result as calling it once.

This is intentionally simple. It avoids partial buildings and floating parts but
does not yet adapt individual building modules to slopes.

## Rotation

`pw_farmstead_v1` supports `0`, `90`, `180`, and `270` degrees. Rotation is
deterministically selected in the regional plan. Local coordinates and road
connectors rotate together, so the door path, garden, windows, roof, and road
anchor metadata remain consistent.

## Mapgen Ownership

The owner of a materialization attempt is the mapgen chunk containing the
settlement candidate center. Before placement, the registry pipeline loads the
full rotated footprint area, then places the whole structure atomically. Neighbor
chunks may contain parts of the result, but they do not create duplicate records
because ModStorage tracks placed settlement IDs and materialized structure IDs.

The current materialization record shape is:

```lua
{
  structure_id = "structure_v1_settlement_v1_n2_p3_0_0",
  structure_name = "pw_farmstead_v1",
  definition_version = 1,
  status = "materialized",
  position = {x = ..., y = ..., z = ...},
  rotation = 90,
  region_id = "region_v1_n2_p3",
  settlement_id = "settlement_v1_n2_p3_0",
}
```

Debug command:

```text
/pw_structure <structure_id>
/pw_materialize <rx> <rz> <index> [force]
```

`/pw_materialize` is for development and screenshots. It does not place nodes
directly; it selects a candidate from the regional plan and calls the same
structure placement pipeline as mapgen.

Screenshot artifact for Structure Pipeline v1:

```text
artifacts/perfectworld/pw_farmstead_v1.png
```

## Village Generation System (v2)

The village generation system replaces the original single-template village
with a biome-aware, multi-archetype grammar pipeline.

### Environment Profile

`pw_compat_mcl.get_environment(pos)` normalises Mineclonia biome data:

```lua
environment = {
  biome_id       -- raw biome identifier
  biome_name     -- resolved string name (from numeric registry)
  biome_family   -- one of: temperate, forest, cold, dry, rocky, wet, coastal
  heat           -- 0–100 heat point
  humidity       -- 0–100 humidity point
  elevation      -- Y coordinate
  roughness      -- sampled surface height variation (0 = flat)
  average_slope  -- alias for roughness
  water_proximity -- distance to nearest water block, or 999
  vegetation_density -- percentage of surface columns with flora
  available_material_profile -- alias for biome_family
}
```

Biome family mapping lives in `pw_compat_mcl` only — no `if biome_name == ...`
checks in planner code. Unknown biomes fall back to `"temperate"` via
heuristic name matching.

### Village Profile

`perfectworld.planner.create_village_profile(candidate, environment)` produces
a deterministic profile:

```lua
profile = {
  village_id          = candidate.id
  generator_version   = PLANTER_VERSION
  environment         = { ... }
  seed_key            = stable_hash("village_v2" | region_seed | candidate.id | biome_family | roughness | planner_version)
  archetype           = "linear" | "compact" | "hillside"
  size_class          = "small"(3-5) | "medium"(5-8) | "large"(8-12)
  target_lots
  density
  road_character      = { main_length, branches, curve, crossing }
  lot_spacing         = { min_gap, max_gap, depth, set_back }
  structure_roles     = ["dwelling", "farm", "utility", "central", ...]
  material_palette    = { foundation, wall_primary, wall_secondary, roof, path, fence }
  variation_parameters = { dwelling_variant, orientation_noise, spacing_jitter }
}
```

### Three Archetypes

| Archetype | Terrain | Road Graph | Characteristics |
|-----------|---------|------------|-----------------|
| `linear` | Flat valley, shore, narrow corridor | One curved main street | Lots on one or both sides, variable spacing, possible gaps |
| `compact` | Open flat area, low roughness | Crossroads + branches | Denser, central public lot, multiple short streets |
| `hillside` | Sloped, rocky, high roughness | Contour-following road | Lateral shifts to maintain gentle grade, stepped lots |

Archetype selection uses weighted random with modifiers: roughness, water
proximity, and biome family all influence the weights.

### Grammar Pipeline

Each village is built through an 11-step grammar, not from a fixed template:

1. Select archetype (weighted by terrain)
2. Build road skeleton (points along angles, with curves and branches)
3. Allocate lots along roads (with spacing jitter, terrain suitability checks)
4. Filter lots by terrain (water avoidance, max slope 4)
5. Assign roles to lots (dwelling, farm, utility, central, optional)
6. Select structure variants per role
7. Orient structures toward road
8. Check footprint overlaps and filter
9. Form immutable materialization plan
10. Materialize: roads first, then structures (each via `structures.place`)
11. Save settlement record with fingerprint

### Material Palettes

Seven palettes provide biome-appropriate materials:

| Family | Foundation | Wall Primary | Roof | Path |
|--------|-----------|-------------|------|------|
| temperate | cobble | wood | oak slab | coarse dirt |
| forest | cobble | wood | oak slab | dirt |
| cold | stone | wood | oak slab | gravel |
| dry | sandstone | sandstone | tree trunk | sand |
| rocky | stone | stone | stone | gravel |
| wet | cobble | wood | oak slab | dirt |
| coastal | stone | wood | oak slab | sand |

### Settlement Record

Saved via `pw_planner` mod_storage under the settlement plan key:

```lua
settlement = {
  settlement_id       = candidate.id
  candidate_id        = candidate.id
  region_id
  generator_version
  status              = "complete" | "partial"
  center_pos
  bounds              = { min_x, max_x, min_z, max_z }
  environment_profile = { ... }
  archetype
  village_fingerprint  = stable_hash
  structure_ids        = [ ... ]
  road_ids             = [ ... ]
  lot_count
  created_at           = game_time
}
```

API: `pw_settlements.get(id)`, `.list_ids()`, `.list()`, `.get_by_candidate(id)`.

### Deterministic Variation

All randomness flows from `village_prng_new(seed_key)` where seed_key depends on:
`region_seed + candidate.id + biome_family + roughness + planner_version`.
Same inputs always produce the same plan, profile, and fingerprint. Different
regions produce different results — not clones with shifted coordinates.

### Fingerprint

`stable_hash("v2" | archetype | biome_family | road_count | lot_count | size_class | [role, name, rotation, x, z for each lot] | [road_kind, point_count, first_point for each road])`

Used for determinism verification, save diagnostics, and cross-region comparison.

### Debug Commands

- `/pw_village_list` — list all materialized settlements
- `/pw_village_info [id]` — detailed info (archetype, fingerprint, lots, roads)
- `/pw_village_tp <id>` — teleport to settlement center

## Future Roads

`pw_roads` currently defines the API boundary only. Future work should add:

- local settlement paths;
- roads between settlements;
- regional roads;
- trade routes.

Road planning should consume regional plans and road anchors. It should not let
individual mapgen chunks independently decide long-distance roads.

## Future AliveWorld Integration

AliveWorld should be unfrozen only after PerfectWorld can provide enough real
physical state for events to reference:

- physical farms, hamlets, and villages;
- basic road network;
- structure registry with real buildings;
- mapgen-safe materialization;
- basic population and economic state.

At that point AliveWorld can observe PerfectWorld settlements, roads, residents,
and changes, then produce events, rumors, chronicles, and quests from real world
state.
