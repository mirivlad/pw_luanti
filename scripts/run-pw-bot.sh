#!/usr/bin/env bash
# run-pw-bot.sh — run PW Bot headless: a real Luanti client on an isolated Xvfb
# display, driven by the intents pw_player_bot publishes.
#
# The server must already be up. Use scripts/run-pw-bot-integration.sh if you
# want the whole thing brought up from cold.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PW_BOT_CONFIG:-$ROOT/runtime/pwbot.toml}"
PYTHON="${PYTHON:-python3}"

usage() {
    cat <<'USAGE'
Usage: scripts/run-pw-bot.sh [--config FILE] [runtime options...]

Runs the bot headless. Anything after --config is passed to the runtime, so
--max-intents, --max-seconds, --keep-open and --run-id all work here.

Examples:
  scripts/run-pw-bot.sh --config runtime/pwbot.toml
  scripts/run-pw-bot.sh --max-intents 5
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

export PYTHONPATH="$ROOT/tools/pw_bot_runtime/src${PYTHONPATH:+:$PYTHONPATH}"
cd "$ROOT"
exec "$PYTHON" -m pw_bot_runtime run --headless --config "$CONFIG" "${ARGS[@]}"
