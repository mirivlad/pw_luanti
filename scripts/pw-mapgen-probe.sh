#!/usr/bin/env bash
# pw-mapgen-probe.sh — how much of the planned world actually gets built?
#
# Every other check in this repo asks the planner to build a settlement and then
# grades what it built. That measures the builder. It does not measure the
# world: a player who flew across this world for half an hour met two buildings,
# while the acceptance run of the same week reported a hundred and sixty-two
# lots standing. Both numbers were true. They answer different questions.
#
# This script asks the player's question. It generates the ground under planned
# candidates the way arriving there would, and reports what the mapgen hook made
# of each one on its own.
#
# No client is started. The remote-control mod runs a chat command by calling
# its function with a player *name*, not a player object, so a measurement that
# never touches a player object needs nobody logged in — and an unattended
# script has no business killing whatever client is running, which on a
# developer's machine is usually the developer.
#
# Usage: scripts/pw-mapgen-probe.sh [--count N] [--radius R] [--inner I]
#
#   --inner   skip the innermost I regions. A world that has been played in has
#             settlements standing in it already, and a candidate that is
#             already built measures nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDPATH="$ROOT/data/worlds/perfectworld"
OUT_DIR="${OUT_DIR:-$ROOT/logs/mapgen}"

COUNT=24
RADIUS=8
INNER=0
while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift ;;
        --radius) RADIUS="$2"; shift ;;
        --inner) INNER="$2"; shift ;;
        --count=*) COUNT="${1#*=}" ;;
        --radius=*) RADIUS="${1#*=}" ;;
        --inner=*) INNER="${1#*=}" ;;
    esac
    shift
done

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT_DIR/mapgen_$STAMP.json"

log() { echo "[mapgen-probe $(date '+%H:%M:%S')] $*"; }

fail() {
    log "FAILED: $*"
    echo "--- server log (tail) ---"
    docker logs perfectworld-dev --tail 25 2>&1 || true
    exit 1
}

# `grep -q` on a docker-logs pipe is a trap: grep exits at the first match, the
# still-writing `docker logs` takes SIGPIPE, and under `pipefail` the whole
# pipeline reports failure however many matches there were. It fails more often
# the longer the log gets, which is to say it starts working and then stops.
# Counting reads the stream to the end and cannot do that.
seen() { docker logs perfectworld-dev 2>&1 | grep -c "$1" || true; }

docker ps --format '{{.Names}}' | grep -qx perfectworld-dev || fail "the server is not running"
[ "$(seen "listening on")" -gt 0 ] || fail "the server never reported that it is listening"

rc() {
    printf '{"command":"runchat","chatcmd":"%s","params":"%s","player":"%s","nonce":"%s"}' \
        "$1" "$2" "${LTK_USER:-pwbot}" "$(date +%s%N)" > "$WORLDPATH/rc_cmd.json"
    sleep "${3:-6}"
}

# Anchor to this run: the report line is counted before the probe starts and
# waited on to increase, so a report left in the log by an earlier run cannot be
# mistaken for this one.
reports_before="$(seen "pw_mapgen_probe: ")"

log "planned density"
rc pw_settlement_density "12" 8
docker logs perfectworld-dev 2>&1 | grep -oE "[0-9]+ regions, [0-9]+ settlements.*" | tail -1 || true

log "walking to $COUNT candidates between region $INNER and $RADIUS"
rc pw_mapgen_probe "$COUNT $RADIUS $INNER" 6

# Each candidate is an emerge plus a settle; a town gets forty seconds of it.
done_=0
for _ in $(seq 1 $((COUNT * 12 + 60))); do
    now="$(seen "pw_mapgen_probe: ")"
    if [ "$now" -gt "$reports_before" ]; then done_=1; break; fi
    sleep 10
done
[ "$done_" = "1" ] || fail "the probe never finished"

docker logs perfectworld-dev 2>&1 | grep -oE "pw_mapgen_probe: .*" | tail -1

latest="$(ls -t "$WORLDPATH"/pw_mapgen_probe_*.json 2>/dev/null | head -1 || true)"
[ -n "$latest" ] || fail "the report was not written"
cp "$latest" "$REPORT"
log "report: $REPORT"

python3 "$ROOT/scripts/mapgen-report.py" "$REPORT"
