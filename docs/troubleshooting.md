# Troubleshooting

## Port Already in Use

```bash
ss -tuln | grep 30000
```

Stop any process using port 30000 or change the port in `docker-compose.yml`.

## Docker Daemon Not Available

```bash
docker ps
```

If the command fails, start Docker:

```bash
sudo systemctl start docker
```

## Mineclonia Not Installed

```
ERROR[Main]: Game "mineclonia" not found
```

Run:

```bash
python3 scripts/install-content.py
```

Then restart the server.

## Content Lock Mismatch

```
content.lock.json is stale
```

Delete the lock and reinstall:

```bash
rm locks/content.lock.json
python3 scripts/install-content.py
```

## Server Not Reaching 'listening'

Check for errors:

```bash
grep -i "ERROR\|ModError\|LuaError" data/debug-test.txt
```

Common causes:
- Missing game content (see above)
- Mod dependency error
- World format lock mismatch — delete `data/worlds/perfectworld/mod_storage.sqlite` (WARNING: destroys all mod data)

## Mod Not Loading

Check `data/debug-test.txt` for the mod name:

```bash
grep "pw_" data/debug-test.txt | head -20
```

Ensure `load_mod_pw_* = true` in `data/worlds/perfectworld/world.mt`.

## pwbot Not Connecting

Check client log:

```bash
tail -20 logs/test-client.log
```

Common issues:
- Wrong password — verify `secrets/pwbot.password`
- Port mismatch — default is 30000
- Name collision — another pwbot already connected; wait 60 seconds or kick: `docker exec perfectworld-dev sh -c 'echo "/kick pwbot" > /proc/1/fd/0'`
- Xvfb not installed — `sudo apt install xvfb`
- Luanti client not found — set `LUANTI_CLIENT` env var

## Player Tests Become SKIP

```
SKIP | player.player_online: Player 'pwbot' is not online.
```

pwbot must be connected when tests run. The `pw_tests` auto-run waits for pwbot.
If running tests manually via `rc_cmd.json`, ensure pwbot is connected first:

```bash
grep "pwbot.*joins game" data/debug-test.txt
```

## JSON Report Not Created

Check:

```bash
grep "luanti_testkit.*Summary" data/debug-test.txt
```

If no summary found, tests didn't run. Check:
- `rc_cmd.json` was processed: `grep "pw_rc" data/debug-test.txt`
- Player has privileges: `docker exec perfectworld-dev sh -c 'echo "/grant pwbot all" > /proc/1/fd/0'`
- TestKit is loaded: `grep "luanti_testkit.*loaded" data/debug-test.txt`

## Permission Denied for data/ Files

```bash
sudo chown -R $USER:$USER data/
```

Docker may create files owned by root.

## Need to Rebuild Image

After changing `Dockerfile`:

```bash
docker compose build --no-cache
```

After changing only mod files, restart is enough:

```bash
docker compose restart
```

## Clean Test Environment Only

To reset mod storage without deleting the world:

```bash
rm data/worlds/perfectworld/mod_storage.sqlite
```

To fully reset:

```bash
docker compose down
rm -rf data/worlds/perfectworld/
mkdir -p data/worlds/perfectworld
cp config/world.mt.example data/worlds/perfectworld/world.mt
```

This preserves `data/games/` (Mineclonia) and `data/mods/` (external mods).

## World Format Lock Error

```
[pw_core] materialization disabled: incompatible_world_format:region_size
```

This happens when `region_size` changed after the world was created. Delete the
lock to reset:

```bash
rm data/worlds/perfectworld/mod_storage.sqlite
```

All placed structures and plans will be lost. New ones will be generated.
