# PerfectWorld

Procedural physical world generation for [Luanti](https://www.luanti.org/) with
[Mineclonia](https://content.luanti.org/packages/ryvnf/mineclonia/).

PerfectWorld builds the physical shape of a living world: regions, settlements,
buildings, roads, and farms — placed deterministically through mapgen
integration.

> **Status:** experimental. See [docs/status.md](docs/status.md) for current
> test baseline and known issues.

## What It Does

- Divides the world into 1024×1024 deterministic regions
- Exposes a server-side perception API (`pw_bot_bridge`) so an automated player
  and the test kit can inspect what was built
- Decides what such a player would do (`pw_player_bot`): bounded memory, beliefs,
  needs, goals and routes — written down as an intent, never executed
- Plans settlement candidates (farms, hamlets, villages) per region
- Places 5 structure types: farmstead, two house variants, barn, well
- Generates village layouts: main street, plots, building assignment
- Builds local roads between village and farm
- All placement is deterministic from world seed — same seed, same world

## What It Doesn't Do (Yet)

- Errands. PW Bot has a body now: it walks a course, climbs stairs and opens
  doors, gates and trapdoors through a real client. What it has no goal for is
  going somewhere *in order to do something* — see
  [docs/pw-bot/](docs/pw-bot/README.md)
- NPCs, villagers, economy
- Roads between settlements
- Bridges or tunnels
- Global route network
- Interior decoration beyond minimal
- Save migration between versions

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
# Setup
cp secrets/pwbot.password.example secrets/pwbot.password  # edit password

# Test mode
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d

# Start test client
./scripts/run-test-client.sh

# Grant privileges
docker exec perfectworld-dev sh -c 'echo "/grant pwbot all" > /proc/1/fd/0'

# Tests auto-run when pwbot connects, or manually:
echo '{"command":"runchat","chatcmd":"pw_test_all","player":"pwbot"}' \
  > data/worlds/perfectworld/rc_cmd.json

# Results
ls -t data/worlds/perfectworld/ltk_report_*.json | head -1
```

Current: **310 total | 308 PASS | 2 FAIL | 0 SKIP | 0 ERROR**

The two failures are a configuration contradiction, not a regression: two
`pw_bot_bridge` tests require `external_transport` to be off by default, while
`config/luanti.conf` turns it on for `pw_bot_runtime`. See
[docs/status.md](docs/status.md).

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
│   │   ├── pw_core/              # API, version, world format lock
│   │   ├── pw_compat_mcl/        # Mineclonia material mappings
│   │   ├── pw_planner/           # Region planning, materialization
│   │   ├── pw_structures/        # Structure registry, placement
│   │   ├── pw_roads/             # Road network API
│   │   ├── pw_settlements/       # Settlement types (skeleton)
│   │   ├── pw_population/        # Population (skeleton)
│   │   ├── pw_debug/             # Chat commands, screenshots
│   │   ├── pw_bot_bridge/        # Server-side perception for the future PW Bot
│   │   ├── pw_player_bot/        # The bot's decision layer: memory, needs, goals, intents
│   │   └── pw_tests/             # TestKit-based tests
│   ├── luanti_testkit/           # Universal test framework
│   └── pw_remote_control/        # JSON remote controller
├── scripts/                      # Build, install, test utilities
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
| [docs/status.md](docs/status.md) | Current state, known issues |
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
