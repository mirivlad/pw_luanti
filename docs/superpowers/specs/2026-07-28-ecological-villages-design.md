# Ecologically Situated Villages

**Date:** 2026-07-28  
**Status:** proposed for implementation  
**Scope:** physical settlement generation only

## Goal

PerfectWorld settlements must be placed and composed as responses to the
physical landscape. A settlement beside usable water should visibly live by
fishing; one on open soil should farm; one in dense woodland should work wood,
bees and game; one at exposed rocky relief should quarry and mine.

This cycle produces physical evidence only. It does not add NPCs, inventories,
resource production, trade, prices or economic simulation.

## Constraints

- Planning remains deterministic: every choice is an independently labelled
  `perfectworld.core.choice` decision.
- Site search is bounded. It never scans an arbitrary region or emerges terrain
  outside the candidate's fixed search envelope.
- Existing materialized settlements are never rebuilt automatically.
- Existing settlement records remain readable.
- New materialization is idempotent and respects protection.
- A failed feature placement rolls back every node it changed.
- Mineclonia node names remain confined to `pw_compat_mcl`.
- `pw_bot_bridge/v1` and `pw_player_bot/v1` do not change.
- `pw_player_bot`, its memory, beliefs, goals, utility and navigation are not
  modified.
- Oracle bridge changes are limited to adapting persisted world records to the
  existing v1 response shapes.
- Runtime visual acceptance uses a real client with the bot runtime's
  `--visible` option.
- Uncommitted bot-runtime and `pw_debug` work belonging to another agent is not
  edited, staged or committed.

## Non-goals

- Residents, professions represented by entities, schedules or population.
- Containers prefilled with produced goods.
- Crop growth simulation or renewable resource accounting.
- Trading, transport or inter-settlement economy.
- Inter-settlement roads, bridges or general tunnel routing.
- Automatic migration or demolition of existing settlements.
- New player-mode perception or bot decision features.

## Selected Architecture

Settlement generation becomes a two-stage deterministic process:

1. The regional planner produces the same stable candidate identity and a
   regional anchor.
2. After the bounded candidate area has emerged, an ecological site selector
   surveys a fixed set of nearby sites and selects the best viable combination
   of buildable ground and local resource specialization.

The selected site drives the existing village grammar:

```text
regional candidate
    -> bounded site candidates
    -> ground/resource survey
    -> viable specialization scores
    -> selected site and primary specialization
    -> roads and specialization-specific lot roles
    -> structures
    -> roads and approaches
    -> bounded production features and decor
    -> validation and persisted record
```

The regional candidate ID does not change when the selected physical center
moves. The record stores both `regional_anchor` and `selected_site`.

## Module Boundaries

### `pw_compat_mcl`

Owns all knowledge of Mineclonia node names and node classification:

- ground below vegetation and tree canopy;
- liquid and shore surfaces;
- soil suitable for fields;
- natural tree trunks and leaves;
- exposed stone;
- abstract decor materials such as barrel, beehive, hay, composter, furnace,
  smoker, anvil, grindstone, rail, chain and campfire.

Planner and structure code consume only these classification/material APIs.

### `pw_settlements`

Owns immutable domain definitions for settlement specializations. A definition
contains:

- stable specialization ID;
- viability rules;
- score weights;
- required role counts;
- optional role ordering;
- conceptual resource features;
- allowed worksite feature kinds.

The first specialization version contains `fishing`, `farming`, `forestry` and
`mining`.

The existing settlement read API remains available. It obtains records from the
planner at call time and therefore does not create a module-load cycle.

### `pw_planner`

Owns bounded site enumeration, survey orchestration, selection, village grammar,
lot placement, persistence and materialization order.

New focused files keep the existing `init.lua` from absorbing unrelated
responsibilities:

- `ecology.lua`: bounded site enumeration, survey metrics and deterministic
  site/specialization selection;
- `worksites.lua`: safe placement and rollback for fields, docks, forestry
  yards and mineheads.

`init.lua` integrates those components into `plan_village` and village
materialization.

### `pw_structures`

Owns registered buildings. It gains three specialization-specific production
buildings while reusing the existing building kit:

- `pw_fishery_v1`;
- `pw_sawmill_v1`;
- `pw_mine_workshop_v1`.

Farming continues to use `pw_farmstead_v1` and `pw_barn_v1`. Each new building
has an ordinary road connector and can be placed and rolled back by the existing
structure pipeline.

### `pw_bot_bridge`

Player perception is unchanged. Oracle perception reads normalized actual
settlement records through `pw_settlements` and road records through `pw_roads`
where possible, falling back to legacy planner records for old worlds.

New specialization metadata may be retained internally by the adapter, but the
shape and meaning of every `pw_bot_bridge/v1` response remains compatible.

## Ground and Resource Survey

### True ground

The current topmost-non-air algorithm treats leaves and trunks as terrain. It
must be replaced in planning and structure analysis with a bounded ground
resolver:

1. scan downward through air;
2. record vegetation, leaves and natural tree columns as resource evidence;
3. skip those nodes while looking for ground;
4. stop at the first non-vegetation solid or liquid surface;
5. return ground Y, ground class and collected canopy evidence.

Terrain preparation may remove vegetation, leaves and natural trunks only
inside the protected, snapshotted modification bounds. It may not clear
arbitrary surrounding forest.

### Site candidates

Each regional anchor evaluates exactly nine sites:

- the anchor itself;
- eight compass sites on a 40-node ring.

The compass order is rotated by a labelled choice so that the labels remain
stable without biasing every region in the same direction. A selected site must
remain inside its regional bounds with the existing regional margin.

Each site surveys an exact 9 by 9 grid with six-node spacing, covering a
48-by-48-node square. At most 729 ground columns are sampled for one regional
candidate. Sampler caching prevents repeated column scans where survey squares
overlap.

### Evidence

The persisted evidence record contains:

```lua
{
  survey_version = 1,
  sample_count = 81,
  buildable_ratio = 0.0,
  soil_ratio = 0.0,
  water_ratio = 0.0,
  tree_ratio = 0.0,
  exposed_stone_ratio = 0.0,
  roughness = 0.0,
  average_slope = 0.0,
  shore_distance = nil,
  shore_direction = nil,
  elevation = 0,
  biome_name = "unknown",
  biome_family = "temperate",
}
```

Ratios are in `[0, 1]`. `shore_distance` is the nearest sampled liquid column
that has a buildable land approach; water without such an approach is not a
valid fishing shore.

### Specialization viability and scores

Biome family is a supporting signal, never sufficient evidence by itself.

`fishing` is viable when:

- `shore_distance <= 30`;
- `water_ratio >= 0.08`;
- `buildable_ratio >= 0.55`.

Its score combines shore distance (45%), water ratio (25%), buildable land
(20%) and a coastal biome-family bonus (10%).

`farming` is viable when:

- `soil_ratio >= 0.60`;
- `buildable_ratio >= 0.70`;
- `roughness <= 3.5`.

Its score combines soil (40%), buildable land (25%), flatness (25%) and a
temperate/dry/cold family bonus (10%).

`forestry` is viable when:

- `tree_ratio >= 0.18`;
- `buildable_ratio >= 0.45`.

Its score combines tree evidence (50%), buildable ground (20%), humidity (15%)
and a forest/cold/wet family bonus (15%).

`mining` is viable when:

- `buildable_ratio >= 0.45`;
- `exposed_stone_ratio >= 0.12` or the site is rocky with
  `roughness >= 2.0`.

Its score combines exposed stone (40%), normalized relief (25%), buildable
ground (20%) and a rocky-family bonus (15%).

All terms are clamped before weighting. The selector chooses the highest-scored
viable site/specialization pair. Exact ties use a labelled choice over sorted
specialization and site IDs. If no pair is viable, materialization records
`no_suitable_ecological_site` and builds nothing.

## Versioning and Persistence

New plans use `settlement_grammar_version = 3`. The version is included in the
village seed key and every new plan/settlement record. The regional planner
version and persistent candidate IDs remain unchanged.

Materialization checks the placed-settlement record before ecological planning.
An existing materialized settlement returns its stored record without being
surveyed, moved or rebuilt.

New settlement records add:

```lua
{
  settlement_grammar_version = 3,
  regional_anchor = {x = 0, z = 0},
  selected_site = {x = 0, y = 0, z = 0},
  specialization = "fishing",
  specialization_score = 0.0,
  resource_features = {"fish", "smoking", "boatwork"},
  ecology = { ...persisted evidence and all specialization scores... },
  worksite_ids = {},
  worksite_kinds = {},
}
```

Legacy records without those fields remain valid and are reported as
`settlement_grammar_version = 2` by normalized read APIs.

## Specialization Grammar

Every complete settlement requires at least two dwellings and one physical
production role matching its primary specialization.

Roles are ordered so required roles are attempted before optional decoration:

### Fishing

- required: `dwelling x2`, `fishery x1`;
- optional: `storage`, `central`, additional dwelling;
- worksite: one shore-connected dock and one drying/smoking yard;
- visible materials: timber piles, barrels, cauldron, smoker, fence-and-chain
  drying racks and lanterns.

### Farming

- required: `dwelling x2`, `farm x1`;
- optional: `barn`, `central`, additional dwelling;
- worksite: fenced crop field and either pen or hay yard;
- visible materials: tilled soil, locally selected crop, hay, composter,
  barrels, fencing and water access.

### Forestry

- required: `dwelling x2`, `sawmill x1`;
- optional: `apiary`, `storage`, `central`, additional dwelling;
- worksite: log-processing yard and, when room exists, apiary or hunting rack;
- visible materials: palette logs and planks, sawmill shed, beehives, campfire,
  barrels and drying frames.

### Mining

- required: `dwelling x2`, `mine_workshop x1`;
- optional: `storage`, `central`, additional dwelling;
- worksite: supported shallow minehead or rock-cut quarry face and ore yard;
- visible materials: stone, cobble, support timbers, rail, furnace, anvil,
  grindstone, lanterns and sparse ore samples.

The production-role structure is a normal planned lot and must connect to a
road. A specialization is never claimed merely because decor happened to fit.

## Worksite Placement

Worksites are physical features attached to a successfully materialized
production lot or to a persisted shore/rock anchor.

Every worksite operation:

1. computes an exact bounded volume;
2. checks that every changed position is unprotected;
3. snapshots nodes and `param2`;
4. verifies feature-specific terrain;
5. places nodes;
6. restores the snapshot on any failure;
7. returns a record containing ID, kind, bounds, anchor, node count and status.

Worksite IDs derive from the settlement ID and stable kind/index labels.
Materialization saves them only after successful placement.

Dock placement follows `shore_direction` from land onto liquid and never fills
the water body. It uses piles down to a bounded depth and rejects unsupported
deep water.

The minehead is a shallow visual adit, not a general tunnel. It may carve only
a fixed depth into natural stone/soil, places support timbers, and closes the
back. It never opens an unbounded cave network.

Fields and yards avoid every planned building footprint and exact road surface.
They are omitted with a recorded error when no bounded placement fits.

## Materialization Order

The order is:

1. production and residential structures;
2. local roads;
3. door approaches and recorded driveways;
4. required specialization worksite;
5. optional worksite/decor;
6. reachability checks;
7. completion status and persistence.

A settlement is `complete` only when:

- two dwellings were materialized;
- the required production structure was materialized;
- its required worksite was materialized;
- every required structure door is reachable from the street;
- all recorded required roles and features validate against the real world.

Optional decor failure does not make a settlement `partial`, but is retained in
`warnings`. Required worksite failure does make it `partial`.

## Roads and Collision Geometry

Planning, worksite collision checks, validation and oracle perception must use
one exact road raster. The raster follows each segment and expands only along
the segment's perpendicular, matching materialization. Width means the exact
number of cells: width 2 is two cells and width 3 is three cells.

The materialized road record stores its exact raster cells or a compact
equivalent sufficient to reproduce them. This removes the current square
dilation mismatch and prevents fields or work yards from overlapping roads.

Legacy road records without a raster continue to use their polyline and width
through the same corrected rasterizer.

## Failure Handling

Expected site failures are data, not Lua errors:

- `no_suitable_ecological_site`;
- `required_role_unplaceable`;
- `shore_worksite_unplaceable`;
- `minehead_unplaceable`;
- `worksite_protected`;
- `worksite_blocked`;
- `worksite_overlaps_structure`;
- `worksite_overlaps_road`.

Unexpected errors are caught at the placement boundary, trigger rollback and
are written to the settlement error list. A failed candidate is persisted with
its survey and rejection diagnostics so repeated generation does not perform
the same expensive work indefinitely.

## Test Strategy

### Pure deterministic tests

- the same evidence and seed always select the same specialization;
- input order and request order do not change selection;
- each specialization wins on an explicit matching evidence fixture;
- biome name alone cannot make an otherwise invalid specialization viable;
- ties are stable;
- all site scans stay within the fixed sample budget.

### Synthetic terrain tests

- forest canopy resolves to the ground below it;
- farming selects open soil and rejects steep ground;
- fishing selects a buildable shore and rejects open water without land;
- mining selects exposed rocky relief and rejects flat soil;
- selected sites remain inside regional bounds;
- no viable site produces an honest failed record.

### Grammar tests

- every viable specialization requests its required production role;
- every viable plan contains at least two dwellings;
- missing required production roles prevent `complete`;
- specialization changes structural fingerprints;
- legacy settlement records still normalize successfully.

### Physical integration tests

- each specialized building is registered and materializes;
- each required worksite records nodes that exist in the real world;
- fields, yards, docks and mineheads do not overlap exact road cells or
  buildings;
- protected worksite placement changes no nodes;
- injected placement failures restore the complete snapshot;
- repeat materialization creates no duplicate nodes or records;
- actual settlement bounds contain structures, doors, roads and worksites;
- existing player-mode bridge integration remains byte-shape compatible.

### Full verification

Run the repository-mandated checks:

```text
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
git diff --check
bash scripts/smoke-test.sh
scripts/run-testkit.sh
```

Inspect server and client logs for:

```text
ERROR|FATAL|ModError|LuaError|AsyncErr|stack traceback
```

The final acceptance tour launches the real runtime with `--visible`. The bot
client visits at least one materialized settlement of each specialization while
the operator can watch the window. Screenshots are diagnostic artifacts only;
oracle and player perception tests continue to use server state.

## Delivery Sequence

1. True-ground classification and pure specialization scoring.
2. Bounded ecological site selection and versioned persistence.
3. Specialization-aware role grammar and required-role validation.
4. Three production buildings and abstract decor materials.
5. Exact shared road raster and collision validation.
6. Transactional fields, dock, forestry yard and minehead.
7. Oracle compatibility adapter.
8. Full automated verification and visible four-specialization acceptance tour.

Each sequence item is independently tested and committed. Only files belonging
to the item are staged. Push occurs after a green checkpoint so existing
uncommitted bot work remains untouched.
