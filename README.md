# PerfectWorld

Procedural physical world generation for [Luanti](https://www.luanti.org/) with
[Mineclonia](https://content.luanti.org/packages/ryvnf/mineclonia/).

PerfectWorld builds the physical shape of a living world: regions, settlements,
buildings, roads between them, and the people who live there — all placed
deterministically from the world seed.

> **Status:** experimental. See [docs/status.md](docs/status.md) for the current
> test baseline, what was measured, and what is known to be wrong.

## What It Does

**The land and what stands on it**

- Divides the world into 1024×1024 deterministic regions, each holding on
  average 1.8 settlements: a lone farmstead about four times in ten, and a
  hamlet, village or town the rest of the time
- Plans farms, hamlets, villages and towns, choosing each site from a bounded
  physical survey rather than from a biome label, and refusing ground that is
  too steep, too barren, or level with the water beside it
- Gives each settlement a trade — fishing, farming, forestry or mining — that
  has to be supported by measured water, soil, trees or stone
- Builds from a catalogue of **68 declarative building schemes in six styles**:
  vernacular, nordic, japanese, mediterranean, stilt, and urban for towns. A
  settlement picks one style and builds only from it
- Walls a town, cuts a gate where each road arrives, posts guards on them, and
  rings it with fields outside the wall
- Names every place from what the land is, and puts a sign at every way in

**Roads**

- Joins settlements with a network computed as a Gabriel graph, so two regions
  either side of a border agree about the countryside between them without
  talking to each other
- Follows the ground with one height profile per road: goes round a hill where
  there is a flank, bores through where there is not, decks a gorge on piers,
  and bridges water up to forty-eight nodes
- Ends in a landing — deck, mooring posts, lamp and a boat — where it meets
  water it cannot cross

**People**

- Moves ordinary Mineclonia villagers in, one per bed standing in the world
- Puts a workstation in every dwelling, chosen from the settlement's trade, so a
  fishing village fills with fishermen and a mining one with masons
- Hangs a bell, which is what makes a cluster of houses read as a village to the
  game rather than as loose mobs standing near each other

**The bot**

- `pw_bot_bridge` — a server-side perception API, so an automated player and the
  test kit can inspect what was built
- `pw_player_bot` — decides what such a player would do: bounded memory,
  beliefs, needs, goals and routes, written down as an intent and never executed
- `pw_bot_runtime` — drives a real client through XTEST. It walks, climbs, and
  opens doors, gates and trapdoors

## What It Doesn't Do (Yet)

- **Economy.** Nothing in the world changes after it is generated: every
  `globalstep` in the project belongs to the bot. A settlement built today is
  identical in a year
- **Caravans.** The roads between settlements carry nobody
- **Port towns.** A road that meets the sea gets a landing stage; the town that
  should stand behind it is not built
- **Errands.** The bot has a body and walks a course, but has no goal for going
  somewhere *in order to do something* — see [docs/pw-bot/](docs/pw-bot/README.md)
- **Cities.** The type exists; region planning never produces one, and a street
  longer than 96 nodes would be planned against terrain that has not been
  generated yet
- **Doors that can be reached.** Measured on a fresh world: 162 lots
  materialized, 16 doors with no walkable route from the street. A rescue route
  was built for all sixteen and none of them worked. Run
  `scripts/pw-accessibility-check.sh --fresh` to reproduce the figure
- **Every planned settlement.** Walking to 23 candidates a traveller would meet,
  20 had something standing on them. The three that did not were a town the
  survey put in the ocean, a village on a hillside too rough to build on, and
  one farmstead. Run `scripts/pw-mapgen-probe.sh` to reproduce the figure
- Global route pathfinding over the settlement network
- Save migration between planner versions

## Requirements

- Docker + Docker Compose
- Python 3
- 3 GB free disk space (Docker image + Mineclonia)
- Port `30000/udp` available

## Quick Start

```bash
git clone https://github.com/mirivlad/pw_luanti.git
cd pw_luanti
python3 scripts/install-content.py
docker compose build
./scripts/sync-local-mods.sh
docker compose up -d
```

Wait for the server:

```bash
timeout 90 sh -c 'while :; do
  grep -q "Server for gameid=.*listening" data/debug.txt && exit 0
  sleep 2
done' && echo "Ready"
```

Connect with any Luanti 5.16.1 client to `127.0.0.1:30000` (game: Mineclonia).

Stop: `docker compose down`

See [docs/quickstart.md](docs/quickstart.md) for detailed first-run instructions.

## Running Tests

```bash
./scripts/run-testkit.sh
```

That restarts the server in test mode, connects `pwbot`, runs everything and
prints the summary. `--keep` reuses a running server; `--no-client` skips
starting the client.

Current: **385 total | 383 PASS | 2 FAIL | 0 SKIP | 0 ERROR**

The two failures are a configuration contradiction, not a regression: two
`pw_bot_bridge` tests require `external_transport` to be off by default, while
`config/luanti.conf` turns it on for `pw_bot_runtime`. See
[docs/status.md](docs/status.md).

Two further scripts measure the world rather than the code, and both take
tens of minutes:

```bash
./scripts/pw-mapgen-probe.sh --count 26 --radius 12 --inner 4
```

walks to planned settlements, generates the ground under each the way arriving
there would, and reports what the mapgen hook built on its own.

```bash
./scripts/pw-accessibility-check.sh --fresh
```

builds a sample of settlements and reports how many doors have no walkable route
from the street.

See [docs/testing.md](docs/testing.md) for full test documentation.

## Project Structure

```
PerfectWorld/
├── Dockerfile                    # Luanti 5.16.1 server build
├── docker-compose.yml            # Server mode (with --terminal)
├── docker-compose.test.yml       # Test mode (log to file)
├── config/
│   ├── luanti.conf               # Server configuration
│   ├── content.json              # ContentDB packages to download
│   └── world.mt.example          # Example world config
├── locks/
│   └── content.lock.json         # Pinned content versions
├── docs/                         # Documentation
├── local_mods/
│   ├── perfectworld/             # PerfectWorld modpack
│   │   ├── pw_core/              # API, version, world format lock, hashed choices
│   │   ├── pw_compat_mcl/        # Mineclonia materials, biome families, palettes
│   │   ├── pw_planner/           # Region planning, village grammar, materialization
│   │   ├── pw_structures/        # Structure registry, terrain preparation, placement
│   │   ├── pw_schemes/           # 68 declarative building schemes in six styles
│   │   ├── pw_roads/             # Road raster, and the network between settlements
│   │   ├── pw_settlements/       # Settlement types, specializations, trades, names
│   │   ├── pw_population/        # The people: villagers, one per bed
│   │   ├── pw_debug/             # /pw_* chat commands, reports, screenshots
│   │   ├── pw_bot_bridge/        # Server-side perception for the bot
│   │   ├── pw_player_bot/        # The bot's decision layer: memory, needs, goals
│   │   └── pw_tests/             # TestKit-based tests
│   ├── luanti_testkit/           # Universal test framework
│   └── pw_remote_control/        # JSON remote controller
├── tools/
│   └── pw_bot_runtime/           # Drives a real client through XTEST
├── scripts/                      # Build, install, test and diagnostic utilities
└── secrets/                      # Password files (gitignored)
```

`data/` is runtime (gitignored): worlds, installed games, mods, logs.

## Documentation

| Document | For |
|----------|-----|
| [docs/quickstart.md](docs/quickstart.md) | First-time setup |
| [docs/player-guide.md](docs/player-guide.md) | Commands and what to expect |
| [docs/testing.md](docs/testing.md) | Running and understanding tests |
| [docs/development.md](docs/development.md) | Architecture and contributing |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and fixes |
| [docs/status.md](docs/status.md) | Current state, what was measured, known issues |
| [docs/perfectworld-architecture.md](docs/perfectworld-architecture.md) | Detailed design |
| [docs/pw-bot/](docs/pw-bot/README.md) | The bot bridge: perception API, protocol, security |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |
| [MIGRATION.md](MIGRATION.md) | History: extraction from monorepo |

## Origin

PerfectWorld was extracted from a larger monorepo in July 2026.
See [MIGRATION.md](MIGRATION.md) for details.

## License

MIT. See [LICENSE](LICENSE).

Mineclonia and Luanti are separate projects under their own licenses, and
nothing here redistributes their content. The village houses are modelled on the
vanilla plains blueprints as *described* on the Minecraft Wiki and written from
scratch in Lua; no Mojang asset is copied or converted into this repository.
