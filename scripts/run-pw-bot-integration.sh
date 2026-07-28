#!/usr/bin/env bash
# run-pw-bot-integration.sh — the full PW Bot vertical, from a cold server.
#
#   server up
#   -> a real client connects as the test player
#   -> the obstacle course is built
#   -> the bot is placed at the start line (the last time anything teleports it)
#   -> the brain observes, decides and publishes intents
#   -> the runtime walks, turns, jumps and opens doors with client input
#   -> results go back to the brain
#   -> the run is checked against what the artifacts actually recorded
#
# Nothing after the start line moves the player except keyboard and pointer
# input. If the bot got somewhere, it walked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PW_BOT_CONFIG:-$ROOT/runtime/pwbot.toml}"
PYTHON="${PYTHON:-python3}"
WORLD="$ROOT/data/worlds/perfectworld"
PLAYER="${PW_BOT_PLAYER:-pwbot}"
VISIBLE=0
KEEP_COURSE=0
MAX_SECONDS="${PW_BOT_MAX_SECONDS:-150}"
COURSE=1

usage() {
    cat <<'USAGE'
Usage: scripts/run-pw-bot-integration.sh [options]

  --visible         watch the run in a window instead of headless
  --no-course       run in the generated world instead of the obstacle course
  --keep-course     leave the course standing afterwards
  --max-seconds N   how long to let the bot run (default 150)
  --config FILE     runtime config (default runtime/pwbot.toml)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --visible) VISIBLE=1; shift ;;
        --no-course) COURSE=0; shift ;;
        --keep-course) KEEP_COURSE=1; shift ;;
        --max-seconds) MAX_SECONDS="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

say() { echo "[pw-bot-integration $(date +%T)] $*"; }

rc() {
    printf '%s' "$1" > "$WORLD/rc_cmd.json"
    sleep 1.5
}

say "1. making sure the server is up"
if ! docker ps --format '{{.Names}}' | grep -q '^perfectworld-dev$'; then
    docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.test.yml" up -d
    timeout 180 sh -c 'while :; do grep -q "Server for gameid=.*listening" '"$ROOT"'/data/debug-test.txt && exit 0; sleep 2; done'
fi
say "   server is running"

say "2. clearing any stale client"
pkill -f "luanti --go" 2>/dev/null || true
sleep 3

say "3. environment check"
export PYTHONPATH="$ROOT/tools/pw_bot_runtime/src${PYTHONPATH:+:$PYTHONPATH}"
cd "$ROOT"
DOCTOR_FLAGS=()
[ "$VISIBLE" = "1" ] && DOCTOR_FLAGS+=(--visible)
"$PYTHON" -m pw_bot_runtime doctor --config "$CONFIG" "${DOCTOR_FLAGS[@]}" >/dev/null || {
    say "   doctor is not happy; run it yourself to see why"
    "$PYTHON" -m pw_bot_runtime doctor --config "$CONFIG" "${DOCTOR_FLAGS[@]}"
    exit 2
}
say "   environment is ready"

# The course and the start line need a connected player, and only the bot's own
# client provides one. Bring a client up briefly to do the setup, then let the
# runtime start its own.
if [ "$COURSE" = "1" ]; then
    say "4. bringing a client up so the course can be built"
    SETUP_DISPLAY=":121"
    Xvfb "$SETUP_DISPLAY" -screen 0 640x480x24 -nolisten tcp >/dev/null 2>&1 &
    SETUP_XVFB=$!
    sleep 2
    DISPLAY="$SETUP_DISPLAY" /usr/games/luanti --go \
        --address 127.0.0.1 --port 30000 --name "$PLAYER" \
        --password-file "$ROOT/secrets/pwbot.password" \
        > "$ROOT/logs/pw-bot-setup-client.log" 2>&1 &
    SETUP_CLIENT=$!
    for _ in $(seq 1 60); do
        docker logs perfectworld-dev --since 90s 2>&1 | grep -q "$PLAYER.*joins game" && break
        sleep 1
    done
    sleep 3

    docker exec perfectworld-dev sh -c "echo \"/grant $PLAYER all\" > /proc/1/fd/0" >/dev/null 2>&1
    sleep 1

    say "5. building the obstacle course"
    rc "{\"command\":\"runchat\",\"chatcmd\":\"pw_bot_course\",\"params\":\"build $PLAYER\",\"player\":\"$PLAYER\"}"
    sleep 2
    rc "{\"command\":\"runchat\",\"chatcmd\":\"pw_bot_course\",\"params\":\"start $PLAYER\",\"player\":\"$PLAYER\"}"
    sleep 1
    if [ -f "$WORLD/pw_bot_course.json" ]; then
        say "   course: $(python3 -c "import json;d=json.load(open('$WORLD/pw_bot_course.json'));o=d['origin'];print('origin (%d, %d, %d)'%(o['x'],o['y'],o['z']))")"
    else
        say "   WARNING: the course did not report landmarks"
    fi

    say "6. forgetting what the bot remembered elsewhere"
    rc "{\"command\":\"runchat\",\"chatcmd\":\"pw_player_bot_memory\",\"params\":\"$PLAYER forget\",\"player\":\"$PLAYER\"}"

    say "7. releasing the setup client"
    kill "$SETUP_CLIENT" 2>/dev/null || true
    sleep 4
    kill "$SETUP_XVFB" 2>/dev/null || true
    # The server needs a moment to notice the name is free again.
    sleep 6
fi

say "8. running the bot"
RUN_FLAGS=(--config "$CONFIG" --max-seconds "$MAX_SECONDS")
if [ "$VISIBLE" = "1" ]; then
    RUN_FLAGS+=(--visible)
else
    RUN_FLAGS+=(--headless)
fi
set +e
"$PYTHON" -m pw_bot_runtime run "${RUN_FLAGS[@]}"
RUN_STATUS=$?
set -e

RUN_ID="$(ls -1t "$ROOT/runtime/pw-bot-artifacts" | head -1)"
say "9. checking what actually happened (run $RUN_ID)"
"$PYTHON" "$ROOT/scripts/check-pw-bot-run.py" \
    --run "$ROOT/runtime/pw-bot-artifacts/$RUN_ID" \
    ${COURSE:+--course "$WORLD/pw_bot_course.json"}
CHECK_STATUS=$?

if [ "$COURSE" = "1" ] && [ "$KEEP_COURSE" != "1" ]; then
    say "10. taking the course back down"
    pkill -f "luanti --go" 2>/dev/null || true
    sleep 3
    Xvfb ":122" -screen 0 640x480x24 -nolisten tcp >/dev/null 2>&1 &
    CLEAN_XVFB=$!
    sleep 2
    DISPLAY=":122" /usr/games/luanti --go --address 127.0.0.1 --port 30000 \
        --name "$PLAYER" --password-file "$ROOT/secrets/pwbot.password" \
        > /dev/null 2>&1 &
    CLEAN_CLIENT=$!
    for _ in $(seq 1 60); do
        docker logs perfectworld-dev --since 90s 2>&1 | grep -q "$PLAYER.*joins game" && break
        sleep 1
    done
    sleep 3
    rc "{\"command\":\"runchat\",\"chatcmd\":\"pw_bot_course\",\"params\":\"remove\",\"player\":\"$PLAYER\"}"
    kill "$CLEAN_CLIENT" 2>/dev/null || true
    sleep 2
    kill "$CLEAN_XVFB" 2>/dev/null || true
    say "    course removed"
fi

say "done: run exit $RUN_STATUS, checks exit $CHECK_STATUS"
exit "$CHECK_STATUS"
