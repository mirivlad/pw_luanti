# Player Guide

PerfectWorld generates physical structures in the Mineclonia world. This guide
covers what you can see and do in the current experimental version.

## What Exists

When you explore new terrain, PerfectWorld places structures through mapgen:

- **Farms** (`pw_farmstead_v1`): walled farmsteads with garden and road connector
- **Houses** (`pw_house_small_v1`, `pw_house_small_v2`): compact residential buildings
- **Barns** (`pw_barn_v1`): storage buildings
- **Wells** (`pw_well_v1`): open wells with cobble pillars
- **Villages**: main street with houses, barn, well, farm, and connecting road

Structures appear as you explore new areas. Generation is deterministic — the
same seed produces the same world.

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
| `/pw_village_info [id]` | Show detailed settlement info (archetype, fingerprint, lots) |
| `/pw_village_tp <id>` | Teleport to a settlement center (requires teleport priv)
| `/pw_demo` | Show demo village+farm coordinates |

### Development (server privilege)

| Command | Description |
|---------|-------------|
| `/pw_materialize <rx> <rz> <idx> [force]` | Force-materialize a planned structure |
| `/pw_prepare_shot [player] <structure_id>` | Teleport near a structure |
| `/pw_photo_setup` | Setup screenshot scene |
| `/pw_photo_village` | Force-materialize demo village |
| `/pw_photo_structure <name>` | Force-materialize a structure |
| `/pw_photo_camera <x> <y> <z>` | Position camera |
| `/pw_photo_shoot <farm\|village\|road>` | Automated screenshot pipeline |
| `/pw_run_tests` | Run all PerfectWorld tests |

## Finding Generated Structures

New structures appear as you explore ungenerated terrain. Walk in any direction
for several hundred blocks. Use `/pw_region` to see your current region, and
`/pw_plan` to check if your region has settlement candidates.

To force-generate a structure for testing:

```
/pw_materialize -2 0 1 force
```

Then teleport to the demo area:

```
/pw_demo
```

## What's Missing

- NPCs and villagers
- Economy and trading
- Roads between settlements (only village-to-farm local roads exist)
- Bridges and tunnels
- Global route network
- Building interiors beyond minimal (light, table, container)
- Save migration between versions
