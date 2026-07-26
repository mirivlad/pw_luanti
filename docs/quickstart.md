# Quick Start

## Clone

```bash
git clone git@github.com:mirivlad/pw_luanti.git
cd pw_luanti
```

## Install Content

```bash
python3 scripts/install-content.py
```

Downloads Mineclonia, mcl_decor, mcl_cozy to `data/`. Versions are pinned in
`locks/content.lock.json`.

## Create Secrets

```bash
cp secrets/pwbot.password.example secrets/pwbot.password
# Edit the file with a password
```

## Build

```bash
docker compose build
```

First build takes several minutes (compiles Luanti from source).

## Start Server

```bash
docker compose up -d
```

Wait for the server:

```bash
timeout 90 sh -c 'while :; do
  grep -q "Server for gameid=.*listening" data/debug.txt && exit 0
  sleep 2
done' && echo "Server ready"
```

## Connect

- **Address:** `127.0.0.1`
- **Port:** `30000`
- **Game:** Mineclonia
- **Luanti version:** 5.16.1

Create an account by connecting with any client and choosing a name/password.

For admin access, grant privileges in the server console:

```bash
docker attach perfectworld-dev
/grant yourname all
# Press Ctrl+P, Ctrl+Q to detach
```

## Stop

```bash
docker compose down
```

## Restart

```bash
docker compose up -d
```

World data persists in `data/worlds/perfectworld/`.

## Next Steps

- Run tests: see `docs/testing.md`
- Player commands: see `docs/player-guide.md`
- Development: see `docs/development.md`
