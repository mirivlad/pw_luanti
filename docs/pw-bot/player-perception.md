# Player perception

## The contract

> **`player` mode is a deterministic server-side approximation of the
> programmatic perception available to a player, bounded by position, look
> direction, field of view, view distance and line of sight.**

Read that sentence twice, because every word in it is load-bearing, and because
what it does *not* say matters as much.

It does not say the bridge returns what is on the screen. It cannot, and any
document that implied otherwise would be lying. What the server actually knows:

| The server knows | The server does not know |
|------------------|--------------------------|
| the player's position | the client's FOV setting |
| yaw and pitch | the client's view range setting |
| every node it has loaded | which mapblocks the client has actually received |
| every object it tracks | what the renderer drew, or in what order |
| line-of-sight geometry | occlusion culling decisions |
| node definitions | the texture pack, transparency, or shaders |

So `player` mode is an approximation with a stated, testable definition, not a
screen capture. The approximation is *deterministic*: same world, same position,
same look direction, same request, same bytes.

## What is never returned in player mode

* nodes behind an opaque obstacle
* the contents of a closed building
* a settlement's full layout
* objects that are not visible
* roads beyond what is observed
* the generator's internal plans
* precise coordinates of unseen targets
* a region's full object list
* arbitrary nodes at remote coordinates
* internal settlement identifiers for anything not yet observed

The last one is worth naming: a settlement id is not secret in itself, but
handing one over for an unobserved village would disclose that the village
exists, which a player standing here would not know.

## Composite, not a cube

A cube of every node within N blocks would be both a leak and useless. Perception
is assembled from six channels, each with its own justification.

### 1. Proprioception — `self_state`

What the body knows about itself.

```json
{
  "player_name": "pwbot",
  "connected": true,
  "position": {"x": 0.0, "y": 0.0, "z": 0.0},
  "eye_position": {"x": 0.0, "y": 1.625, "z": 0.0},
  "eye_height": 1.625,
  "velocity": {"x": 0.0, "y": 0.0, "z": 0.0},
  "yaw": 0.0,
  "pitch": 0.0,
  "look_dir": {"x": 0.0, "y": 0.0, "z": 1.0},
  "on_ground": true,
  "on_ground_source": "derived_from_node_under_and_velocity",
  "in_liquid": false,
  "liquid_type": null,
  "hp": 20,
  "breath": 10,
  "wielded_item": "mcl_throwing:snowball",
  "attached": false,
  "attached_entity": null,
  "node_under": {"name": "...", "state": "loaded", "position": {}, "semantics": []},
  "node_at_feet": {},
  "node_at_body": {},
  "node_at_head": {}
}
```

Two honesty rules apply here.

**Nothing is invented.** A field the server API cannot answer is reported as
`{"available": false, "reason": "unsupported_by_server_api"}` rather than
guessed.

**Derived values say they are derived.** Luanti exposes no server-side ground
flag for players, so `on_ground` is inferred from the node under the feet and
the vertical velocity, and `on_ground_source` says exactly that. A consumer that
needs certainty knows not to trust it blindly.

### 2. Tactile / collision vicinity — `tactile`

The space the body occupies and the block it is about to walk into. Radius: 2
nodes.

```json
{
  "radius": 2,
  "ground_under_feet": {"name": "...", "walkable": true, "climbable": false, "liquid_type": "none"},
  "space_at_feet_ahead": {},
  "space_at_body_ahead": {},
  "space_at_head_ahead": {},
  "space_above_head": {},
  "step_height_ahead": 1,
  "step_reason": "standable",
  "drop_ahead": 0,
  "head_clearance": 3,
  "in_liquid": false,
  "obstacle_ahead": false,
  "climbable_ahead": false
}
```

This channel is reported **regardless of where the head is pointing**, and that
is deliberate: at arm's length it models physical contact, not sight. A walker
knows the ground it is standing on while looking at the sky. That is why the
radius is two nodes and not twenty — the justification stops working at
distance.

### 3. Vision rays — `rays`

A deterministic fan relative to the current yaw and pitch. Rays start at body
levels, not only at the eye: the ray that tells a walker about a kerb comes from
the feet, and an eye-level ray cannot.

| Profile | Rays | Composition |
|---------|------|-------------|
| `minimal` | 3 | body centre, one up, one down |
| `navigation` | 17 | feet/body/head × −30°/−15°/0°/+15°/+30°, plus up and down |
| `detailed` | 27 | feet/body/head × ±45°/±30°/±15°/0°, plus three up and three down |

Origin levels: `feet` at +0.3, `body` at +1.0, `head` at the real eye height;
`up` and `down` start at the eye with a ±35° pitch offset. Rays that fall outside
the configured field of view, or outside a scan sector, are skipped and counted
in `rays_skipped_outside_sector` — never silently dropped.

```json
{
  "ray_id": "body_c",
  "origin_level": "body",
  "yaw_offset_deg": 0,
  "pitch_offset_deg": 0,
  "hit_type": "node",
  "distance": 4.2,
  "visible": true,
  "attenuated": false,
  "position": {"x": 10, "y": 65, "z": 14},
  "relative_position": {"x": 0, "y": 0, "z": 4},
  "node": {"name": "...", "properties": {}, "semantics": []},
  "passed_nodes": []
}
```

`hit_type` is `node`, `unloaded`, `ignore`, `none` or `budget`. Rays are sorted
by `ray_id`, so their order in a response never depends on how the profile table
was built.

**Nothing beyond the first opaque obstacle is reported as visible.** The
traversal is a voxel walk (Amanatides–Woo) that stops at the first sight-blocking
node, at unloaded map, or at an `ignore` placeholder — the bridge does not claim
to see through data it does not have.

`passed_nodes` is the other half of that truth. A closed door, a pane of glass
and a ladder are all things a player plainly sees, and none of them stop light,
so the ray records the solid-but-see-through nodes it went through, up to four
per ray. Without it, "is there a door ahead?" could never be answered.

### 4. Visible objects — `visible_entities`

Four filters, cheapest first: range, then the view sector, then the policy
filter, then line of sight — which is the only one that touches the map. An
object is tested at three heights, so a boat is not declared invisible because
its keel is behind a kerb.

```json
{
  "observation_id": "ent-s113-8974b28c-2",
  "kind": "boat",
  "name": "mcl_boats:boat",
  "position": {},
  "relative_position": {},
  "distance": 7.3,
  "direction": {},
  "interactable": true,
  "physical": true,
  "attached_to": null,
  "attached_to_player": false,
  "semantic_tags": ["boat", "interactable", "vehicle"]
}
```

No Lua reference ever leaves the bridge. `observation_id` is opaque and stable
for the life of the session; after a restart or a reconnection it addresses
nothing. Rejected candidates are summarised by reason
(`occluded`, `outside_horizontal_fov`, `outside_vertical_fov`, `out_of_range`,
`limit`) so a consumer can tell "nothing is there" from "something is there and
you cannot see it".

### 5. Visible features — `visible_features`

Recognition, not disclosure. A dense internal fan sweeps the permitted sector
and reports the recognised features it strikes: `road_surface`, `path_surface`,
`door`, `gate`, `stair`, `slab`, `ladder`, `climbable`, `water`, `liquid`,
`shore`, `structure_entrance`, `fence`, `farmland`, `container`, `hazard`,
`vehicle`, `boat`.

A stretch of road in view is reported as road. Where that road goes is not,
because a player standing there would not know either.

### 6. Surface profile — `surface_profile`

A short strip of ground in the look direction, at most 12 nodes.

```json
{
  "step": 3,
  "relative_direction": "forward",
  "position": {"x": 10, "z": 14},
  "ground_y": 63,
  "ground_node": "mcl_core:dirt",
  "top_y": 63,
  "slope": -1,
  "gap": true,
  "water": false,
  "obstacle_height": 0,
  "head_clearance": 3,
  "walkable": true,
  "semantics": ["ground"]
}
```

Two filters apply, modelling two different senses. The first three steps are
body space and are reported whatever the head is doing. Every step beyond that
must be inside the field of view **and** in line of sight — a dip behind a wall
stays hidden, and says so with `{"available": false, "reason": "not_visible"}`.

The ground reported is the highest surface with room to stand on, which is what
a walker cares about; a liquid counts as a surface, because "the ground ahead is
water" is precisely the fact that must not be hidden by reporting the stone
underneath it. `top_y` gives the highest solid node in the column, which is not
always the one a body would stand on.

## Scans

`scan_forward`, `scan_left`, `scan_right`, `scan_up`, `scan_down` narrow the
reported sector to part of the field of view that is already permitted:

| Operation | Sector |
|-----------|--------|
| `scan_forward` | the central third, horizontally and vertically |
| `scan_left` | the left half |
| `scan_right` | the right half |
| `scan_up` | the upper half |
| `scan_down` | the lower half |

A scan never turns the player and never widens what may be seen. The real turn
will be made later by a real client; the integration tests assert that yaw,
pitch and position are unchanged after every scan.

## `inspect_target`

The one place that uses the engine's own raycast, because "what would this player
select" is a question about *pointability*, which is what `minetest.raycast`
answers — and pointability is not the same property as opacity. The response says
which it used (`"method": "engine_raycast_pointability"`) and reports
`within_reach` separately from `distance`.

## Typical cost

Measured on the project's dev world with a connected `pwbot`:

| Profile | Response | Rays | Nodes read | Time |
|---------|----------|------|------------|------|
| `navigation` | ~33 KB | 17 | ~2100 | ~3–4 ms |
| `detailed` | ~48 KB | 27 | ~2300 | ~4 ms |

Well inside the 40 ms budget and the 256 KB response limit. When a budget is
exhausted the response says so in `budget.truncated` and
`budget.truncated_reason`; the wide feature sweep is built last, so what degrades
first is the least essential channel.
