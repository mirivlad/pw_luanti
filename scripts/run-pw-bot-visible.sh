#!/usr/bin/env bash
# run-pw-bot-visible.sh — run PW Bot where a human can watch it.
#
# The client runs inside a nested X server (Xephyr) shown as a window on your
# desktop. You see everything the bot does in real time, and the bot's keyboard
# and pointer never leave that nested display: your own windows are not in
# reach, and your mouse pointer does not move.
#
# If Xephyr is not installed, the runtime falls back to an Xvfb display mirrored
# into a read-only ffplay window. That is stricter still — the mirror forwards
# nothing — but the picture lags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PW_BOT_CONFIG:-$ROOT/runtime/pwbot.toml}"
PYTHON="${PYTHON:-python3}"

usage() {
    cat <<'USAGE'
Usage: scripts/run-pw-bot-visible.sh [--config FILE] [runtime options...]

Runs the bot in a window you can watch. Useful additions:
  --keep-open        leave the client running afterwards so you can look around
  --max-intents N    stop after N intents
  --max-seconds N    stop after N seconds

While it runs, from another terminal:
  python3 -m pw_bot_runtime pause  --run-id <id>
  python3 -m pw_bot_runtime resume --run-id <id>
  python3 -m pw_bot_runtime stop   --run-id <id>
USAGE
}

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: no config at $CONFIG" >&2
    echo "Create one:  cp tools/pw_bot_runtime/config.example.toml $CONFIG" >&2
    exit 2
fi

if [ -z "${DISPLAY:-}" ]; then
    echo "ERROR: DISPLAY is not set, so there is no desktop to show the bot on." >&2
    echo "Visible mode needs a graphical session; use scripts/run-pw-bot.sh instead." >&2
    exit 2
fi

export PYTHONPATH="$ROOT/tools/pw_bot_runtime/src${PYTHONPATH:+:$PYTHONPATH}"
cd "$ROOT"
exec "$PYTHON" -m pw_bot_runtime run --visible --config "$CONFIG" "${ARGS[@]}"
