# PerfectWorld

PerfectWorld is a Luanti modpack for the physical shape of the world. It owns
regions, settlements, buildings, roads, farms and the people who live in them.

## Modules

| Module | Responsibility |
| --- | --- |
| `pw_core` | Shared `perfectworld` API, settings, world seed handling, composite IDs, world format lock, and the hashed-choice contract every decision is made with |
| `pw_compat_mcl` | Mineclonia node and material compatibility: seven biome families, per-family palettes, workstations, abstract decor roles |
| `pw_planner` | Region planning, the village grammar, the bounded ecological survey, road paving and materialization |
| `pw_structures` | Structure registry, terrain preparation, rotation, placement and rollback |
| `pw_schemes` | 68 declarative building schemes in six styles, five roof kinds, interiors by role |
| `pw_roads` | The exact road raster, and the network that joins one settlement to the next |
| `pw_settlements` | Settlement types, physical specializations, the trades each supports, and place names |
| `pw_population` | The people: ordinary Mineclonia villagers, one per bed standing in the world |
| `pw_bot_bridge` | Server-side perception API for an automated player |
| `pw_player_bot` | That player's decision layer: memory, beliefs, needs, goals, intents |
| `pw_debug` | `/pw_*` chat commands: reports, diagnostics, batch builds, screenshots |
| `pw_tests` | Luanti TestKit coverage for PerfectWorld |

## Buildings

Two catalogues, and they are not the same kind of thing.

**`pw_structures`** holds ten buildings written as Lua generators, for the roles
that carry contracts a scheme cannot yet express: `pw_farmstead_v1`,
`pw_house_small_v1`, `pw_house_small_v2`, `pw_house_long_v1`,
`pw_house_tall_v1`, `pw_barn_v1`, `pw_well_v1`, and the three production
buildings `pw_fishery_v1`, `pw_sawmill_v1` and `pw_mine_workshop_v1`.

**`pw_schemes`** holds 68 buildings written as data. A scheme names its
footprint, wall height, roof kind, door side, interior fixtures by role, and the
village roles it can fill. A style adds shared proportions and any material it
pins outright. One builder reads both; no scheme carries code.

| Style | Belongs in | What carries it |
| --- | --- | --- |
| `vernacular` | anywhere (fallback) | 45° gables, timber posts, stone plinth, local wood |
| `nordic` | cold, rocky | shallow turf roofs, longhouses, few small windows |
| `japanese` | temperate, forest, wet | raised floors, verandas, eaves two nodes past the wall |
| `mediterranean` | dry, rocky | flat terraced roofs with parapets, pale stone cubes |
| `stilt` | wet, coastal | everything on posts over open water, light roofs |
| `urban` | any town | two to four storeys, stone below and timber above |

A settlement picks **one** style, hashed from its own id and constrained by
biome family, and builds only from it. `urban` is the exception: it is a size of
building rather than a place's way of building, so a town draws on it whatever
style the region otherwise gave it.

## Village Layout

Villages produce a deterministic layout:

1. A bounded ecological survey of nine sites picks where the settlement stands
   and what it lives on — fishing, farming, forestry or mining — from measured
   water, soil, trees and stone
2. A street network sized from the buildings meant to stand on it, with side
   lanes for larger settlements
3. Lots along the streets, each rejected against slope, water, barren ground and
   its neighbours
4. Doors face the street, and every one is checked with the engine's pathfinder
   from the carriageway, on foot
5. A required production building and a transactional worksite — a dock, a
   field, a forestry yard or a minehead
6. A bell, and a signpost at every way in

Towns add a wall with a gate where each road arrives, guards on the gates, and
fields outside the wall.

## Commands

Reports and diagnostics:

```text
/pw_status /pw_region /pw_plan [rx] [rz] /pw_structure <id>
/pw_settlement_density [radius]
/pw_village_list /pw_village_info [id] /pw_village_failures
/pw_population [id] /pw_road_network [radius]
/pw_road_check [range] /pw_street_check [id]
```

Building and maintenance (server priv):

```text
/pw_materialize <rx> <rz> <index> [force]
/pw_village_batch [count] [radius]
/pw_village_rematerialize
/pw_roads_pave [chunk_radius]
/pw_populate [id] [force]
/pw_village_analyze [synthetic|world] [count]
```

## Current Behaviour

- Region size defaults to `1024`. A region holds on average 1.8 settlements
- Every decision is an independent labelled hash of the seed — there is no PRNG
  stream anywhere, so a decision can be reproduced without replaying the ones
  before it
- Candidate IDs are composite and readable: `settlement_v1_n2_p3_0`; structure
  IDs embed the settlement, `structure_v1_settlement_v1_n2_p3_0_0`
- Records are sharded by the region their id names, so writing one barn rewrites
  one region rather than the world
- PerfectWorld writes a ModStorage world format lock. Incompatible values
  disable new materialization instead of silently writing a different plan into
  an existing world
- Settlements are joined by roads planned as a Gabriel graph and paved per
  mapchunk, with tunnels, embankments, bridges and landings

## Limitations

- Nothing changes after generation. There is no economy and no clock: every
  `globalstep` in the modpack belongs to the bot
- Roads carry nobody. There are no caravans
- A road that meets the sea gets a landing stage, not a port town
- Cities are a declared type that region planning never produces
- No global route pathfinding over the settlement network
- No save migration between planner versions
