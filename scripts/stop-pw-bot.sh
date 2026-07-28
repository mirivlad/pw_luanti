#!/usr/bin/env bash
# stop-pw-bot.sh — stop a running bot, or clean up after one that crashed.
#
# The ordinary path asks the run to stop, which releases every held key, ends
# the current intent as `operator_stopped`, and writes the report. The --force
# path is for when a runtime died without cleaning up: it kills the client and
# any display the runtime left behind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PW_BOT_CONFIG:-$ROOT/runtime/pwbot.toml}"
PYTHON="${PYTHON:-python3}"
RUN_ID=""
FORCE=0

usage() {
    cat <<'USAGE'
Usage: scripts/stop-pw-bot.sh [--run-id ID] [--force] [--config FILE]

  --run-id ID   stop that run (default: the newest one with no result yet)
  --force       kill the client and any leftover Xvfb/Xephyr display
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

export PYTHONPATH="$ROOT/tools/pw_bot_runtime/src${PYTHONPATH:+:$PYTHONPATH}"
cd "$ROOT"

ARTIFACTS="$ROOT/runtime/pw-bot-artifacts"

if [ -z "$RUN_ID" ] && [ -d "$ARTIFACTS" ]; then
    # The newest run that has not written a verdict is the one still going.
    for candidate in $(ls -1t "$ARTIFACTS" 2>/dev/null); do
        if [ -d "$ARTIFACTS/$candidate" ] && [ ! -f "$ARTIFACTS/$candidate/result.json" ]; then
            RUN_ID="$candidate"
            break
        fi
    done
fi

if [ -n "$RUN_ID" ]; then
    echo "asking run $RUN_ID to stop"
    "$PYTHON" -m pw_bot_runtime stop --run-id "$RUN_ID" --config "$CONFIG" || true
    for _ in $(seq 1 20); do
        [ -f "$ARTIFACTS/$RUN_ID/result.json" ] && { echo "run finished cleanly"; break; }
        sleep 1
    done
else
    echo "no run appears to be in progress"
fi

if [ "$FORCE" = "1" ]; then
    echo "force: killing any client and runtime-owned display"
    pkill -f "luanti --go" 2>/dev/null || true
    sleep 1
    pkill -9 -f "luanti --go" 2>/dev/null || true
    # Only displays in the range the runtime allocates from.
    for number in $(seq 90 120); do
        pkill -f "Xvfb :$number" 2>/dev/null || true
        pkill -f "Xephyr :$number" 2>/dev/null || true
    done
    pkill -f "ffplay .*x11grab" 2>/dev/null || true
    echo "done"
fi
