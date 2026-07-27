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

Seed keys are strings built from those values; every decision is an independent
`hash32(seed_key .. "#" .. label)`. Nothing uses the global random generator,
and nothing uses a simple sum, so regions such as `(0, 1)` and `(1, 0)` do not
collide through commutative mixing. See
[Stable Variation Contract](#stable-variation-contract) for why a stream PRNG
was not usable here.

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
  biome_id       -- numeric biome id as returned by minetest.get_biome_data
  biome_name     -- resolved string name (minetest.get_biome_name)
  biome_family   -- one of: temperate, forest, cold, dry, rocky, wet, coastal
  heat           -- 0-100 heat point
  humidity       -- 0-100 humidity point
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

`minetest.get_biome_data().biome` is a numeric biome **id**, while
`minetest.registered_biomes` is keyed by **name**. Resolution must therefore go
through `minetest.get_biome_name(id)`; indexing the registry with an id silently
misses and collapses every biome in the world to `"temperate"`.

### Stable Variation Contract

Planning decisions are **not** drawn from a sequential PRNG. Each decision is an
independent hash of a seed key and a label:

```text
hash32(seed_key | "archetype")
hash32(seed_key | "size_class")
hash32(seed_key | "road:main:direction")
hash32(seed_key | "lot:5:variant")
hash32(seed_key | "lot:5:rotation")
```

`perfectworld.core.choice` provides `unit`, `index`, `int`, `range`, `pick`,
`bool`, `weighted` and `shuffle` on top of `perfectworld.core.hash32`.

Properties a stream generator cannot offer:

- adding a new decision anywhere leaves every other decision untouched;
- decisions can be evaluated in any order, or skipped entirely;
- a single decision is reproducible in isolation, which makes golden tests cheap.

`hash32` splits every multiplication into 16-bit limbs, so the largest
intermediate is `2^48`. Lua numbers here are IEEE-754 doubles, exact only up to
`2^53`; the previous LCG multiplied a 31-bit state by 1103515245, reaching
`2.37e18` — 263x above the exact range — and lost the low ~9 bits of every
step. Measured in the shipped LuaJIT build, that collapsed the generator to a
single cycle of length **10466** with states quantised to multiples of 64.

Seed keys depend only on world seed, region coordinates, candidate id, planner
version and region size. Terrain influences the plan through decision
**weights**, never through the seed.

### Three Archetypes

| Archetype | Terrain | Road Graph | Characteristics |
|-----------|---------|------------|-----------------|
| `linear` | Flat valley, shore, narrow corridor | One main street, optionally curved | Lots on both sides, variable spacing |
| `compact` | Open flat area, low roughness | Crossroads plus branches | Denser, central public lot, multiple streets |
| `hillside` | Sloped, rocky, high roughness | Contour-following street plus spur | Lateral shifts to hold a gentle grade, terraced lots |

Archetype selection is weighted by roughness, water proximity and biome family.
Main streets snap to one of eight compass directions: a free angle turns into
staircase noise on a block grid.

**Documented fallback.** The archetype is chosen from the environment profile
before any lot has been tested against the ground. If a flat archetype produces
no viable layout, the planner retries once as `hillside` with the same seed key
and records `archetype_fallback_from`. This is deterministic.

### Grammar Pipeline

1. Emerge the site (a village spans ~110 blocks; the mapchunk holding its
   centre is never enough terrain to plan on).
2. Read the environment profile at the real surface.
3. Build the profile: archetype, size class, target lots, road character, lot
   spacing, role composition, palette.
4. Build the road skeleton for the archetype.
5. Generate lot anchors along every road, both sides.
6. For each anchor, in role order: pick the structure variant, orient it so its
   road connector faces the street, then push it away from the kerb until its
   footprint clears the carriageway and every neighbour.
7. Validate the ground under the **building footprint** with the structure's own
   slope limit — the same limit `analyze_terrain` will apply at placement time.
8. Compute bounds, role counts and the three fingerprints.
9. Materialize structures first (terrain preparation reshapes the surface and
   would otherwise bury the roads).
10. Lay roads perpendicular to their direction of travel, then a driveway from
    every placed door to its road point.
11. Save the settlement record and mark the candidate placed.

Setback is a property of the building, not a constant: a nine-block barn stands
further back from the kerb than a three-block well.

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

The palette is passed to `structures.place` as `context.palette` and reaches
`prepare_terrain` (foundation) and every building generator (walls, roof,
floor, paths, fences) through `perfectworld.structures.palette_material`.
Joinery — doors, glass, torches, furniture — stays on the generic material
table. An unregistered palette node falls back to the generic role.

### Buildable Ground

A column cannot carry a settlement when its surface is liquid, is in the `ice`,
`water` or `lava` groups, or has liquid within three blocks under a thin solid
crust. Checking only for `"water"` in the node name is not enough: a frozen
ocean is flat, solid, walkable and opaque, so every geometric check passes and
the planner will lay a crossroads across the sea.

Road polylines are laid out geometrically, before any terrain is consulted, and
are then **trimmed** to the contiguous run around the settlement centre where
the ground exists, is buildable, and rises no more than three blocks per
two-block step. Without the trim a street runs off a clifftop and into the
water, which is the single most obvious way a generated settlement stops
looking built.

### Terrain Adaptation

`context.terrain_overrides` relaxes a structure's terrain contract for one
placement. Hillside villages use
`{max_slope = 5, max_cut_depth = 5, max_fill_height = 4, foundation_depth = 4}`
so they terrace into a slope instead of being rejected.

Terrain preparation writes only inside the building footprint plus
`modification_margin` (1 block), so a settlement can never carve a large
artificial platform. Where the downhill side of a footprint would sit above
open air, the foundation is carried down as a plinth until it meets solid
ground, bounded by `max_plinth_depth` (default 12).

### Completeness Contract

| Status | Meaning |
|--------|---------|
| `complete` | Every planned lot built, no placement errors, at least `MIN_DWELLINGS` (2) dwellings |
| `partial` | Something was built, but a lot failed or a required role is missing |
| `failed` | Nothing was built |

A plan with no viable layout is persisted as `failed` and never materialized.
"The map is not generated here yet" is a transient condition, not a verdict:
it returns `terrain_not_ready` and leaves the candidate unplaced.

### Settlement Record

```lua
settlement = {
  settlement_id, candidate_id, region_id, generator_version, seed_key,
  status                = "complete" | "partial" | "failed",
  center_pos, bounds    = { min_x, max_x, min_z, max_z },
  environment_profile, biome_name, biome_family,
  archetype, size_class, palette_id, material_palette,
  required_roles, optional_roles, missing_required_roles, role_counts,
  exact_plan_fingerprint, structural_fingerprint, road_graph_fingerprint,
  village_fingerprint   -- legacy alias for exact_plan_fingerprint
  structure_ids, structure_variants,
  road_ids, road_segment_count,
  lot_count, planned_lot_count, errors, created_at,
}
```

API: `pw_settlements.get(id)`, `.list_ids()`, `.list()`, `.get_by_candidate(id)`.

### Fingerprints

Three fingerprints answer three different questions.

**`exact_plan_fingerprint`** — is this literally the same plan?
Full normalised geometry with no quantisation: every lot (relative position,
role, structure name, rotation, road point) and every road (kind, width, every
point relative to the centre), each sorted canonically. A one-block difference
changes it.

**`structural_fingerprint`** — does this look like the same village?
Positions quantised to a 4-block grid, plus archetype, size class, palette, lot
and road counts, segment count and the role/structure multisets. Two plans that
differ by a one-block nudge share a structural fingerprint on purpose.

**`road_graph_fingerprint`** — is this the same street network?
Canonical, with an explicit contract:

- coordinates are relative to the settlement centre, so absolute world position
  never creates false uniqueness;
- a segment is **undirected**: written from either end it yields the same token,
  because the lexicographically smaller endpoint is emitted first;
- segments are sorted, so Lua table order and the order in which independent
  roads were generated do not matter;
- per-node degrees are appended, so two graphs over the same point set but with
  different connections differ;
- every intermediate point is kept, so different bends differ;
- road ids, kinds and names are excluded — this is geometry and topology only.

### Validation

`perfectworld.planner.validate_settlement(id)` checks the record **and the real
world**. A record in mod_storage is not evidence that anything was built.

| Check | What it proves |
|-------|----------------|
| `complete_has_lots`, `complete_has_required_roles`, `complete_has_no_errors`, `complete_fully_materialized` | the completeness contract holds |
| `failed_has_no_lots` | a failed settlement really built nothing |
| `has_fingerprints` | all three fingerprints are recorded |
| `structures_resolve`, `roads_resolve` | every referenced id exists |
| `footprints_disjoint` | buildings do not intersect |
| `terrain_prep_isolated` | preparing one lot cannot damage its neighbour |
| `roads_avoid_buildings` | no carriageway crosses a building |
| `lots_connected_to_road` | every building reaches the network (driveways count) |
| `doors_accessible` | the node outside each door is passable |
| `bounds_contain_all` | bounds cover every structure and road cell |
| `structures_present_in_world` | the nodes are actually there |
| `no_floating_buildings` | solid ground under every footprint corner |
| `nodes_registered` | no unknown nodes were placed |
| `no_oversized_platform` | terrain modification margin stays within contract |
| `no_duplicate_structures` | re-materialization did not clone anything |

### Diversity Analysis

`perfectworld.planner.build_analysis_sample{mode, count}` builds a
deterministic sample of >= 100 planning inputs; `analyze_input(input)` plans one
and returns a flat row.

- `synthetic` mode drives `make_synthetic_terrain`, which produces coherent
  value-noise relief on a lattice. It covers flat lowland and upland, gentle and
  steep slopes, rolling and rough ground, shoreline, submerged and cliff sites,
  crossed with every biome family, several world seeds and the fallback biome.
  It needs no map generation, so it also runs inside the test suite.
- `world` mode plans against the live map and emerges each site first.

Metrics: input/valid/rejected/empty counts, archetype, biome family, palette,
size class and lot count distributions, unique exact / structural / road graph
fingerprints, unique lot layouts, role and structure compositions, duplicate
groups and rejection reasons.

### Debug Commands

- `/pw_village_list` — list all materialized settlements
- `/pw_village_info [id]` — full settlement contract (nearest one if omitted)
- `/pw_village_tp <id>` — teleport to settlement centre
- `/pw_village_validate [id]` — run the physical validator
- `/pw_village_validate_all` — validate every record and summarise failures
- `/pw_village_batch [count] [region_radius]` — materialize planned villages,
  spread across biome families
- `/pw_village_analyze [synthetic|world] [count]` — write a diversity report
- `/pw_village_export` — write every record plus its validation report
- `/pw_village_shotlist` — write camera setups and metadata for screenshots
- `/pw_photo_at <x> <y> <z> <tx> <ty> <tz>` — exact reproducible camera
## Future Roads

`pw_roads` currently defines the API boundary only. Future work should add:

- local settlement paths;
- roads between settlements;
- regional roads;
- trade routes.

Road planning should consume regional plans and road anchors. It should not let
individual mapgen chunks independently decide long-distance roads.

## Bot Bridge

`pw_bot_bridge` is a server mod that turns PerfectWorld's world state into a
structured, versioned perception API. It exists for two consumers: a future
PW Bot, which will connect as an ordinary player and needs senses, and the test
kit, which needs an exact instrument for checking what the generator actually
built.

```
PerfectWorld world state
        |
        v
pw_bot_bridge
        |
        v
player / oracle observation
        |
        v
future pw_bot memory and logic        <- not implemented
        |
        v
future real-client controller          <- not implemented
        |
        v
real Luanti client actions
```

The bridge observes and explains; it never acts. It does not move a player, turn
a head, open a door, attach anyone to a vehicle, or write a node. That boundary
is what makes the bot worth having: a server-side mod that teleports a player
tests the server's idea of the world, while a real client walking with real
inputs tests the world as a player meets it — collision boxes, step height, the
door that turns out to be one node too high. Every interesting defect this
project has found lived in that gap.

Two modes, both read-only:

| Mode | Contract |
|------|----------|
| `player` | a deterministic server-side approximation of the programmatic perception available to a player, bounded by position, look direction, field of view, view distance and line of sight |
| `oracle` | exact world data within configured limits, for the test kit, a coding agent and generator diagnostics |

Oracle mode reads the same records the rest of this document describes —
settlement plans, lots, structures with their rotations and footprints, road
polylines, doorways — and adds physical verdicts on top of them: whether a road
hangs over a hole, whether a plot is flooded, whether a doorway can be stood in.
That makes it the natural place to build automated checks of the village grammar
described above.

The protocol is `pw_bot_bridge/v1`. Any incompatible change to it requires a new
version, not a silent edit.

Full documentation: [docs/pw-bot/](pw-bot/README.md).

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
