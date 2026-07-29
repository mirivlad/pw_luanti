#!/usr/bin/env bash
# pw-accessibility-check.sh — can every door in a settlement be walked to?
#
# Builds a sample of settlements on a world and reports, per settlement, how
# many of its doors have no walkable route from the street. Writes a machine
# readable report and prints a summary table.
#
# Why this exists rather than a handful of manual commands: three earlier
# attempts to measure this ended with "client never connected" and no data. The
# cause was not the client, which joins in about three seconds — it was that
# nothing waited for the *server* to finish starting, so the client was launched
# at a socket that was not listening yet, failed quietly, and sat there while a
# fixed-length poll ran out. Detection is now anchored to this run: the number
# of "joins game" lines in the server log is counted before the client starts
# and waited on to increase, so a join left over from an earlier run cannot be
# mistaken for this one.
#
# Usage:
#   scripts/pw-accessibility-check.sh [--fresh] [--count N] [--radius R]
#
#   --fresh    regenerate the world before building (recommended: old
#              settlements are already materialized and would be counted
#              without ever exercising the code under test)
#   --count    how many settlements to ask for (default 26)
#   --radius   how many regions out to look (default 20)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDPATH="$ROOT/data/worlds/perfectworld"
OUT_DIR="${OUT_DIR:-$ROOT/logs/accessibility}"
CLIENT_LOG="$ROOT/logs/accessibility-client.log"
DISPLAY_NUM="${DISPLAY_NUM:-71}"
LTK_USER="${LTK_USER:-pwbot}"
PASSWORD_FILE="${PASSWORD_FILE:-$ROOT/secrets/pwbot.password}"
LUANTI_CLIENT="${LUANTI_CLIENT:-/usr/games/luanti}"

COUNT=26
RADIUS=20
FRESH=0
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --count=*) COUNT="${arg#*=}" ;;
        --radius=*) RADIUS="${arg#*=}" ;;
    esac
done
# `--count N` and `--radius R` as separate words too.
while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift ;;
        --radius) RADIUS="$2"; shift ;;
    esac
    shift || true
done

mkdir -p "$OUT_DIR" "$ROOT/logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT_DIR/accessibility_$STAMP.json"

XVFB_PID=""
CLIENT_PID=""

log() { echo "[accessibility $(date '+%H:%M:%S')] $*"; }

compose() { docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.test.yml" "$@"; }

cleanup() {
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
    sleep 1
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    log "FAILED: $*"
    echo "--- server log (tail) ---"
    docker logs perfectworld-dev --tail 25 2>&1 || true
    echo "--- client log (tail) ---"
    tail -25 "$CLIENT_LOG" 2>/dev/null || echo "(no client log)"
    exit 1
}

# --- the world -------------------------------------------------------------

if [ "$FRESH" = "1" ]; then
    log "regenerating the world"
    compose down >/dev/null 2>&1 || true
    pkill -x luanti 2>/dev/null || true
    sleep 3
    python3 - "$WORLDPATH" <<'PY'
import os, random, re, shutil, sys
world = sys.argv[1]
mt = open(os.path.join(world, "world.mt")).read()
shutil.rmtree(world)
os.makedirs(world)
seed = str(random.SystemRandom().randrange(10**17, 10**18))
mt = re.sub(r'^seed = .*$', 'seed = ' + seed, mt, flags=re.M)
mt = re.sub(r'^fixed_map_seed = .*$', 'fixed_map_seed = ' + seed, mt, flags=re.M)
open(os.path.join(world, "world.mt"), "w").write(mt)
print(seed)
PY
fi

# --- the server ------------------------------------------------------------

log "starting the server"
compose up -d >/dev/null 2>&1

# Wait for the server to say it is listening, and give it a moment to finish
# registering mods. Skipping this is what made three earlier runs report a
# client that "never connected": the socket was not open yet.
ready=0
for _ in $(seq 1 120); do
    if docker logs perfectworld-dev 2>&1 | grep -q "listening on"; then ready=1; break; fi
    sleep 2
done
[ "$ready" = "1" ] || fail "the server never reported that it is listening"
sleep 4
log "server ready"

# --- the client ------------------------------------------------------------

# Any client still running belongs to an earlier run and would be
# indistinguishable from this one in the server log.
pkill -x luanti 2>/dev/null || true
sleep 3
pgrep -x luanti >/dev/null && fail "a client from an earlier run will not die"

# Anchor detection to this run rather than to a time window: count the joins
# already in the log and wait for one more.
joins_before="$(docker logs perfectworld-dev 2>&1 | grep -c "$LTK_USER.*joins game" || true)"

rm -f "/tmp/.X${DISPLAY_NUM}-lock" 2>/dev/null || true
Xvfb ":$DISPLAY_NUM" -screen 0 1280x720x24 -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
sleep 2

log "starting the client on display :$DISPLAY_NUM"
DISPLAY=":$DISPLAY_NUM" "$LUANTI_CLIENT" --go --address 127.0.0.1 --port 30000 \
    --name "$LTK_USER" --password-file "$PASSWORD_FILE" > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

connected=0
for _ in $(seq 1 90); do
    joins_now="$(docker logs perfectworld-dev 2>&1 | grep -c "$LTK_USER.*joins game" || true)"
    if [ "$joins_now" -gt "$joins_before" ]; then connected=1; break; fi
    kill -0 "$CLIENT_PID" 2>/dev/null || fail "the client exited before joining"
    sleep 1
done
[ "$connected" = "1" ] || fail "the client did not join within 90 seconds"
log "client joined"
sleep 3

# --- driving the server ----------------------------------------------------

rc() {
    printf '{"command":"runchat","chatcmd":"%s","params":"%s","player":"%s","nonce":"%s"}' \
        "$1" "$2" "$LTK_USER" "$(date +%s%N)" > "$WORLDPATH/rc_cmd.json"
    sleep "${3:-6}"
    kill -0 "$CLIENT_PID" 2>/dev/null || fail "the client died while running /$1"
}

log "building $COUNT settlements within $RADIUS regions"
rc pw_village_batch "$COUNT $RADIUS" 6
built=0
for _ in $(seq 1 240); do
    if docker logs perfectworld-dev 2>&1 | grep -q "village batch finished"; then built=1; break; fi
    kill -0 "$CLIENT_PID" 2>/dev/null || fail "the client died during the batch"
    sleep 10
done
[ "$built" = "1" ] || fail "the batch never finished"
docker logs perfectworld-dev 2>&1 | grep -oE "village batch finished.*" | tail -1

log "collecting the accessibility report"
rc pw_accessibility_report "" 25

docker logs perfectworld-dev 2>&1 | grep -oE "pw_accessibility_report wrote .*" | tail -1

# The mod writes the report into the world directory; copy it out so a run is
# not lost when the world is regenerated.
latest="$(ls -t "$WORLDPATH"/pw_accessibility_*.json 2>/dev/null | head -1 || true)"
[ -n "$latest" ] || fail "the report was not written"
cp "$latest" "$REPORT"
log "report: $REPORT"

python3 "$ROOT/scripts/accessibility-report.py" "$REPORT"
