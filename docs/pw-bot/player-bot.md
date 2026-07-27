# pw_player_bot — the brain

`pw_player_bot` is the second half of PW Bot: the part that decides.

```
pw_bot_bridge     perceives    -- never acts
pw_player_bot     decides      -- never acts
a future runtime  acts         -- through a real client, like a player
```

The mod has no way to move a player, turn a head, press a key, place a node or
read the map. It reads what `pw_bot_bridge` reports in **player mode**, keeps a
bounded memory of it, forms beliefs, feels needs, scores goals, plans a route
over remembered ground, and writes down an intent. Something else — not yet
written — reads that intent and drives a real Luanti client.

## Why the split

A server mod *can* teleport a player. The moment one does, the thing it produces
stops being a bot and becomes a puppet: it walks through walls it never saw, and
none of its behaviour tells you anything about whether the world is walkable.
The whole exercise is worth doing only if the bot is confined to what a player
could know and what a player could do, which is why the boundary is enforced by
`scripts/smoke-test.sh` and not just described here.

## The decision loop

One tick, start to finish, in [brain.lua](../../local_mods/perfectworld/pw_player_bot/brain.lua):

```
observe -> remember -> believe -> feel -> propose -> score -> plan -> intend
```

| Stage | Module | What happens |
|-------|--------|--------------|
| observe | `brain.observe` | One `observe` request to the bridge, in the configured profile |
| remember | `memory.integrate` | The observation is folded into bounded memory with a confidence |
| believe | `beliefs.rebuild` | Traversability, hazards, water and the frontier are derived |
| feel | `needs.evaluate` | Five drives in `[0, 1]`, each with a stated reason |
| propose | `goals.propose` | Every goal the beliefs make possible, capped at 24 candidates |
| score | `utility.choose` | Need satisfaction × instance quality, deterministic tie-break |
| plan | `goals.plan` | Only the chosen goal is planned; a goal that cannot be planned is dropped and the next one gets its turn |
| intend | `intent.build` | An intent document, with the alternatives that lost |

The loop runs on a timer (`pw_player_bot.tick_interval`, default 1 s), never per
server step, and every stage is bounded. If a tick overruns
`settings.HARD.tick_budget_us` (25 ms) mid-planning, it publishes what it has
rather than stalling the server.

### The freshness hold

A fresh intent is left alone until `intent_ttl_ticks` have passed. Without it the
bot dithers: it picks a frontier cell, takes one step, notices a marginally
better one, and turns around forever. The hold is broken by two things — being
stuck for two ticks, and `safety > 0.5`. Committing to a plan is not the same as
ignoring a fire.

## Player mode only, enforced

`brain.ALLOWED_OPERATIONS` lists the bridge operations the brain may ask for.
They are all player-mode operations. If a bot happens to be registered in oracle
mode — because an administrator was diagnosing something — the brain still
refuses to think with oracle data.

## Determinism

`math.random` is never called; the smoke test greps for the call and fails the
build if it appears. Equal-scoring candidates are common and genuinely
equivalent, so ties break on `perfectworld.core.choice.unit` over the candidate's
label plus the memory tick: the same way every time for the same state, and
differently across ticks, so the bot does not lock onto one of two equal options
forever.

The contract is: **the same memory and the same observation produce the same
intent.**

## Modules

| File | Covers |
|------|--------|
| `settings.lua` | Every tunable, each with a hard ceiling |
| `memory.lua` | Bounded, decaying, persisted memory of columns, features and objects |
| `beliefs.lua` | What memory implies: standable, traversable, hazardous, frontier |
| `navigation.lua` | A* over remembered columns only |
| `needs.lua` | Five drives, and the fear gate |
| `goals.lua` | Seven goal kinds, their candidates and their plans |
| `utility.lua` | Scoring and the tie-break |
| `intent.lua` | `pw_player_bot/v1`: the document a controller executes |
| `brain.lua` | The tick, the timer, the status |
| `api.lua` | The public Lua API |
| `commands.lua` | Administrative chatcommands |

See [player-bot-memory.md](player-bot-memory.md) for memory and beliefs,
[player-bot-decisions.md](player-bot-decisions.md) for needs, goals and scoring,
and [intent-v1.md](intent-v1.md) for the output document.

## Settings

All under the `pw_player_bot.` prefix; see `settingtypes.txt` for the full list
with ranges.

| Setting | Default | Meaning |
|---------|---------|---------|
| `enabled` | `true` | Whether the timer runs at all |
| `tick_interval` | `1.0` | Seconds between decisions |
| `observation_profile` | `navigation` | Bridge profile: `minimal`, `navigation`, `detailed` |
| `memory_max_cells` | `4096` | Ceiling on remembered columns |
| `memory_max_features` | `512` | Ceiling on remembered features |
| `memory_max_entities` | `128` | Ceiling on remembered objects |
| `memory_stale_ticks` | `600` | After this, memory reports itself stale |
| `route_max_expansions` | `4000` | A* budget per plan |
| `route_max_length` | `128` | Longest route accepted |
| `route_max_step_up` | `1` | Highest climbable step |
| `route_max_step_down` | `3` | Deepest acceptable drop |
| `intent_ttl_ticks` | `10` | How long an intent stays fresh |
| `log_intents` | `false` | Write every intent to a world artifact |

Every setting is clamped to `settings.HARD` on load. A configuration file cannot
raise a ceiling.

## Commands

All require the bridge's `pw_bot_admin` privilege — a separate privilege would
only be a second thing to forget to check.

| Command | Does |
|---------|------|
| `/pw_player_bot_status [player]` | What the bot knows, wants and decided |
| `/pw_player_bot_start <player>` | Start thinking for a bot already registered with the bridge |
| `/pw_player_bot_stop <player>` | Stop and save memory |
| `/pw_player_bot_think <player>` | Run one decision now and summarise it |
| `/pw_player_bot_explain <player>` | The full scoring table, deciding nothing |
| `/pw_player_bot_route <player> <x> <y> <z>` | Plan a route using only remembered ground |
| `/pw_player_bot_memory <player> [forget]` | Summarise or wipe what was learned |
| `/pw_player_bot_capabilities` | What this build can do |
| `/pwbot_brain [think\|status\|stop]` | Shortcut for the configured test player |

Commands that produce a full document write it to a world artifact and print the
file name only. A server filesystem layout is not something to print into chat.

## Lifecycle

`P.start(player_name, actor)` refuses unless the player is **already registered
with `pw_bot_bridge`**. Perception is granted by the server; this mod is a
consumer of that grant, never a second way to obtain one.

Memory is saved on `stop`, on `/pw_player_bot_memory ... forget` (as a wipe), and
on server shutdown. A bot that forgot the village whenever the server bounced
would never build up anything worth calling knowledge.

## What this mod does not do

- move, turn, jump, interact, or press anything
- place or remove a node
- read the map, cast a ray, or list objects — all of that is the bridge's
- use oracle data
- build, craft, fight, trade, chat, or run an NPC
- call an LLM
- look at a screenshot; a screenshot is a diagnostic artifact for a human, and
  is not, and will not be, the bot's vision
