# Player Guide

PerfectWorld generates physical structures in the Mineclonia world. This guide
covers what you can see and do in the current experimental version.

## What Exists

When you explore new terrain, PerfectWorld places structures through mapgen:

- **Farms** (`pw_farmstead_v1`): walled farmsteads with garden and road connector
- **Houses** (`pw_house_small_v1`, `pw_house_small_v2`): compact residential buildings
- **Barns** (`pw_barn_v1`): storage buildings
- **Wells** (`pw_well_v1`): open wells with cobble pillars
- **Fisheries** (`pw_fishery_v1`): shore workshops with fish-smoking and
  boatwork details
- **Sawmills** (`pw_sawmill_v1`): timber workshops for forest settlements
- **Mine workshops** (`pw_mine_workshop_v1`): stone-and-metal workshops beside
  exposed rock
- **Villages**: a street network whose homes, production building and physical
  work area reflect the resources at its selected site

Villages come in three shapes:

| Archetype | Where it appears | What it looks like |
|-----------|------------------|--------------------|
| `linear` | Valleys, shores, narrow ground | One street with buildings down both sides |
| `compact` | Open flat ground | A crossroads with side branches and a central well |
| `hillside` | Slopes and rough ground | A street that follows the contour, buildings terraced into the hill |

Their primary specialization comes from measured local terrain, not a random
label:

| Specialization | Required evidence | Required physical features |
|----------------|-------------------|----------------------------|
| `fishing` | A buildable shore close to open or frozen water | Fishery and a dock |
| `farming` | Mostly soil, buildable ground and gentle relief | Farmstead and a fenced 9x7 field |
| `forestry` | Sufficient nearby trunks/canopy and buildable ground | Sawmill and a lumber/apiary yard |
| `mining` | Exposed stone or rocky relief with usable ground | Mine workshop and a shallow supported minehead |

For each regional village candidate, grammar v3 surveys exactly nine bounded
possible sites after the area has emerged. Each site samples no more than 81
columns. The highest-scoring viable site/specialization pair wins; if none is
viable, the planner records an honest failure and builds nothing.

Buildings are made of local materials: sandstone in deserts, stone in the
mountains, wood and cobble in temperate and forested land, gravel paths in the
cold north, sand paths on the coast.

Structures appear as you explore new areas. Generation is deterministic — the
same seed produces the same world, and revisiting an area never duplicates
anything.

## Commands

All commands require at least `interact` privilege. Some require `server`.

### Information

| Command | Description |
|---------|-------------|
| `/pw_status` | Show PerfectWorld version and configuration |
| `/pw_region` | Show your current region |
| `/pw_plan [rx] [rz]` | Show the plan for a region |
| `/pw_structure <id>` | Show a materialized structure record |
| `/pw_village_list` | List all generated village settlements |
| `/pw_village_info [id]` | Full settlement info; with no id, the nearest settlement |
| `/pw_village_tp <id>` | Teleport to a settlement center (requires teleport priv) |
| `/pw_village_validate [id]` | Check a settlement against its record and the real world |
| `/pw_village_validate_all` | Validate every settlement and list the failures |
| `/pw_demo` | Show demo village+farm coordinates |

### Development (server privilege)

| Command | Description |
|---------|-------------|
| `/pw_materialize <rx> <rz> <idx> [force]` | Force-materialize a planned structure |
| `/pw_prepare_shot [player] <structure_id>` | Teleport near a structure |
| `/pw_photo_setup` | Setup screenshot scene |
| `/pw_photo_village` | Force-materialize demo village |
| `/pw_photo_structure <name>` | Force-materialize a structure |
| `/pw_photo_camera <x> <y> <z>` | Position camera automatically |
| `/pw_photo_at <x> <y> <z> <tx> <ty> <tz>` | Exact camera position and aim point |
| `/pw_photo_shoot <farm\|village\|road>` | Automated screenshot pipeline |
| `/pw_village_batch [count] [radius]` | Materialize planned villages across biome families |
| `/pw_village_analyze [synthetic\|world] [count]` | Write a generator diversity report |
| `/pw_village_export` | Write all settlement records and validation reports |
| `/pw_village_shotlist` | Write camera setups and metadata for screenshots |
| `/pw_run_tests` | Run all PerfectWorld tests |

## Finding Generated Structures

New structures appear as you explore ungenerated terrain. Walk in any direction
for several hundred blocks. Use `/pw_region` to see your current region, and
`/pw_plan` to check if your region has settlement candidates.

Villages are larger than a single mapgen chunk, so they are queued: the site is
generated first and the village is built a moment later. Walking into a region
with a village candidate is enough to trigger it.

To force-generate villages for testing:

```
/pw_village_batch 12
```

Then list and visit them:

```
/pw_village_list
/pw_village_tp <settlement_id>
```

To force-generate a single planned structure:

```
/pw_materialize -2 0 1 force
```

## Reading a Settlement

`/pw_village_info` reports the settlement's biome and family, its material
palette, archetype, size class and specialization, how many lots were planned
versus built, the roles and worksite present, and three fingerprints:

- **exact plan fingerprint** — changes if anything moves by even one block;
- **structural fingerprint** — shared by plans that look alike;
- **road graph fingerprint** — the street network alone, independent of where in
  the world it stands.

A grammar-v3 settlement is `complete` only when every planned lot was built
without errors, at least two dwellings exist, its specialization-specific
production building and required worksite were materialized, and every door is
reachable from the street. Otherwise it is `partial`, or `failed` if nothing
could be built.

Worksites are bounded transactions: the planner checks protection and loaded
nodes before changing anything, and restores node names and rotation data if a
placement fails. Fields, docks, yards and mineheads are kept out of exact road
cells and building footprints.

Already materialized villages are not moved or rebuilt when grammar v3 is
installed. Their legacy records remain readable and normalize as grammar
version 2.

## What's Missing

- NPCs and villagers
- Production simulation, inventories, economy and trading
- Roads between settlements (only local village streets and driveways exist)
- Bridges and tunnels
- Global route network
- Building interiors beyond minimal (light, table, container)
- Save migration between versions
