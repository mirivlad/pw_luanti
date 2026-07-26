# PerfectWorld Village Settlements — Verified Materializations

## Settlement 1: Region (0,0) — Temperate Flat

| Field | Value |
|-------|-------|
| Settlement ID | `settlement_v1_p0_p0_0` |
| Region | rx=0, rz=0 |
| Center | ~(500, 0, 500) (deterministic, exact pos varies by seed) |
| Biome Family | temperate (default Mineclonia spawn biome) |
| Archetype | compact |
| Fingerprint | 764596070 |
| Status | complete |
| Lot count | varies (deterministic) |
| Teleport | `/pw_village_tp settlement_v1_p0_p0_0` |

Materialized via: `/pw_materialize 0 0 0 force`

## Settlement 2: Region (0,6) — Test Materialization

| Field | Value |
|-------|-------|
| Settlement ID | `settlement_v1_p0_p6_0` |
| Region | rx=0, rz=6 |
| Center | ~(500, 0, 6500) |
| Biome Family | temperate |
| Archetype | varies (deterministic per seed) |
| Status | complete (test cleanup removes after pass) |
| Verified by | `materialize_chunk_handles_village_candidate` test |

## Commands

```text
/pw_village_list              — list all settlements
/pw_village_info <id>         — detailed info
/pw_village_tp <id>           — teleport to settlement
/pw_materialize <rx> <rz> 0 force  — force-materialize candidate
```

## Notes

- Settlement records are persisted in mod_storage under `pw_settlement_plans`
- Each settlement stores: archetype, fingerprint, structure IDs, road IDs, environment profile
- Restarting the server preserves all records
- Repeated materialization is idempotent (no duplicates)
