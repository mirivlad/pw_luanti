# Ecologically Situated Villages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate deterministic physical villages whose selected site, production buildings and bounded decor visibly express fishing, farming, forestry or mining.

**Architecture:** Keep regional candidate identities stable, then select one of nine bounded physical sites after emerge by scoring measured resource evidence. `pw_settlements` owns pure specialization definitions, `pw_planner` owns survey/selection/materialization, `pw_roads` owns exact shared raster geometry, `pw_structures` owns production buildings, and the oracle bridge adapts normalized records without changing either v1 protocol.

**Tech Stack:** Luanti 5.16 Lua, Mineclonia compatibility APIs, ModStorage JSON, Luanti TestKit, Docker Compose, real `pw_bot_runtime --visible` client.

## Global Constraints

- Physical generation only: no NPCs, inventories, production, trade or economy.
- Never edit, stage or commit the existing dirty `pw_debug` and `tools/pw_bot_runtime` files.
- Do not change `pw_bot_bridge/v1`, `pw_player_bot/v1`, player perception or any `pw_player_bot` file.
- Existing materialized settlements remain unchanged and legacy records remain readable.
- Every planning choice uses independently labelled `perfectworld.core.choice`; no PRNG stream or `math.random`.
- Mineclonia node names appear only in `pw_compat_mcl`.
- Every world mutation checks protection and rolls back on failure.
- Site search is exactly nine sites and no more than 729 sampled columns per candidate.
- Runtime acceptance uses a real bot client with `--visible`.
- Stage only explicit task files, commit each green task and push checkpoints to `origin/master`.

---

### Task 1: True-ground classification and specialization scoring

**Files:**
- Create: `local_mods/perfectworld/pw_settlements/specializations.lua`
- Create: `local_mods/perfectworld/pw_tests/tests/ecology.lua`
- Modify: `local_mods/perfectworld/pw_settlements/init.lua`
- Modify: `local_mods/perfectworld/pw_compat_mcl/init.lua`
- Modify: `local_mods/perfectworld/pw_tests/init.lua`
- Modify: `local_mods/perfectworld/pw_tests/mod.conf`

**Interfaces:**
- Produces: `perfectworld.compat.classify_node(node_name) -> classification`
- Produces: `perfectworld.compat.is_natural_vegetation(node_name) -> boolean`
- Produces: `perfectworld.settlements.SPECIALIZATION_VERSION == 1`
- Produces: `perfectworld.settlements.get_specialization(id) -> defensive copy|nil`
- Produces: `perfectworld.settlements.list_specializations() -> sorted IDs`
- Produces: `perfectworld.settlements.evaluate_specializations(evidence) -> sorted result array`

- [ ] **Step 1: Register a focused ecology test file**

Add `"ecology"` to `pw_tests/init.lua` and make `pw_settlements` and `pw_roads`
required by `pw_tests/mod.conf`.

Start `tests/ecology.lua` with classification and scoring fixtures:

```lua
local T = luanti_testkit

local function evidence(overrides)
  local value = {
    buildable_ratio = 0.8, soil_ratio = 0.1, water_ratio = 0,
    tree_ratio = 0, exposed_stone_ratio = 0, roughness = 1,
    average_slope = 1, shore_distance = nil, elevation = 40,
    humidity = 0.5, biome_family = "temperate",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

T.register_test("perfectworld", "ecology_classifies_ground_below_canopy", function(ctx)
  local trunk = perfectworld.compat.classify_node("mcl_trees:tree_oak")
  local leaves = perfectworld.compat.classify_node("mcl_trees:leaves_oak")
  local soil = perfectworld.compat.classify_node("mcl_core:dirt_with_grass")
  local stone = perfectworld.compat.classify_node("mcl_core:stone")
  ctx.assert.is_true(trunk.tree, "oak trunk must be tree evidence")
  ctx.assert.is_true(leaves.vegetation, "oak leaves must be vegetation")
  ctx.assert.is_true(soil.soil and soil.buildable_ground, "grass must be buildable soil")
  ctx.assert.is_true(stone.stone, "stone must be exposed-stone evidence")
end)

T.register_test("perfectworld", "ecology_matching_evidence_selects_each_specialization", function(ctx)
  local fixtures = {
    fishing = evidence({water_ratio = 0.3, shore_distance = 8, biome_family = "coastal"}),
    farming = evidence({soil_ratio = 0.9, roughness = 0.5}),
    forestry = evidence({tree_ratio = 0.55, buildable_ratio = 0.65,
      humidity = 0.8, biome_family = "forest"}),
    mining = evidence({exposed_stone_ratio = 0.55, roughness = 5,
      biome_family = "rocky"}),
  }
  for expected, fixture in pairs(fixtures) do
    local ranked = perfectworld.settlements.evaluate_specializations(fixture)
    ctx.assert.equal(ranked[1].id, expected, expected .. " evidence must rank first")
    ctx.assert.is_true(ranked[1].viable, expected .. " must be viable")
  end
end)

T.register_test("perfectworld", "ecology_biome_alone_cannot_claim_a_specialization", function(ctx)
  local ranked = perfectworld.settlements.evaluate_specializations(
    evidence({buildable_ratio = 0.2, biome_family = "coastal"}))
  for _, result in ipairs(ranked) do
    ctx.assert.is_false(result.viable, result.id .. " must need physical evidence")
  end
end)
```

- [ ] **Step 2: Run the focused tests and verify red**

Run:

```bash
scripts/run-testkit.sh --keep
```

Expected: the new ecology tests fail to load because classification and
specialization APIs do not exist. Existing suites must still load.

- [ ] **Step 3: Add compatibility classifications and abstract decor materials**

Extend `pw_compat_mcl/init.lua` materials/fallbacks with `barrel`, `beehive`,
`hay`, `composter`, `furnace`, `smoker`, `anvil`, `grindstone`, `rail`,
`chain`, `campfire` and `cauldron`. All concrete names stay in this file.

Implement classification from registered-node groups:

```lua
function perfectworld.compat.classify_node(node_name)
  local def = minetest.registered_nodes[node_name]
  local groups = (def and def.groups) or {}
  local liquid = perfectworld.compat.is_liquid_node(node_name)
  local leaves = (groups.leaves or 0) > 0
  local tree = (groups.tree or groups.log or 0) > 0
    or node_name:find(":tree_", 1, true) ~= nil
  local flora = (groups.flora or groups.plant or 0) > 0
    or (def and def.buildable_to == true)
  local soil = perfectworld.compat.is_livable_ground(node_name)
  local stone = (groups.stone or 0) > 0
    or ((groups.cracky or 0) > 0 and not soil and not tree)
  return {
    liquid = liquid,
    vegetation = leaves or tree or flora,
    tree = tree,
    leaves = leaves,
    soil = soil,
    stone = stone,
    buildable_ground = soil and not liquid,
  }
end

function perfectworld.compat.is_natural_vegetation(node_name)
  return perfectworld.compat.classify_node(node_name).vegetation
end
```

- [ ] **Step 4: Implement immutable specialization definitions**

Load `specializations.lua` from `pw_settlements/init.lua` using its mod path.
The new file must define exact viability gates, score weights, resource
features, required roles and structure variants from the design:

```lua
local S = perfectworld.settlements
S.SPECIALIZATION_VERSION = 1

local definitions = {
  fishing = {
    required_role_counts = {dwelling = 2, fishery = 1},
    role_variants = {
      dwelling = {"pw_house_small_v1", "pw_house_small_v2",
        "pw_house_long_v1", "pw_house_tall_v1"},
      fishery = {"pw_fishery_v1"},
      storage = {"pw_barn_v1"},
      central = {"pw_well_v1"},
    },
    resource_features = {"fish", "smoking", "boatwork"},
    required_worksite = "dock",
  },
  farming = {
    required_role_counts = {dwelling = 2, farm = 1},
    role_variants = {farm = {"pw_farmstead_v1"}, barn = {"pw_barn_v1"}},
    resource_features = {"crops", "livestock", "hay"},
    required_worksite = "field",
  },
  forestry = {
    required_role_counts = {dwelling = 2, sawmill = 1},
    role_variants = {sawmill = {"pw_sawmill_v1"}, apiary = {"pw_sawmill_v1"},
      storage = {"pw_barn_v1"}},
    resource_features = {"lumber", "honey", "game", "hides"},
    required_worksite = "forestry_yard",
  },
  mining = {
    required_role_counts = {dwelling = 2, mine_workshop = 1},
    role_variants = {mine_workshop = {"pw_mine_workshop_v1"},
      storage = {"pw_barn_v1"}},
    resource_features = {"stone", "ore", "gems"},
    required_worksite = "minehead",
  },
}
```

Merge shared dwelling/central variants when returning a definition. Implement
`evaluate_specializations` with the exact gates and percentages from the spec,
clamp every score term to `[0,1]`, and sort by descending score then ID.

- [ ] **Step 5: Run focused tests and the existing pure village tests**

Run:

```bash
scripts/run-testkit.sh --keep
```

Expected: all classification/scoring tests pass and no previous suite regresses.

- [ ] **Step 6: Commit only Task 1 files**

```bash
git add -- \
  local_mods/perfectworld/pw_compat_mcl/init.lua \
  local_mods/perfectworld/pw_settlements/init.lua \
  local_mods/perfectworld/pw_settlements/specializations.lua \
  local_mods/perfectworld/pw_tests/init.lua \
  local_mods/perfectworld/pw_tests/mod.conf \
  local_mods/perfectworld/pw_tests/tests/ecology.lua
git commit -m "feat: classify village ecology and specializations"
git push origin master
```

### Task 2: Bounded ecological site selection

**Files:**
- Create: `local_mods/perfectworld/pw_planner/ecology.lua`
- Modify: `local_mods/perfectworld/pw_planner/init.lua`
- Modify: `local_mods/perfectworld/pw_planner/mod.conf`
- Modify: `local_mods/perfectworld/pw_tests/tests/ecology.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/village.lua`

**Interfaces:**
- Consumes: `perfectworld.settlements.evaluate_specializations(evidence)`
- Produces: `perfectworld.planner.ecology.enumerate_sites(candidate) -> 9 sites`
- Produces: `perfectworld.planner.ecology.survey_site(site, terrain, environment) -> evidence`
- Produces: `perfectworld.planner.ecology.select_site(candidate, terrain, environment_provider) -> selection|nil, reason`
- Extends terrain samplers with `sample_column(x,z) -> column`

- [ ] **Step 1: Add failing site-budget and selection tests**

Append:

```lua
T.register_test("perfectworld", "ecology_site_search_is_bounded_and_deterministic", function(ctx)
  local candidate = {id = "ecology_sites", x = 100, z = 200, rx = 0, rz = 0}
  local a = perfectworld.planner.ecology.enumerate_sites(candidate)
  local b = perfectworld.planner.ecology.enumerate_sites(candidate)
  ctx.assert.equal(#a, 9, "site search must have exactly nine sites")
  ctx.assert.equal(minetest.write_json(a), minetest.write_json(b),
    "site enumeration must be deterministic")
end)

T.register_test("perfectworld", "ecology_survey_reads_exactly_81_columns", function(ctx)
  local calls = 0
  local terrain = {
    sample_column = function()
      calls = calls + 1
      return {y = 32, buildable = true, soil = true, liquid = false,
        tree = false, stone = false}
    end,
  }
  perfectworld.planner.ecology.survey_site({id = "center", x = 0, z = 0},
    terrain, {biome_family = "temperate", humidity = 50})
  ctx.assert.equal(calls, 81, "one site must sample exactly 9x9 columns")
end)
```

Add fixtures in which `select_site` chooses a shore ring site over an invalid
center and never returns a point outside the candidate's region.

- [ ] **Step 2: Run TestKit and verify the selector tests fail**

Run `scripts/run-testkit.sh --keep`.

Expected: failures mention `perfectworld.planner.ecology`.

- [ ] **Step 3: Implement the shared column sampler**

In the real sampler, scan down through air and natural vegetation. Return:

```lua
{
  y = ground_y,
  node_name = ground_name,
  buildable = class.buildable_ground,
  soil = class.soil,
  liquid = class.liquid,
  tree = tree_seen,
  tree_count = tree_count,
  stone = class.stone,
}
```

Preserve `surface_y`, `is_liquid` and `is_livable` by delegating to
`sample_column`. Extend `make_synthetic_terrain(spec)` with the same method;
default synthetic ground is buildable soil, while optional callbacks
`spec.column_at(x,z)` and `spec.biome_at(x,z)` provide ecology fixtures.

- [ ] **Step 4: Implement nine-site enumeration and 81-column surveys**

`ecology.lua` returns a module table. Enumerate center plus a 40-node compass
ring, rotated by `choice.index(seed_key, "ecology:site_rotation", 8)`. Clamp
sites to the region margin. Survey offsets are exactly `-24,-18,...,24`.

Persist nearest valid `shore_anchor`, `shore_direction` and `stone_anchor` in
the winning evidence, because dock and minehead placement need physical
anchors rather than only ratios.

- [ ] **Step 5: Integrate selection into `plan_village`**

Add `SETTLEMENT_GRAMMAR_VERSION = 3`, include it in `village_seed_key`, and
select the physical site before profile/layout creation. Preserve the input
candidate as `regional_anchor`; build roads and lots around `selected_site`.

For no viable pair return a non-viable plan with:

```lua
{
  settlement_grammar_version = 3,
  village_id = candidate.id,
  center = {x = candidate.x, z = candidate.z},
  roads = {}, lots = {},
  rejections = {no_suitable_ecological_site = 1},
  viable = false,
}
```

- [ ] **Step 6: Run all PerfectWorld tests**

Run `scripts/run-testkit.sh --keep`.

Expected: deterministic profiles, fingerprints, bounds and new ecological tests
pass. Update assertions only where grammar v3 intentionally changes the plan;
do not weaken invariants.

- [ ] **Step 7: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_planner/ecology.lua \
  local_mods/perfectworld/pw_planner/init.lua \
  local_mods/perfectworld/pw_planner/mod.conf \
  local_mods/perfectworld/pw_tests/tests/ecology.lua \
  local_mods/perfectworld/pw_tests/tests/village.lua
git commit -m "feat: situate villages by local resources"
git push origin master
```

### Task 3: Specialization-aware village grammar

**Files:**
- Modify: `local_mods/perfectworld/pw_planner/init.lua`
- Modify: `local_mods/perfectworld/pw_settlements/specializations.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/ecology.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/village.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/fingerprints.lua`

**Interfaces:**
- Consumes: selected specialization definition and evidence.
- Produces: profile fields `specialization`, `required_role_counts`,
  `required_worksite`, `resource_features`, `role_variants`.
- Produces: generic `perfectworld.planner.missing_required_roles(plan_or_counts, requirements)`.

- [ ] **Step 1: Add failing grammar contract tests**

For each specialization, build a profile from explicit evidence and assert:

```lua
ctx.assert.equal(profile.specialization, expected, "selected specialization")
ctx.assert.equal(profile.required_role_counts.dwelling, 2, "two dwellings required")
ctx.assert.equal(profile.required_role_counts[production_role], 1,
  "one production role required")
ctx.assert.equal(profile.required_worksite, expected_worksite, "required worksite")
```

Build a plan and assert its fingerprint changes when only specialization
changes. Assert a plan missing its production role is not viable.

- [ ] **Step 2: Run tests and verify red**

Run `scripts/run-testkit.sh --keep`.

Expected: profile fields and generic requirements are absent.

- [ ] **Step 3: Replace universal roles with specialization grammar**

Build role arrays in required order:

```lua
local roles = {"dwelling", "dwelling", production_role}
```

Then append specialization optional roles until `target_lots` is reached using
stable labelled choices. Select structures only from `profile.role_variants`.
Unknown/missing variants reject the lot honestly.

Replace the hard-coded dwelling-only viability check with:

```lua
local missing = perfectworld.planner.missing_required_roles(
  role_counts, profile.required_role_counts)
plan.viable = #missing == 0
plan.missing_required_roles = missing
```

Include specialization, grammar version and ordered required counts in exact
and structural signatures.

- [ ] **Step 4: Make materialization completion generic**

Use the same helper against actually placed role counts. A record cannot be
`complete` if the production role failed even when two houses succeeded.
Persist `specialization`, `resource_features`, `regional_anchor`,
`selected_site`, ecology scores and `settlement_grammar_version`.

- [ ] **Step 5: Run all TestKit suites**

Run `scripts/run-testkit.sh --keep`.

Expected: all four grammar fixtures pass; prior dwelling and completion tests
remain strict and green.

- [ ] **Step 6: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_planner/init.lua \
  local_mods/perfectworld/pw_settlements/specializations.lua \
  local_mods/perfectworld/pw_tests/tests/ecology.lua \
  local_mods/perfectworld/pw_tests/tests/village.lua \
  local_mods/perfectworld/pw_tests/tests/fingerprints.lua
git commit -m "feat: compose villages around local work"
git push origin master
```

### Task 4: Exact shared road raster

**Files:**
- Create: `local_mods/perfectworld/pw_roads/geometry.lua`
- Create: `local_mods/perfectworld/pw_tests/tests/roads.lua`
- Modify: `local_mods/perfectworld/pw_roads/init.lua`
- Modify: `local_mods/perfectworld/pw_roads/mod.conf`
- Modify: `local_mods/perfectworld/pw_planner/init.lua`
- Modify: `local_mods/perfectworld/pw_planner/mod.conf`
- Modify: `local_mods/perfectworld/pw_bot_bridge/oracle_perception.lua`
- Modify: `local_mods/perfectworld/pw_bot_bridge/tests/unit_core.lua`
- Modify: `local_mods/perfectworld/pw_tests/init.lua`

**Interfaces:**
- Produces: `perfectworld.roads.cross_section(dx,dz,width) -> offsets`
- Produces: `perfectworld.roads.rasterize(path,width) -> sorted cells`
- Produces: `perfectworld.roads.cell_set(path,width) -> keyed cells`
- Produces: `perfectworld.roads.rasterize_record(road) -> cells`
- Produces: `perfectworld.roads.set_provider(provider)` for planner persistence.

- [ ] **Step 1: Add failing exact-width and direction tests**

Test horizontal, vertical and diagonal width 1/2/3 roads. For a straight
five-cell centerline assert counts are exactly 5, 10 and 15 away from endpoint
overlap. Assert width 2 never becomes width 3. Assert oracle cells equal the
public raster.

- [ ] **Step 2: Run focused/full tests and verify red**

Run `scripts/run-testkit.sh --keep`.

Expected: even widths and oracle square dilation fail.

- [ ] **Step 3: Make `pw_roads` independent of planner load order**

Change `pw_roads/mod.conf` to depend only on `pw_core`. Keep public reads/writes
backward compatible through a registered provider:

```lua
local provider
function perfectworld.roads.set_provider(value) provider = value end
function perfectworld.roads.save(road) return provider and provider.save(road) end
function perfectworld.roads.get(id) return provider and provider.get(id) or nil end
function perfectworld.roads.list_routes()
  return provider and provider.list() or {}
end
```

Make `pw_planner` depend on `pw_roads` and register its existing ModStorage
functions as the provider after those functions are defined.

- [ ] **Step 4: Implement exact raster geometry**

For width `n`, use `n` centered offsets:

```lua
local first = -(width - 1) / 2
for index = 0, width - 1 do
  local offset = first + index
  -- round the perpendicular displacement to a grid cell
end
```

Deduplicate cells by `x:z`, then sort by X and Z. Use this implementation in
planner collision checks, road bounds, actual road placement and persisted
road records (`cells`).

- [ ] **Step 5: Adapt oracle without changing v1 output**

Prefer `perfectworld.roads.rasterize_record`. For a new record with persisted
cells return those; for a legacy path/width derive them. Remove oracle's square
dilation. Do not add or remove protocol response fields.

- [ ] **Step 6: Run TestKit and smoke boundary checks**

Run:

```bash
scripts/run-testkit.sh --keep
bash scripts/smoke-test.sh
```

Expected: exact geometry tests, planner collision tests and all bridge v1 tests
pass.

- [ ] **Step 7: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_roads \
  local_mods/perfectworld/pw_planner/init.lua \
  local_mods/perfectworld/pw_planner/mod.conf \
  local_mods/perfectworld/pw_bot_bridge/oracle_perception.lua \
  local_mods/perfectworld/pw_bot_bridge/tests/unit_core.lua \
  local_mods/perfectworld/pw_tests/init.lua \
  local_mods/perfectworld/pw_tests/tests/roads.lua
git commit -m "fix: share exact road geometry across the world"
git push origin master
```

### Task 5: Specialized production buildings

**Files:**
- Create: `local_mods/perfectworld/pw_structures/village_specialized.lua`
- Modify: `local_mods/perfectworld/pw_structures/init.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/structures.lua`

**Interfaces:**
- Produces registered structures `pw_fishery_v1`, `pw_sawmill_v1`,
  `pw_mine_workshop_v1`.
- Consumes only abstract `perfectworld.compat.get_material` names.

- [ ] **Step 1: Add registration and physical placement tests**

Assert all three definitions exist, validate, advertise the expected category
and have a road connector. In isolated flat snapshot areas, place each at every
supported rotation and assert non-air nodes exist inside its bounds.

- [ ] **Step 2: Run tests and verify red**

Run `scripts/run-testkit.sh --keep`.

Expected: structures are not registered.

- [ ] **Step 3: Load a focused specialized-building registration file**

At the bottom of `pw_structures/init.lua`, after `register_building` is
available:

```lua
local register_specialized = dofile(
  minetest.get_modpath("pw_structures") .. "/village_specialized.lua")
register_specialized({register_building = register_building})
```

The new file returns that registration function. Register visually distinct
buildings:

- fishery: wide storage building with smoker, barrels, cauldron and lantern;
- sawmill: open-sided timber work shed with logs, planks, campfire and barrel;
- mine workshop: stone-based workshop with furnace, anvil, grindstone and
  lantern.

Every optional material is skipped when unavailable; building shells still
materialize.

- [ ] **Step 4: Run structure and full TestKit suites**

Run `scripts/run-testkit.sh --keep`.

Expected: all rotations place and roll back correctly, and grammar no longer
rejects unknown production structures.

- [ ] **Step 5: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_structures/init.lua \
  local_mods/perfectworld/pw_structures/village_specialized.lua \
  local_mods/perfectworld/pw_tests/tests/structures.lua
git commit -m "feat: build village production workshops"
git push origin master
```

### Task 6: Transactional specialization worksites

**Files:**
- Create: `local_mods/perfectworld/pw_planner/worksites.lua`
- Create: `local_mods/perfectworld/pw_tests/tests/worksites.lua`
- Modify: `local_mods/perfectworld/pw_planner/init.lua`
- Modify: `local_mods/perfectworld/pw_tests/init.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/village_diversity.lua`

**Interfaces:**
- Produces: `perfectworld.planner.worksites.place(kind, context) -> ok, record|error`
- Produces: `perfectworld.planner.worksites.transaction(bounds, mutator) -> ok, result`
- Worksite record: `{id, kind, required, anchor, bounds, node_count, status}`.

- [ ] **Step 1: Add failing rollback, protection and collision tests**

Create isolated snapshot areas and assert:

- a mutator that changes one node then raises restores the original node and
  `param2`;
- a protected position prevents every mutation;
- a field avoids exact road cells and building footprints;
- a dock requires a valid `shore_anchor`;
- a minehead requires a valid `stone_anchor`;
- repeat placement returns the existing worksite record without duplication.

- [ ] **Step 2: Run tests and verify red**

Run `scripts/run-testkit.sh --keep`.

Expected: worksite module is absent.

- [ ] **Step 3: Implement the bounded transaction**

Snapshot every node and `param2` in exact bounds, reject protection before the
first write, run the mutator in `pcall`, and restore in reverse order on false
or error. Reject volumes larger than the maximum needed by the four fixed
features.

- [ ] **Step 4: Implement four required worksites**

- `field`: 9x7 fenced field, tilled soil, palette crop, water cell and
  composter;
- `dock`: shore-direction walkway, bounded piles, barrels, drying frames and
  lantern;
- `forestry_yard`: log stacks, plank work bed, beehives and a bounded drying
  frame;
- `minehead`: five-node shallow adit or quarry face, support timbers, closed
  back, rail, furnace/ore yard.

Every placement uses abstract compatibility materials. Every candidate cell is
rejected if it belongs to a structure or `pw_roads.cell_set`.

- [ ] **Step 5: Integrate worksite materialization and records**

After roads and approaches, place the required worksite from
`profile.required_worksite`. Persist `worksite_ids`, `worksite_kinds`,
`worksites`, and optional warnings. Extend actual settlement bounds.

Required failure adds a settlement error and prevents `complete`; optional
decor failure adds only a warning. Remove the old universal `build_yard`
Mineclonia-name logic after equivalent decor is covered.

- [ ] **Step 6: Extend physical validation**

`validate_settlement` must check that every required worksite record has at
least one expected non-air node inside its recorded bounds and does not overlap
the exact road raster/buildings. Validation reads the real world, not only
ModStorage.

- [ ] **Step 7: Run full TestKit**

Run `scripts/run-testkit.sh --keep`.

Expected: all rollback/protection/physical validation tests pass; no settlement
can be complete without its required physical worksite.

- [ ] **Step 8: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_planner/init.lua \
  local_mods/perfectworld/pw_planner/worksites.lua \
  local_mods/perfectworld/pw_tests/init.lua \
  local_mods/perfectworld/pw_tests/tests/worksites.lua \
  local_mods/perfectworld/pw_tests/tests/village_diversity.lua
git commit -m "feat: materialize village work sites safely"
git push origin master
```

### Task 7: Normalized persistence and oracle compatibility

**Files:**
- Modify: `local_mods/perfectworld/pw_settlements/init.lua`
- Modify: `local_mods/perfectworld/pw_planner/init.lua`
- Modify: `local_mods/perfectworld/pw_bot_bridge/oracle_perception.lua`
- Modify: `local_mods/perfectworld/pw_bot_bridge/tests/integration.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/ecology.lua`
- Modify: `local_mods/perfectworld/pw_tests/tests/village_diversity.lua`

**Interfaces:**
- Produces: `perfectworld.settlements.normalize(data) -> normalized record|nil`
- Produces: actual persisted entrances on structure records.
- Preserves every `pw_bot_bridge/v1` response key and type.

- [ ] **Step 1: Add legacy/new normalization tests**

Use one legacy `{plan,profile,settlement}` fixture and one grammar-v3 fixture.
Assert both normalize with actual `center_pos` and actual settlement `bounds`;
legacy gets grammar version 2 and empty ecology/worksite arrays.

In bridge integration, seed both records and assert `get_settlement` uses actual
bounds/center while its response schema remains unchanged.

- [ ] **Step 2: Run tests and verify the actual-vs-plan bug**

Run `scripts/run-testkit.sh --keep`.

Expected: legacy normalization API is absent and oracle reports plan bounds.

- [ ] **Step 3: Implement defensive normalization**

Return deep copies. Prefer actual `settlement.center_pos` and
`settlement.bounds`, retain plan lots separately, and synthesize only missing
legacy defaults. Never expose internal ecology fields through player mode.

- [ ] **Step 4: Persist actual structure entrances**

When a structure materializes, store its actual door/entrance position in the
structure record. Oracle uses persisted entrances first, then legacy plan lot,
then current definition connector. This prevents definition changes from
inventing entrances for old structures.

- [ ] **Step 5: Switch oracle facades**

Use `pw_settlements` for settlement records, `pw_roads` for road records and
their exact raster, and planner fallback only for legacy plan/lot detail.
Return explicit unavailable data internally if a provider is absent rather
than treating missing providers as an empty world. Keep v1 output canonical.

- [ ] **Step 6: Run bridge and full TestKit plus smoke checks**

Run:

```bash
scripts/run-testkit.sh --keep
bash scripts/smoke-test.sh
```

Expected: bridge player/oracle suites and all PerfectWorld suites pass.

- [ ] **Step 7: Commit and push**

```bash
git add -- \
  local_mods/perfectworld/pw_settlements/init.lua \
  local_mods/perfectworld/pw_planner/init.lua \
  local_mods/perfectworld/pw_bot_bridge/oracle_perception.lua \
  local_mods/perfectworld/pw_bot_bridge/tests/integration.lua \
  local_mods/perfectworld/pw_tests/tests/ecology.lua \
  local_mods/perfectworld/pw_tests/tests/village_diversity.lua
git commit -m "fix: expose actual village records to oracle diagnostics"
git push origin master
```

### Task 8: Documentation, exhaustive verification and visible acceptance

**Files:**
- Modify: `docs/status.md`
- Modify: `docs/perfectworld-architecture.md`
- Modify: `docs/player-guide.md`
- Modify only if a verified defect requires it: files already owned by Tasks
  1-7; never dirty bot-runtime or `pw_debug` files.

**Interfaces:**
- Produces user-facing documentation for specialization meanings and limits.
- Produces automated reports and a visible four-specialization acceptance log.

- [ ] **Step 1: Update documentation from actual behavior**

Document grammar v3, nine-site bounded search, four specializations, required
physical features, legacy behavior and the absence of NPC/economic simulation.
Update the status baseline only after the final report exists.

- [ ] **Step 2: Run static and syntax gates**

```bash
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
git diff --check
docker run --rm --entrypoint luajit \
  -v "$PWD/local_mods:/m" perfectworld-luanti \
  -e "for _,p in ipairs({
    '/m/perfectworld/pw_planner/init.lua',
    '/m/perfectworld/pw_planner/ecology.lua',
    '/m/perfectworld/pw_planner/worksites.lua',
    '/m/perfectworld/pw_roads/init.lua',
    '/m/perfectworld/pw_structures/init.lua'
  }) do local f,e=loadfile(p); assert(f,e) end; print('OK')"
bash scripts/smoke-test.sh
```

Expected: every command exits 0 and Lua prints `OK`.

- [ ] **Step 3: Run a clean full server/client TestKit cycle**

```bash
scripts/run-testkit.sh
python3 scripts/report-summary.py "$(ls -t data/worlds/perfectworld/ltk_report_*.json | head -1)"
```

Expected: all tests PASS, with zero FAIL, SKIP and ERROR. Inspect the report
path printed by the summary.

- [ ] **Step 4: Inspect logs**

```bash
rg -n "ERROR|FATAL|ModError|LuaError|AsyncErr|stack traceback" \
  data/debug-test.txt logs/test-client.log
```

Expected: no new PerfectWorld errors. Classify known intentional test messages
explicitly rather than ignoring them.

- [ ] **Step 5: Start the real runtime in visible mode**

From the user's graphical session:

```bash
scripts/run-pw-bot-visible.sh --config runtime/pwbot.toml --keep-open
```

Expected: doctor checks pass, a Xephyr/mirror window opens, the real `pwbot`
client joins, and the runtime reports `display.mode=visible`.

- [ ] **Step 6: Materialize and visit four real settlements**

Use existing server/debug commands without editing `pw_debug`:

```text
/pw_village_batch 40
/pw_village_list
/pw_village_validate_all
```

Select one complete record of each specialization from the exported/listed
records. For each ID, enter `/pw_village_tp <id>` through the visible real
client and keep the window open long enough to inspect the production building,
required worksite, street connection and surrounding ecology.

Record for each specialization: settlement ID, biome, score, required structure,
required worksite, validation status and observed visual defects. If the real
map does not yield all four within 40 candidates, generate another bounded batch
rather than relabelling a mismatched village.

- [ ] **Step 7: Fix only defects that violate this spec and repeat gates**

For every observed blocker, first add a focused failing test, apply the smallest
fix in a Task 1-7 owned file, rerun focused tests, then rerun full TestKit and
the visible visit. Do not change bot code to make the tour pass.

- [ ] **Step 8: Commit docs/final verified fixes and push**

```bash
git add -- docs/status.md docs/perfectworld-architecture.md docs/player-guide.md
git commit -m "docs: describe ecologically situated villages"
git push origin master
```

- [ ] **Step 9: Completion audit**

Verify current source, TestKit report, server/client logs, four visible visit
records, `git status`, `git log origin/master..HEAD` and remote branch state.
For every design requirement identify direct evidence. The dirty files listed
before this work must remain dirty but unstaged and byte-unmodified by these
commits.
