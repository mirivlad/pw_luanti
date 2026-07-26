# PerfectWorld

PerfectWorld is a Luanti modpack for the physical shape of the world. It owns
regions, settlement candidates, buildings, roads, farms, and later population
and transport.

## Modules

| Module | Responsibility |
| --- | --- |
| `pw_core` | Shared `perfectworld` API, settings, world seed handling, composite IDs, world format lock |
| `pw_planner` | Deterministic regional logical plans, settlement/road persistence |
| `pw_structures` | Structure registry, terrain preparation, rotation, and placement API |
| `pw_village` | Village layout planner: plots, street, building assignment |
| `pw_roads` | Road network API skeleton |
| `pw_settlements` | Settlement type definitions |
| `pw_population` | Population API skeleton |
| `pw_debug` | `/pw_*` debug chat commands |
| `pw_compat_mcl` | Mineclonia node/material compatibility |
| `pw_tests` | Luanti TestKit coverage for PerfectWorld |

## Registered Structures

| Structure | Type | Size | Description |
| --- | --- | --- | --- |
| `pw_farmstead_v1` | farm | 15x7x14 | Farmstead with walls, roof, garden, road connector |
| `pw_house_small_v1` | residential | 7x5x5 | Compact house, low roof, 1 window |
| `pw_house_small_v2` | residential | 9x6x5 | Wider house, higher walls, 2 windows |
| `pw_barn_v1` | farmyard | 9x6x7 | Storage building, no windows, large door |
| `pw_well_v1` | public | 3x4x3 | Open well with cobble pillars and water |

## Village Layout

Villages (settlement type `"village"`) produce a deterministic layout:

1. Main street (40-80 nodes, 2-3 wide) through the settlement center
2. 4-7 plots on both sides of the street
3. Building assignment: 2-4 houses, 0-1 barn, 1 public point (well)
4. Doors face the street
5. Short path from each plot to the street

Layout is deterministic from settlement ID + region coordinates.

## Commands

```text
/pw_status
/pw_region
/pw_plan
/pw_plan <rx> <rz>
/pw_structure <structure_id>
/pw_prepare_shot [player] <structure_id>
/pw_materialize <rx> <rz> <index> [force]
/pw_demo
```

## Current Behavior

- Region size defaults to `1024`.
- Each region gets a deterministic plan from world seed, region coordinates,
  planner version, and configuration.
- A region may contain 0 to 2 settlement candidates.
- Candidate IDs are composite and readable, for example
  `settlement_v1_n2_p3_0`; structure IDs use the settlement ID plus a local
  index, for example `structure_v1_settlement_v1_n2_p3_0_0`.
- PerfectWorld writes a ModStorage world format lock with
  `world_format_version`, `planner_version`, `region_size`, and
  `world_seed_fingerprint`. Incompatible values disable new materialization
  instead of silently writing a different plan into an existing world.
- Villages, farms, and roads are materialized through `pw_planner.materialize_chunk`
  and `pw_planner.materialize_region_candidate`.
- Materialized structures are recorded separately in ModStorage by structure ID.
- `pw_farmstead_v1` uses a simple deterministic terrace strategy.
- Village street and building placement use the same terrain preparation pipeline.

## Limitations

- No real villages, towns, farms, or economy yet.
- Roads between settlements are simple straight lines with height correction.
- Bridges are not implemented; roads may fail on steep terrain.
- Population is a skeleton only.
- No global route pathfinding exists yet.
- Terrain adaptation is a flat terrace, not a slope-following building system.
- Building interiors are minimal (light, table, container).
