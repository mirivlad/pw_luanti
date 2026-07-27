#!/usr/bin/env bash
# run-testkit.sh
# End-to-end TestKit cycle: start test server, connect pwbot, run all tests,
# print the JSON report summary.
#
# Usage:
#   scripts/run-testkit.sh              # restart server, run everything
#   scripts/run-testkit.sh --keep       # reuse a running server
#   scripts/run-testkit.sh --no-client  # do not (re)start pwbot
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDPATH="$ROOT/data/worlds/perfectworld"
DEBUG_LOG="$ROOT/data/debug-test.txt"
CLIENT_LOG="$ROOT/logs/test-client.log"
PID_FILE="$ROOT/run/pwbot.pid"

LUANTI_CLIENT="${LUANTI_CLIENT:-luanti}"
LTK_USER="${LTK_USER:-pwbot}"
LTK_PASSWORD_FILE="${LTK_PASSWORD_FILE:-$ROOT/secrets/pwbot.password}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-180}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-120}"
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"

KEEP_SERVER=0
START_CLIENT=1
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP_SERVER=1 ;;
    --no-client) START_CLIENT=0 ;;
  esac
done

mkdir -p "$ROOT/run" "$ROOT/logs"

log() { echo "[run-testkit $(date '+%H:%M:%S')] $*"; }

compose() { docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.test.yml" "$@"; }

stop_client() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 -- -"$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
}

if [ "$KEEP_SERVER" = "0" ]; then
  log "stopping client and server"
  stop_client
  compose down >/dev/null 2>&1 || true
  rm -f "$DEBUG_LOG"
  log "starting test server"
  compose up -d >/dev/null
fi

log "waiting for server (timeout ${SERVER_TIMEOUT}s)"
timeout "$SERVER_TIMEOUT" sh -c "while :; do grep -q 'Server for gameid=.*listening' '$DEBUG_LOG' 2>/dev/null && exit 0; sleep 2; done" \
  || { log "ERROR: server did not become ready"; tail -30 "$DEBUG_LOG" 2>/dev/null; exit 1; }
log "server ready"

if [ "$START_CLIENT" = "1" ]; then
  stop_client
  log "starting pwbot client on display :$DISPLAY_NUM"
  setsid xvfb-run --auto-servernum --server-num="$DISPLAY_NUM" \
    "$LUANTI_CLIENT" --go --address 127.0.0.1 --port 30000 \
    --name "$LTK_USER" --password-file "$LTK_PASSWORD_FILE" \
    >> "$CLIENT_LOG" 2>&1 &
  echo $! > "$PID_FILE"
  log "client PID $(cat "$PID_FILE")"

  timeout "$CLIENT_TIMEOUT" sh -c "while :; do grep -q '$LTK_USER.*joins game' '$DEBUG_LOG' 2>/dev/null && exit 0; sleep 2; done" \
    || { log "ERROR: $LTK_USER did not connect"; tail -30 "$CLIENT_LOG"; exit 1; }
  log "pwbot connected: $(grep -m1 "$LTK_USER.*joins game" "$DEBUG_LOG")"
fi

log "granting privileges"
docker exec perfectworld-dev sh -c "echo '/grant $LTK_USER all' > /proc/1/fd/0" || true
sleep 2

BEFORE=$(ls "$WORLDPATH"/ltk_report_*.json 2>/dev/null | wc -l || true)

log "triggering full test run"
printf '{"command":"runchat","chatcmd":"pw_test_all","player":"%s","nonce":"%s"}' "$LTK_USER" "$(date +%s%N)" \
  > "$WORLDPATH/rc_cmd.json.tmp"
mv "$WORLDPATH/rc_cmd.json.tmp" "$WORLDPATH/rc_cmd.json"

log "waiting for report (timeout ${TEST_TIMEOUT}s)"
timeout "$TEST_TIMEOUT" sh -c "
  while :; do
    n=\$(ls '$WORLDPATH'/ltk_report_*.json 2>/dev/null | wc -l)
    [ \"\$n\" -gt \"$BEFORE\" ] && exit 0
    sleep 3
  done" || { log "ERROR: no new report produced"; exit 1; }

sleep 2
REPORT=$(ls -t "$WORLDPATH"/ltk_report_*.json | head -1)
log "report: $REPORT"
python3 "$ROOT/scripts/report-summary.py" "$REPORT"
