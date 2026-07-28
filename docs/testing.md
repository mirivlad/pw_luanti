# Testing

PerfectWorld tests run on a live Luanti server via [Luanti TestKit](../local_mods/luanti_testkit/).

## Architecture

```
TestKit (luanti_testkit)  ←  universal framework
    ↑
pw_tests                  ←  PerfectWorld-specific tests
pw_bot_bridge/tests       ←  bot bridge suite (registers into the same TestKit)
pw_player_bot/tests       ←  bot brain suite (registers into the same TestKit)
    ↑
pwbot (test client)       ←  connects to server, runs chat commands
    ↑
pw_remote_control         ←  reads rc_cmd.json, executes /commands
```

Two suites run in one pass:

| Suite | Covers |
|-------|--------|
| `perfectworld` | core, planner, structures, variation, fingerprints, village, diversity |
| `pw_bot_bridge` | protocol, registry, permissions, perception, semantics, events, transport, scenes A–E, live integration |
| `pw_player_bot` | memory, beliefs, navigation, needs, goals, utility scoring, intent documents, live brain integration |

The bridge suite is documented in detail in
[docs/pw-bot/testing.md](pw-bot/testing.md).

## Setup

### 1. Password

```bash
cp secrets/pwbot.password.example secrets/pwbot.password
# Edit with any password
```

### 2. Start Test Server

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
```

Test mode differs from server mode:
- No `--terminal` (ncurses console)
- Logs go to `data/debug-test.txt`
- Everything else is identical

### 3. Wait for Server

```bash
timeout 90 sh -c 'while :; do
  grep -q "Server for gameid=.*listening" data/debug-test.txt && exit 0
  sleep 2
done' && echo "Ready"
```

### 4. Start Test Client

```bash
./scripts/run-test-client.sh
```

Or manually:

```bash
xvfb-run --auto-servernum luanti --go \
  --address 127.0.0.1 --port 30000 \
  --name pwbot --password-file secrets/pwbot.password \
  >> logs/test-client.log 2>&1 &
```

Wait for connection:

```bash
timeout 30 sh -c 'while :; do
  grep -q "pwbot.*joins game" data/debug-test.txt && exit 0
  sleep 2
done' && echo "pwbot connected"
```

Requires: Luanti client installed (`luanti` or `/usr/games/luanti`), `xvfb-run` for headless mode.

### 5. Grant Privileges

```bash
docker exec perfectworld-dev sh -c 'echo "/grant pwbot all" > /proc/1/fd/0'
```

## Running Tests

### Automatic

`pw_tests` auto-runs all tests when `pwbot` connects (waits up to 30 seconds
for area emerge). No manual command needed.

### Manual — All Tests

```bash
echo '{"command":"runchat","chatcmd":"pw_test_all","player":"pwbot"}' \
  > data/worlds/perfectworld/rc_cmd.json
```

### Manual — Single Suite

```bash
echo '{"command":"runchat","chatcmd":"ltk_suite","params":"perfectworld pwbot","player":"pwbot"}' \
  > data/worlds/perfectworld/rc_cmd.json
```

### Manual — Single Test

```bash
echo '{"command":"runchat","chatcmd":"ltk_run","params":"perfectworld.planner_deterministic pwbot","player":"pwbot"}' \
  > data/worlds/perfectworld/rc_cmd.json
```

### Via Server Console

```bash
docker exec perfectworld-dev sh -c 'echo "/ltk_run perfectworld.planner_deterministic pwbot" > /proc/1/fd/0'
```

## Test Report

After tests complete, find the JSON report:

```bash
ls -t data/worlds/perfectworld/ltk_report_*.json | head -1
```

Parse summary:

```bash
python3 -c "
import json, glob
reports = sorted(glob.glob('data/worlds/perfectworld/ltk_report_*.json'))
with open(reports[-1]) as f:
    r = json.load(f)
print(f\"{r['summary']['total']} total | {r['summary']['passed']} PASS | {r['summary']['failed']} FAIL | {r['summary']['skipped']} SKIP | {r['summary']['errors']} ERROR\")
for t in r['results']:
    if t['status'] != 'PASS':
        print(f\"  {t['status']} | {t['suite']}.{t['name']}: {t['message']}\")
"
```

### Status Meanings

| Status | Meaning |
|--------|---------|
| PASS | Test passed |
| FAIL | Assertion failed — investigate |
| SKIP | Test skipped (missing dependency, player offline, area not emerged) |
| ERROR | Unhandled Lua error — bug in test or tested code |

## Clean Test Run

To run tests without affecting an existing world, use a separate world
directory. The default `data/worlds/perfectworld/` is for development.

### Current Baseline

310 total | 308 PASS | 2 FAIL | 0 SKIP | 0 ERROR

149 in `perfectworld`, 4 in `player`, 89 in `pw_bot_bridge`, 62 in
`pw_player_bot`, 6 in `smoke`.

The two failures are a configuration contradiction rather than a regression:
`pw_bot_bridge.integration_transport_follows_its_setting` and
`transport_is_off_by_default_and_needs_no_insecure_environment` both require
`pw_bot_bridge.external_transport` to be off, while `config/luanti.conf` turns
it on so `pw_bot_runtime` can reach the spool.

The baseline must stay green. See `docs/status.md` for the current state and
`python3 scripts/report-summary.py <report.json>` to print a summary.

## Stop Environment

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml down
```

## Troubleshooting Tests

| Problem | Check |
|---------|-------|
| `pwbot` not connecting | `grep "pwbot.*joins game" data/debug-test.txt` |
| Player tests SKIP | pwbot may have disconnected; restart client |
| `rc_cmd.json` not processed | File already processed (cached); delete and rewrite with different content |
| No `ltk_report` | Check `grep "luanti_testkit.*Summary" data/debug-test.txt` |
| `ERROR` in log | Check for `ModError\|LuaError\|traceback` in debug log |
| Tests timeout | Increase timeout for large world operations (materialize_chunk tests) |
