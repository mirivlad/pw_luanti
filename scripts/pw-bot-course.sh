#!/usr/bin/env bash
# pw-bot-course.sh — build, inspect or remove the PW Bot obstacle course.
#
# The course commands are ordinary admin chatcommands, and pw_remote_control
# runs a chatcommand *as a player*, so one has to be connected. This brings a
# short-lived client up on a scratch display, issues the command, and takes the
# client away again — which also frees the player name for the bot's own client.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLD="$ROOT/data/worlds/perfectworld"
PLAYER="${PW_BOT_PLAYER:-pwbot}"
DISPLAY_NUMBER="${PW_COURSE_DISPLAY:-121}"
ACTION="${1:-info}"

case "$ACTION" in
    build|remove|info|start|door) ;;
    *) echo "Usage: scripts/pw-bot-course.sh <build|remove|info|start|door>" >&2; exit 2 ;;
esac

say() { echo "[course $(date +%T)] $*"; }

cleanup() {
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null || true
    sleep 2
    [ -n "${CLIENT_PID:-}" ] && kill -9 "$CLIENT_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# A client already connected as this player is one we must not fight with.
#
# "The log mentions a join" is not evidence that a client is connected now — it
# is evidence that one connected at some point, which after a previous run is
# exactly the wrong conclusion. Only a live process counts, and even then the
# command is verified below rather than assumed to have run.
if pgrep -f "luanti[ ]--go" >/dev/null 2>&1; then
    say "a client process is already running; using it"
    REUSE=1
else
    REUSE=0
    JOINS_BEFORE="$(docker logs perfectworld-dev 2>&1 | grep -c "$PLAYER.*joins game" || true)"
    say "starting a scratch client on :$DISPLAY_NUMBER"
    Xvfb ":$DISPLAY_NUMBER" -screen 0 640x480x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 2
    mkdir -p "$ROOT/logs"
    DISPLAY=":$DISPLAY_NUMBER" /usr/games/luanti --go \
        --address 127.0.0.1 --port 30000 --name "$PLAYER" \
        --password-file "$ROOT/secrets/pwbot.password" \
        > "$ROOT/logs/pw-bot-course-client.log" 2>&1 &
    CLIENT_PID=$!
    # Wait for *a new* join, not for the log to mention one. `--since` compares
    # against the container clock, which is not the host clock, so a stale entry
    # from a previous run reads as success and the command then runs with
    # nobody connected. Counting is immune to both problems.
    JOINED=0
    for _ in $(seq 1 60); do
        NOW="$(docker logs perfectworld-dev 2>&1 | grep -c "$PLAYER.*joins game" || true)"
        if [ "${NOW:-0}" -gt "${JOINS_BEFORE:-0}" ]; then
            JOINED=1; break
        fi
        kill -0 "$CLIENT_PID" 2>/dev/null || break
        sleep 1
    done
    [ "$JOINED" = "1" ] || { say "the scratch client never joined"; exit 1; }
    sleep 3
    docker exec perfectworld-dev sh -c "echo \"/grant $PLAYER all\" > /proc/1/fd/0" >/dev/null 2>&1
    sleep 1
fi

say "running /pw_bot_course $ACTION"
# The nonce matters. pw_remote_control skips a command byte-identical to the
# previous one, so running `start` twice in a row would silently do nothing the
# second time — and the scenario would begin from wherever the bot was left.
printf '{"command":"runchat","chatcmd":"pw_bot_course","params":"%s %s","player":"%s","nonce":"%s"}' \
    "$ACTION" "$PLAYER" "$PLAYER" "$(date +%s%N)" > "$WORLD/rc_cmd.json"

# Poll rather than sleep a fixed amount: restoring the course is a whole-region
# VoxelManip write and takes several seconds, and a fixed wait either reports a
# false failure or wastes time on every other command.
OUTPUT=""
for _ in $(seq 1 20); do
    sleep 1
    OUTPUT="$(docker logs perfectworld-dev --since 40s 2>&1 | grep -i "pw_rc.*pw_bot_course" | tail -1 || true)"
    [ -n "$OUTPUT" ] && break
done

# Silence here means the command never ran — usually because no player was
# connected to run it as. Failing loudly beats a scenario that starts from
# wherever the bot happened to be left standing.
if [ -z "$OUTPUT" ]; then
    say "ERROR: the server never reported running /pw_bot_course $ACTION"
    exit 1
fi
echo "$OUTPUT"
if echo "$OUTPUT" | grep -q "=> false"; then
    say "ERROR: the command was refused"
    exit 1
fi

if [ "$ACTION" = "build" ] && [ -f "$WORLD/pw_bot_course.json" ]; then
    python3 - "$WORLD/pw_bot_course.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
o = d["origin"]
print(f"  origin ({o['x']}, {o['y']}, {o['z']})")
for key in ("start", "corner", "step_up", "stairs_top", "door", "room_centre",
            "room_exit", "too_high", "low_beam", "pit", "water", "dead_end"):
    spot = d["landmarks"].get(key)
    if spot:
        print(f"  {key:<12} ({spot['x']}, {spot['y']}, {spot['z']})")
PY
fi

if [ "$REUSE" = "0" ]; then
    say "releasing the scratch client"
fi
