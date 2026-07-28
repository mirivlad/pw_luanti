#!/usr/bin/env bash
# run-pw-bot-visible.sh — run PW Bot where a human can watch it.
#
# The client runs on an isolated Xvfb display mirrored into an ffplay window.
# The mirror is deliberately read-only: moving the host cursor over it cannot
# change the bot's camera, while the runtime's XTest input still reaches the
# isolated client. Set PW_BOT_VISIBLE_BACKEND=xephyr explicitly only when an
# interactive, lower-latency view is worth accepting host pointer input.
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

The window is read-only by default. To restore the interactive Xephyr backend:
  PW_BOT_VISIBLE_BACKEND=xephyr scripts/run-pw-bot-visible.sh ...

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
export PW_BOT_VISIBLE_BACKEND="${PW_BOT_VISIBLE_BACKEND:-mirror}"
cd "$ROOT"
exec "$PYTHON" -m pw_bot_runtime run --visible --config "$CONFIG" "${ARGS[@]}"
