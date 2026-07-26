# PerfectWorld

Procedural physical world generation for [Luanti](https://www.luanti.org/) with [Mineclonia](https://content.luanti.org/packages/ryvnf/mineclonia/).

PerfectWorld builds the physical shape of a living world: regions, settlements,
buildings, roads, and farms — placed deterministically through mapgen
integration.

## Current State

- Deterministic regional planner (1024×1024 regions)
- 5 registered structure types (farmstead, houses, barn, well)
- Village layout generator (street, plots, building assignment)
- Structure placement pipeline with terrain analysis, preparation, and rollback
- Farm placement with multi-phase location search
- Simple road builder between village and farm
- World format lock preventing silent corruption on config changes
- 45 tests via Luanti TestKit

## Requirements

- Docker + Docker Compose
- Python 3 for `scripts/install-content.py`
- Port `30000/udp` available

## Quick Start

```bash
# Install Mineclonia content
./scripts/install-content.py

# Sync local mods
./scripts/sync-local-mods.sh

# Build Docker image
./scripts/build-image.sh

# Start server
docker compose up -d
```

## Running Tests

```bash
# Start test client (requires Xvfb for headless)
./scripts/run-test-client.sh

# Run tests via remote controller
echo '{"command":"runchat","chatcmd":"pw_test_all","player":"pwbot"}' > data/worlds/perfectworld/rc_cmd.json
```

## Project Structure

```
PerfectWorld/
├── Dockerfile
├── docker-compose.yml
├── docker-compose.test.yml
├── config/
│   ├── luanti.conf
│   └── world.mt.example
├── docs/
│   └── perfectworld-architecture.md
├── local_mods/
│   ├── perfectworld/        # PerfectWorld modpack
│   │   ├── pw_core/
│   │   ├── pw_compat_mcl/
│   │   ├── pw_planner/
│   │   ├── pw_structures/
│   │   ├── pw_roads/
│   │   ├── pw_settlements/
│   │   ├── pw_population/
│   │   ├── pw_debug/
│   │   └── pw_tests/
│   ├── luanti_testkit/      # Universal test framework
│   └── pw_remote_control/   # JSON remote controller
└── scripts/
    ├── build-image.sh
    ├── install-content.py
    ├── sync-local-mods.sh
    ├── run-test-client.sh
    ├── run-test-ui.sh
    └── smoke-test.sh
```

## Limitations

- Roads between settlements are simple straight lines
- Bridges are not implemented
- Population is a skeleton only
- No global route pathfinding
- Terrain adaptation uses flat terrace, not slope-following
- Building interiors are minimal
