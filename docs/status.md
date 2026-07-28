# Project Status

**Date:** 2026-07-29
**Test baseline:** 359 total | 357 PASS | 2 FAIL | 0 SKIP | 0 ERROR

The two failures are the long-standing `external_transport` configuration
contradiction: two `pw_bot_bridge` tests require the setting to be off by
default, while `config/luanti.conf` turns it on so `pw_bot_runtime` can reach
the spool.

Measured on `master` after roads between settlements, larger settlements and
population.

## Implemented Modules

| Module | Status | Notes |
|--------|--------|-------|
| `pw_core` | ✅ Complete | API, composite IDs, world format lock, exact 32-bit hashing, stable variation contract |
| `pw_compat_mcl` | ✅ Complete | Material mappings, biome and ecological node classification, 7 families, environment profiles, palettes and abstract decor materials |
| `pw_planner` | ✅ Implemented | Region planning, grammar v3, bounded ecological survey, 3 archetypes, exact local roads with a shared walkable height profile, transactional worksites, real-world validation and sharded persistence |
| `pw_structures` | ✅ Complete | 10 registered structures, including fishery, sawmill and mine workshop; palette-aware placement, bounded terrain prep and rollback |
| `pw_roads` | ✅ Implemented | Shared exact-width raster, persistence facade, canonical road cells, and the Gabriel-graph network joining settlement to settlement |
| `pw_settlements` | ✅ Implemented | Four specialization definitions, scoring and normalized legacy/current settlement records |
| `pw_debug` | ✅ Complete | 27 chat commands including validation, batch build, diversity analysis, road network report and readback, population report, screenshot support |
| `pw_bot_bridge` | ✅ Implemented | Server-side perception: `player`/`oracle` modes, stable `pw_bot_bridge/v1`, normalized oracle settlement records, semantic registry and bounded transport; player-mode contract unchanged |
| `pw_player_bot` | ✅ Complete | Bounded memory, beliefs, navigation over remembered ground, needs, goals and `pw_player_bot/v1`. Movement is judged over elapsed time, so thinking faster than the world moves is not mistaken for being stuck. Decides only — never acts |
| `pw_schemes` | ✅ Implemented | 61 declarative building schemes across five architectural styles, five roof kinds, interiors by role, deterministic per-settlement style choice |
| `pw_tests` | ✅ Complete | PerfectWorld tests across core, store, schemes, planner, structures, ecology, worksites, roads, road network, population, variation, fingerprints, village and diversity |
| `luanti_testkit` | ✅ Complete | Universal test framework |
| `pw_remote_control` | ✅ Complete | JSON remote control |

| `pw_population` | ✅ Implemented | Ordinary Mineclonia villagers, one per bed standing in the world, moved in when the settlement is built |

No skeleton modules remain.

## Building Schemes (`pw_schemes`)

Buildings are data now, not generators. 61 schemes across five styles, where
there were 10 buildings and no styles at all.

| Style | Belongs in | What carries it |
|-------|-----------|-----------------|
| `vernacular` | anywhere (fallback) | 45° gables, timber posts, stone plinth, local wood |
| `nordic` | cold, rocky | pitch 2 turf roofs, longhouses, few small windows |
| `japanese` | temperate, forest, wet | raised floors, verandas, eaves two nodes past the wall |
| `mediterranean` | dry, rocky | flat terraced roofs with parapets, pale stone cubes |
| `stilt` | wet, coastal | everything on posts over open water, light roofs |

The families are the seven `pw_compat_mcl` reports: cold, coastal, dry, forest,
rocky, temperate, wet. Four styles originally named invented ones — taiga,
jungle, desert and so on — which matched nothing, so only the fallback was ever
chosen and every village in the world came out vernacular. A test now rejects a
style naming a family the game does not have, and another requires every family
to offer something beyond the fallback.

A scheme names its footprint, wall height, roof kind, door side, interior
fixtures by role, and the village roles it can fill. A style adds shared
proportions and any material it pins outright. One builder reads both; no scheme
carries code. Materials resolve style-first, then through the biome palette, so
a vernacular village is made of its own forest while a Japanese roof stays tile
wherever it stands.

A settlement picks **one** style, hashed from its own id and constrained by
biome family, and builds only from it. Mixing styles inside a village would read
as a sample book rather than a place.

Roof kinds: `gable`, `hip`, `pent`, `flat`, `wide_eaved_gable`. All of them place
stairs rising towards the ridge — the shared builder means one wrong direction
would be wrong in every style at once, so a test asserts it.

Wired into the planner. Each scheme registers as an ordinary `pw_structures`
definition whose generator calls the scheme builder, so terrain analysis,
rotation, the plinth, rollback and the reachability check all apply unchanged. A
village picks one style and every lot draws from it.

Roles taken from the catalogue: `dwelling`, `storage`, `barn`. Left with the
pre-catalogue structures: `central` (the well) and the specialization production
buildings (`farm`, `fishery`, `sawmill`, `mine_workshop`), because those carry
worksite contracts the scheme vocabulary does not yet express.

Verified in the world rather than only in the plan, with
`scripts/pw-village-check.sh`: a radius-9 batch produced 26 new structures, 15
from the catalogue, japanese and stilt villages both appearing, and no
settlement mixing two styles.

## Roads Between Settlements

Villages had streets; the countryside between them had nothing. It now carries a
road network, planned from the road anchors regions already produce.

**Which settlements are joined** is a Gabriel graph: a and b are neighbours when
no third settlement lies inside the circle on diameter ab — "there is nothing
between them". The property that made it the right choice is that deciding one
edge only ever needs the anchors near that edge, so two regions sharing a border
reach the same answer without talking to each other. Joining everything within
range gives a cobweb; joining each anchor to its k nearest is not even
symmetric. The inside test is exact in integers, `(a-c)·(b-c) < 0`, so there is
no epsilon for the two sides to disagree about. Nearest-neighbour pairs are
always Gabriel edges, so nothing within range is stranded.

Three classes, by the smaller of the two places served: `highway` (gravel, three
wide), `road` (coarse dirt, two) and `track` (grass path, one). A track to a
lone farm does not become a highway because the other end is a village.

**Paving happens per mapchunk.** The far end of a link is usually hundreds of
nodes away in terrain nobody has generated, and `set_node` into an unloaded
block writes nothing at all. Each chunk lays the stretch crossing it, with an
overlap so neighbouring passes meet rather than butt together, and the road
grows to meet itself whichever end was built first.

**One height profile per stretch, not per segment.** Paving segment by segment
let the road drift from the ground within a segment and jump back at the next,
which read as a staircase with a cliff in it every forty nodes. The rule is
one-sided — a road may be cut into a hill, never raised above it — and a forward
then backward minimum pass computes the lowest profile that stays under the
ground and never rises faster than one node per step.

Water up to forty-eight nodes is bridged with a plank deck at the water surface;
wider than that the road stops at the shore. A deck already laid reads as solid
ground, so what is *underneath* is asked instead — without that the overlapping
pass replaced the planks with dirt.

Measured on the ground with `/pw_road_check`: 124 of 124 cells, no gaps, no step
above one, across three chunk seams, on a link that crosses a lake.

Two instruments, both of which were needed to find the above: `/pw_road_network`
reports what is planned; `/pw_road_check` reads back what is on the ground and
says what is there instead when nothing is. The first readback claimed 138 of
170 cells paved and was measuring the dirt under the grass, which is why tracks
are surfaced in grass path rather than dirt.

## Settlement Size

Villages were coming out at four buildings when they were planned for eight to
twelve. The cause was not terrain: on perfectly flat synthetic ground, where
terrain can be ruled out entirely, only 34 of 50 reached their planned size and
every rejection was `lot_overlap` or `road_conflict` — geometry, not ground.

Street length was drawn independently of how many buildings were meant to stand
on it. `branches` was computed for every archetype and read only by the compact
one, so a long thin village had nowhere to put its last houses, and the branches
that were drawn were seated at independent random points and could land on top
of each other.

Frontage is now two sides of street, a lot every average gap, half again on top
for the anchors lost to neighbours and to the carriageway. That figure is a
*floor* under the length, not a replacement for it: sizing the street only from
the target was tried first and was worse in every direction, and the valid rate
fell from 177 in 241 to 135.

Measured over the same 241-input synthetic sample:

| | before | after |
|---|---:|---:|
| valid plans | 177 | 183 |
| lots achieved, of target | 905 (0.82) | 1077 (0.94) |
| reached their planned size | 104 of 177 | 136 of 183 |
| settlements of 8 lots or more | 19 | 39 |

In the world, a batch of twenty fresh candidates went from 4.1 to 5.0 lots per
settlement built, with slightly fewer outright failures.

The street length is capped at 96 nodes so the settlement stays inside the area
`emerge_village_area` generates for it. Towns larger than that need a wider
emerge, which is not done.

## Population

Settlements hold ordinary Mineclonia villagers. Ordinary on purpose: the game
already knows how a villager sleeps, claims a bed, takes a profession from a job
block and flees a zombie, and a parallel implementation would have to be as good
as that before it was worth anything.

The unit of population is **a bed standing in the world** — not a planned
dwelling, which would put people inside buildings that failed to materialize,
and not a lot, which would put them in barns. People move in when the place is
built, while its buildings are still loaded; the record makes that idempotent so
walking past twice does not double it.

"Place", not "settlement": region planning makes a village one time in five, and
the other four are a single farmstead with a bed in it. Population was first
routed through settlement records only, which left four fifths of the inhabited
buildings in the world standing empty — and would have refused them anyway,
since a lone farmstead has no settlement record to be found by. Both paths now
go through the same `settle(id, bounds)`.

Two failure modes that would have been silent:

- a node search over unloaded mapblocks returns nothing, exactly as an empty
  village does, so "not loaded" is a distinct answer and is not written down;
- spawning on the bed puts the mob inside a node, so villagers are placed on
  walkable ground beside it and a bed with nowhere to stand beside it is counted
  rather than papered over.

Verified in the world: six beds, six villagers, still six loaded in the village
after a full server restart. A batch of eight fresh villages populated itself as
it was built, two to five people each. A hamlet materialized on its own at
(27105, 27320) reported one bed and one villager moved in.

## Towns

Region planning now makes towns as well as farms, hamlets and villages — six
candidates in a hundred, because a world where one settlement in five is a town
is a world with no countryside in it.

A town is not a large village. It is planned to fourteen to twenty-four lots,
allowed a street twice as long, given up to six side lanes, walled, and built
partly out of the tall catalogue.

**Two to four storeys, stone below and timber above.** The `urban` schemes are
not a regional style: height belongs to the place, not to the region's way of
building, so a town draws on the tall catalogue *and* its regional one and comes
out mixed. Stone under timber is what the bottom of a tall building does
everywhere that has ever built one, and it is the single thing that stops a
four-storey plank box from reading as a four-storey plank box. Upper storeys are
reached by a ladder through a hole in each floor: without one they are sealed
rooms, which is worse than not having them, because a villager that cannot reach
its bed never sleeps.

**A wall with gates.** It follows the ground rather than being levelled into it,
so it steps down a slope the way a built wall does. Gates are cut wherever a way
crosses the line — and the ways include the roads arriving from other
settlements, which come from outside and would otherwise end at a wall. A wall
without them seals the town and everything that was reachable stops being
reachable, which does not look wrong from outside.

**Guards.** Two to four iron golems are posted at the gates when the town is
built, rather than waiting for the population to reach the threshold Mineclonia
raises golems at. That mechanism is untouched and still applies.

Measured, on a town built at (-3236, -9533):

    size_class=town  lot_count=14  planned_lot_count=14
    structure_variants: urban_tower_four_hip, urban_house_three,
                        urban_house_two x2, vern_cottage_corner x2,
                        vern_stable x3, vern_barn, vern_house_long,
                        pw_farmstead_v1, pw_well_v1
    warnings=wall:1706 nodes, 11 gate(s)
    11 beds, 11 villagers moved in

**Fields outside the wall.** A town eats more than it can grow inside itself,
and a walled town with nothing but wall around it reads as a fort. The fields
are ordinary `field` worksites — the same kind a farming village gets — ringed
beyond the wall, because that is where farmland is when there is a wall: the
ground inside is worth too much to plant.

Eleven gates is more than a town wants — the rule opens one wherever any way
crosses, and six streets plus the roads to other settlements cross a lot. It is
honest rather than right, and tightening it to major ways only is the obvious
next pass.

Two things had to be built before any of this could work. Emerging the ground
for a town in one request would ask for more mapblocks than the emerge queue
accepts, and the surplus is dropped **silently** — the final callback never
fires and the caller waits forever. The area is emerged in tiles small enough
that no configuration can refuse one, nearest the centre first. And
`/pw_find_candidate` is bounded by the engine's map limit: region planning will
happily name coordinates the world does not extend to, and the first town this
project ever tried to build sat at x=33357, past the limit of about 31000, and
reported a failure with no visible cause.

## Trades This World Adds

Mineclonia's profession system is open: `mobs_mc.register_villager` takes a
name, a point-of-interest id, the workstation node the trade claims, a texture,
a trade list and a gift list. Everything a villager then does with it — finding
the workstation, claiming it, walking to it on a schedule, working, trading,
going home to sleep — is the game's own behaviour, generic over the profession.
Nothing was copied.

Two are added, for different reasons:

| Trade | Workstation | Why |
|---|---|---|
| `miner` | `pw_population:ore_table` | The game has a mason who cuts stone and a toolsmith who works iron, and nobody who goes and gets it. A world whose settlements are sited on measured ore should have somebody whose living is ore |
| `caravaneer` | `pw_population:loading_stage` | The roads between settlements exist and nothing uses them |

The workstations are our own nodes. Every node the game uses as a workstation is
already spoken for by one of its own professions, so sharing one would put two
trades in competition for the same block and whichever villager arrived first
would decide what the building was for.

**What the caravaneer is not, yet.** Registering the profession gives a villager
who claims a loading stage, works at it and trades other places' goods. It does
*not* give a villager who walks to the next town with a load: that is new
behaviour, not a new profession, and it is not written. `mcl_mobs` has `gopath`
and the settlement links are the waypoints it would need — the road is open, but
the journey is not made.

Miners are offered by mining settlements; caravaneers only by towns, because a
hamlet does not have a caravan.

Measured in a town at (357, 11727):

    trades: butcher=1 caravaneer=2 farmer=3 librarian=2
    workstations 15: barrel_closed=6 composter=4 lectern=2
                     loading_stage=2 smoker=1

Eight villagers, eight in work, and two of them in a trade this game did not
have until this mod registered it.

The one thing that had to be got right for any of it to load: `pw_population`
declares `optional_depends = mobs_mc`. Without it our mod loaded first, `mobs_mc`
was an undeclared global, and the registration silently did nothing but log that
this game had no profession API.

## Work

A village of six was one farmer and five people standing still. Mineclonia hands
out professions by letting a villager claim a workstation node it can find, and
our buildings contained almost none: of the fixtures the schemes placed, only
barrel, loom and cauldron were workstations the game recognises, and none of
them appeared in a dwelling. Anvil, furnace, crafting table and bookshelf are
decoration as far as a villager is concerned — the professions that sound like
them want a blast furnace, a smoker, a fletching table and a lectern.

Every dwelling now carries one workstation, and which one comes from the
settlement's specialization, which is itself decided from physical evidence. So
the trades follow from the land: a fishing village fills with fishermen and
fletchers, a mining one with masons and smiths. The scheme does not know or
care — one dwelling design furnishes differently in each.

Measured in a six-bed farming village, before and after:

    before   trades: farmer=1 unemployed=5
    after    trades: farmer=2 librarian=2 nitwit=2
             workstations 6: composter=3 lectern=2 smoker=1

Nobody is unemployed. The two nitwits are vanilla Mineclonia: a fraction of
villagers are born without the capacity for a profession. Reading it once was
not enough — straight after spawning the same village said `nitwit=2
unemployed=4`, because claiming a workstation takes time.

A **bell** goes up beside the street. It is what makes a cluster of houses read
as a village to the game rather than as loose mobs standing near each other:
villagers gather at it, raise the alarm from it, and the iron golems that defend
the place are counted around it.

Two tests defend this. One requires every trade a settlement offers to resolve
to a node this game actually registers. The other requires every workstation we
place to appear in `mobs_mc.jobsites` — the list the game itself uses — which is
the check that would have caught the anvil.

## Village Generation System (grammar v3)

Resource-aware, multi-archetype physical settlement pipeline. See
`docs/perfectworld-architecture.md` for the full contracts.

- **Bounded site selection**: exactly 9 sites and at most 81 surface columns
  per site
- **Four specializations**: fishing, farming, forestry and mining require
  physical water/soil/tree/stone evidence rather than a random or biome-only
  label
- **Grammar contract**: at least 2 dwellings, the specialization's production
  building and its required field/dock/forestry yard/minehead
- **3 archetypes**: linear, compact, hillside, with a documented hillside fallback
- **Grammar pipeline**: emerge → ecological survey → specialization → roads →
  required lots → optional lots → structures → exact roads → transactional
  worksite → reachability
- **Material palettes**: applied to foundations, walls, roofs, floors and paths
- **Stable variation**: independent labelled hash decisions, not a PRNG stream
- **Three fingerprints**: exact plan, structural, road graph
- **Physical validation**: checks records, required roles/worksites, exact
  collisions, doors and nodes in the real world
- **Diversity analysis**: >= 100 deterministic inputs, full metric set

## Resolved in This Cycle

| Defect | Impact |
|--------|--------|
| LCG lost 9 bits per step to double rounding | Generator collapsed to a 10466-long cycle; replaced with exact hash-based choices |
| `get_biome_data` returns a numeric id, resolver indexed `registered_biomes` by name | Every biome in the world resolved to `temperate`; the palette system was dead |
| Material palettes computed but never passed to a generator | Every village was built out of oak regardless of biome |
| Wells declare only rotation 0, planner picked from `{0,90,180,270}` | 3 of 4 wells failed to place |
| Road width applied along +x regardless of heading | North-south streets were one block wide |
| Roads materialized before structures | Terrain preparation buried the streets it had just laid |
| Fixed lot setback smaller than building footprints | Dominant rejection reason; lots could not clear the carriageway |
| Lot terrain check used a different area and slope limit than placement | Settlements landed in `partial` for lots the placer then rejected |
| Villages materialized inline from `on_generated` | Planned against terrain that did not exist yet and burned the candidate |
| `minetest.load_area` does not generate | Plans near the edge of the generated world produced zero lots |
| Downhill footprint corners sat above open air | Buildings floated on slopes; foundations now carry down as a bounded plinth |
| Settlement bounds hardcoded to ±50 | Did not contain the settlement |
| `complete` status ignored required roles and unbuilt lots | Contract now enforced and validated |
| Driveways were drawn but never recorded | Nothing proved a lot was reachable |
| Single fingerprint quantised coordinates by 2 | One-block differences were invisible |
| Frozen ocean passed every buildability check | A village with a full crossroads was materialized on the sea |
| Road polylines were never checked against terrain | Streets ran off clifftops, down rock faces and into water |
| Screenshot helper matched the xvfb-run wrapper shell | Captured the desktop instead of the game |
| Village role was effectively biome-flavoured variation | Nine bounded physical surveys now choose fishing/farming/forestry/mining from measured resources |
| Tree crowns hid the actual ground and a 6-node lattice missed trunks | Canopy is tree evidence, while structure and paving analysis continue to true ground |
| Fishing centres and streets could point into the water | The centre moves to measured shore land and the main street runs tangent to the shore |
| Every consumer interpreted road width independently | One exact raster now drives planning, placement, validation, worksite collision and oracle diagnostics |
| Production was only a label on a building | Every complete grammar-v3 village requires a physical transactional worksite |
| A frozen shore passed ecological selection but failed dock placement | The dock consumes the same open/frozen-water surface contract as the survey |
| Oracle settlement reads repeatedly parsed the entire storage map | Decoded storage maps are cached between writes; a 500-record oracle integration went from 8+ minutes to an immediate PASS |
| Street length was drawn independently of the number of buildings meant to stand on it | Villages planned for eight to twelve came out at four; frontage is now a floor under the length |
| `branches` was computed for every archetype and read only by the compact one | Long thin villages had nowhere to put their last houses |
| Branch streets were seated at independent random points | Two branches could land on top of each other and add no frontage at all |
| Settlement links paved segment by segment | Each segment restarted the height profile, so the road drifted from the ground and jumped back every forty nodes |
| A bridge deck reads as solid ground on the next pass | The overlapping chunk replaced the planks with road surface; what is under the deck is asked instead |
| `brain_holds_a_fresh_intent_instead_of_dithering` inherited the player's position | A diagnostic had left the test player in a lake, where dropping the plan every tick is correct; the test now builds its own dry ground and states the premise |

## Known Test Issues

The two FAILs are an existing test-configuration contradiction, not planner
regressions:

- `pw_bot_bridge.integration_transport_follows_its_setting`
- `pw_bot_bridge.transport_is_off_by_default_and_needs_no_insecure_environment`

Both expect `pw_bot_bridge.external_transport=false`, while the local
development file `config/luanti.conf` explicitly sets it to `true`. Configuration
was not changed during this cycle. Every other test passes.

Expected log noise remains: the world-format test deliberately feeds `pw_core`
an incompatible lock, terrain rollback fixtures provoke
`CONTENT_IGNORE` diagnostics in unloaded test cells, Mineclonia can overflow
its redstone event queue after the destructive fixture suite, and the client
reports unsupported translation `.po` files. No `LuaError`, `AsyncErr`, fatal
error or stack traceback was observed.

## Buildings

Modelled on the vanilla plains village houses
([Minecraft Wiki, Village/Structure/Blueprints](https://minecraft.wiki/w/Village/Structure/Blueprints)):
cobble plinth, timber corner posts, plank infill, glass-pane windows on every
wall, a pitched roof of stairs with a slab ridge and one-block eaves, and a
porch step at the door.

Ten structures: four dwelling shapes, a barn, a farmstead, a well, a fishery, a
sawmill and a mine workshop. Each biome family carries its own wood and stone —
oak, birch, spruce, acacia, dark oak, jungle — so two villages in different
biomes can use different materials.

Every door is checked with the engine's pathfinder from the street, on foot,
with a walker's limits. Unreachable lots are rejected at plan time; anything
that still cannot be reached gets a stepped way cut to it and, failing that,
keeps the settlement out of `complete`.

## Known Visual Defects

Reviewed through a real visible Luanti client. Complete farming, forestry and
mining records were validated against the world and inspected from overview and
worksite cameras.

| Defect | Cause | Effect |
|--------|-------|--------|
| Streets are patchy where the ground undulates | The carriageway is one node per column at a smoothed height; cells whose surface is water are skipped | The street reads as a street, but the edges are ragged |
| 3 of 11 settlements have one door the pathfinder cannot reach | The approach check is per-lot; it cannot see a neighbour that will later be built across the only route | Those settlements stay `partial`, which is the honest status |
| Most settlements come out `hillside` on this mapgen | The hillside fallback fires whenever a flat archetype finds no viable layout, which is common on `carpathian` | On flat ground hillside looks like linear |
| No complete fishing village was found inside valid world coordinates in this seed's acceptance sample | Viable shore geometry must fit two houses, a fishery and a dock without using water or a cliff | Fishery and dock components pass physical tests, but full real-world fishing composition still needs a deterministic acceptance fixture |
| `/pw_village_batch` accepts radii beyond the engine's usable coordinate range | The development command enumerates arbitrary region coordinates and does not clamp to `mapgen_limit` | It can write non-visualizable diagnostic records; normal mapgen does not generate those regions |
| A settlement link can leave one water cell unpaved at a lake edge | The bridge decides from the column it probes; water that flows back over a freshly laid deck is not re-probed | One cell in sixty-two on the link measured; the road either side is continuous |
| `/pw_street_check` reads nothing for settlements whose blocks are not loaded | Teleporting to a settlement does not guarantee the server keeps its mapblocks, and `load_area` only loads what is already generated | Streets in those settlements report every cell unreadable, which is honest but leaves them unmeasured |

Fixed: roof stairs pointed downhill, so every course rose at its outer edge and
dropped at its inner one and the roof read as a row of combs from the gable end.
`roof_stairs_rise_towards_the_ridge` now measures orientation; nothing did
before.

Village streets now use the same one-sided height profile the settlement links
do, and a driveway no longer rewrites the street cell it arrives at. Measured
with `/pw_street_check`:

| built by | street | cells | biggest step |
|---|---|---:|---:|
| the old per-segment paver | main | 57 | 18 |
| the old per-segment paver | contour | 53 | 6 |
| the shared profile | main | 84 | 0 |
| the shared profile | main | 73 | 0 |
| the shared profile | cross | 55 | 1 |
| the shared profile, before the driveway fix | main (with lots) | 69 | 5 |
| the shared profile, after the driveway fix | contour (with lots) | 63 | 1 |

The last row is one village measured cleanly; the other villages in that batch
could not be read at all, so the driveway fix has one physical data point
behind it rather than a sample.

`/pw_street_check` took four revisions before it measured the carriageway, and
each wrong version accused the road of a defect it did not have — the topmost
node in the column is the tree beside the street, the topmost walkable one is
the mountain above it, and a probe that follows the last cell too far down
finds a cave and reports a village built underground. The lesson is not about
roads: a measurement that has never been wrong has probably never been checked.

Fix directions: add a valid-coordinate deterministic fishing acceptance seed,
order lots by approach quality before accepting them, clamp debug batch radius,
and make the plan-level approach check require a driveway long enough for the
height it has to lose rather than a flat limit of six.

## PW Bot: measured on the obstacle course

The third part exists. `pw_bot_runtime` drives a real client through XTEST; the
course in `pw_debug/bot_course.lua` gives it deliberate obstacles, half of which
it is meant to fail. Run it with `scripts/pw-bot-course.sh build` then
`pw-bot-runtime scenario course`.

**The course passes end to end.** Every step behaves as expected.

| Step | Verdict |
|------|---------|
| `walk_straight`, `turn_corner`, `step_up`, `climb_stairs` | reached — the body walks, turns, climbs a kerb and takes stairs |
| `open_door` | reached — `door_acacia_t_1` → `_t_2`, closed to open, empty hand, crosshair on the door |
| `enter_room`, `leave_room` | reached — through the doorway it opened, and out the far side |
| `open_gate`, `open_trapdoor` | reached — a fence gate and a trapdoor inside the room, both opened by hand |
| the five obstacles that must fail | all `blocked`, and no longer by an unopened door |

Everything physical the bot does goes through XTEST into a real client. Nothing
teleports it after the start line.

### What was wrong, and how it was found

Six defects, each of which alone stopped an interaction, and all found by
measuring rather than reasoning:

1. **The pointer warp destroyed the aim.** The runtime aimed, then warped the
   pointer to the window centre, then pressed. Luanti turns the head from
   *relative* pointer motion and never grabs the pointer on a bare Xvfb, so the
   warp arrived as a large mouse movement between aiming and pressing.
2. **The "empty" hotbar slot held a block.** Twice guessed, twice wrong —
   `players.sqlite` has snowballs in slots 1 and 2 and oak wood in 5. The
   runtime now asks the bridge what is in hand instead of assuming.
3. **The crosshair position was read from the wrong field.** `inspect_target`
   reports it on the *target*, with the node nested inside; the code looked in
   the node, got null on every hit, and called a correct aim a miss.
4. **Aiming once at the named node pointed at the floor.** A door is named by
   its lower node, which from the doorstep is a node below eye level a node
   away — the ray hit the floor at the bot's feet. Aiming is now closed-loop
   against what the crosshair reports.
5. **Aiming at a node's centre misses a thin node.** A closed trapdoor fills a
   fraction of its node; a ray through the middle passes into the wall behind.
   The aim tries fractional heights too.
6. **An opened gate stops being visible, and that read as failure.** A closed
   leaf blocks the ray, an open one does not. Had the click done nothing, the
   closed leaf would still be blocking and still be reported — so the
   disappearance is evidence, not silence.

The wrong-field lookup in (3) appeared in three separate places and was fixed
three times, each time after it had produced a different, plausible-looking
failure. It is the single most expensive mistake in this cycle.

Ruled out along the way, with evidence rather than argument: the client does
read `client.conf` and its bindings are live (moving `keymap_forward` to a
non-default key stops the bot walking); `keymap_place` is a setting Luanti
recognises and `SYSTEM_SCANCODE_21` is R (it normalises `KEY_KEY_R` to exactly
that); the place action reaches the server (`pwbot places node …` in the server
log); and the course's door is a working door (`/pw_bot_course door` calls its
`on_rightclick` server-side, and puts it back afterwards).

### What the course does not yet prove

The five obstacles that must fail stand in series, and the runtime walks in
straight lines. All five report `blocked by mcl_trees:wood_oak` — the two-node
wall of the *first* of them. Only that first obstacle is genuinely under test;
the other four sit behind a wall the bot cannot pass. Better than being stopped
by an unopened door, and still not proof.

Interaction is tested against a door, a fence gate and a trapdoor. Chests,
levers, buttons and furnaces go through the same path but have never been tried,
and a chest is the interesting case: opening one changes no node state, so the
current "did the world answer" check has nothing to see.

One run in three had `leave_room` return `blocked by something` with no node
named, and the next run of the same course passed it. That is flaky rather than
fixed, and an obstacle report that cannot name what stopped the bot is worth
chasing on its own.

## Missing Systems

- The acting PW Bot client layer remains outside this world-generation cycle;
  `pw_bot_bridge` only perceives and `pw_player_bot` only decides — see
  [docs/pw-bot/](pw-bot/README.md)
- Terrain generated before a feature existed never had its chunk hook run over
  it: settlement links in an old world have to be laid by hand with
  `/pw_roads_pave`, and villages built before people existed need `/pw_populate`
- Production simulation, inventories, economy and trading — deliberately out of
  scope for now
- Cities: the type exists in `pw_settlements` but region planning does not
  produce it. Towns do exist now
- Farms and hamlets are the same building under two names — both place a single
  `pw_farmstead_v1` and differ only in priority
- The caravaneer's journey: the profession exists and is taken, but nobody yet
  walks a load from one settlement to the next
- Tunnels, and bridges over water wider than forty-eight nodes
- Global route pathfinding over the settlement link network
- Save migration between planner versions

## Immediate Technical Tasks

- Add a deterministic, in-range complete fishing-village acceptance fixture
- Clamp `/pw_village_batch` and other world-debug enumeration to the engine
  `mapgen_limit`
- Integrate the remaining legacy settlement type weights into the specialization
  definitions
- Add a save migration framework for world format changes
- Widen the structure catalogue and add more specialization-specific decor

## Supported Platforms

- Linux with Docker
- Luanti 5.16.1 server and client
- Mineclonia game
- Xvfb for headless testing and screenshots
