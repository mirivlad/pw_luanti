#!/usr/bin/env bash
# run-test-ui.sh
# Host-side UI test manager for PerfectWorld pwbot.
# Orchestrates client lifecycle, screenshot capture, and restart recovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDPATH="$ROOT/data/worlds/perfectworld"
SIGNAL_FILE="$WORLDPATH/pwbot_client.signal"
SCREENSHOT_DIR="$ROOT/artifacts"
DEBUG_LOG="$ROOT/data/debug-test.txt"
CLIENT_LOG="$ROOT/logs/test-ui.log"
PID_FILE="$ROOT/run/pwbot.pid"

mkdir -p "$ROOT/run" "$SCREENSHOT_DIR"

# === Config ===
LUANTI_CLIENT="${LUANTI_CLIENT:-luanti}"
LTK_HOST="${LTK_HOST:-127.0.0.1}"
LTK_PORT="${LTK_PORT:-30000}"
LTK_USER="${LTK_USER:-pwbot}"
LTK_PASSWORD_FILE="${LTK_PASSWORD_FILE:-$ROOT/secrets/pwbot.password}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"

# === Helpers ===

log() {
  echo "[$(date '+%H:%M:%S')] $*" >> "$CLIENT_LOG"
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

find_xauth() {
  local xauth
  xauth=$(ls -t /tmp/xvfb-run.*/Xauthority 2>/dev/null | head -1)
  if [ -z "$xauth" ]; then
    xauth=$(ls /tmp/xvfb-run.*/Xauthority 2>/dev/null | head -1)
  fi
  echo "$xauth"
}

find_display() {
  local xauth display_num
  xauth=$(find_xauth)
  if [ -z "$xauth" ]; then
    echo "$DISPLAY_NUM"
    return
  fi
  display_num=$(ps aux | grep -F "$xauth" | grep -oP 'Xvfb :\K\d+' | head -1)
  echo "${display_num:-$DISPLAY_NUM}"
}

screenshot() {
  local name="${1:-screenshot}"
  local path="$SCREENSHOT_DIR/${name}.png"
  local xauth display
  xauth=$(find_xauth)
  display=$(find_display)
  if [ -z "$xauth" ]; then
    log "WARNING: no xauth found, screenshot may fail"
    return 1
  fi
  if ! DISPLAY=":$display" XAUTHORITY="$xauth" import -window root "$path" 2>/dev/null; then
    log "ERROR: screenshot failed (display :$display, xauth: $xauth)"
    return 1
  fi
  log "screenshot saved: $path ($(du -h "$path" | cut -f1))"
  printf '%s' "$path"
}

rc_command() {
  local cmd="$1"
  local params="${2:-}"
  local player="${3:-$LTK_USER}"
  local json
  json=$(printf '{"command":"runchat","chatcmd":"%s","params":"%s","player":"%s"}' "$cmd" "$params" "$player")
  printf '%s' "$json" > "$SIGNAL_FILE.tmp"
  mv "$SIGNAL_FILE.tmp" "$WORLDPATH/rc_cmd.json"
  log "rc: /$cmd $params as $player"
}

# === Client Management ===

start_client() {
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      log "client already running (PID $old_pid)"
      return 0
    fi
    rm -f "$PID_FILE"
  fi

  log "starting pwbot client (display :$DISPLAY_NUM)"

  rm -f "$SIGNAL_FILE"

  setsid xvfb-run --auto-servernum --server-num="$DISPLAY_NUM" \
    "$LUANTI_CLIENT" \
    --go \
    --address "$LTK_HOST" \
    --port "$LTK_PORT" \
    --name "$LTK_USER" \
    --password-file "$LTK_PASSWORD_FILE" \
    >> "$CLIENT_LOG" 2>&1 &

  local pid=$!
  echo "$pid" > "$PID_FILE"
  log "client PID: $pid"

  sleep 5

  if kill -0 "$pid" 2>/dev/null; then
    log "client started successfully"
    return 0
  else
    log "ERROR: client failed to start"
    return 1
  fi
}

stop_client() {
  local kick_json
  kick_json=$(printf '{"command":"kick","target":"%s","player":"%s"}' "$LTK_USER" "$LTK_USER")
  printf '%s' "$kick_json" > "$WORLDPATH/rc_cmd.json.tmp" 2>/dev/null
  mv "$WORLDPATH/rc_cmd.json.tmp" "$WORLDPATH/rc_cmd.json" 2>/dev/null
  sleep 1

  if [ ! -f "$PID_FILE" ]; then
    log "no PID file found"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  log "stopping client (PID $pid)"
  kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  log "client stopped"
}

restart_client() {
  local reason="${1:-manual}"
  log "restarting client (reason: $reason)"
  stop_client
  sleep 1
  printf '' > "$SIGNAL_FILE"
  start_client
}

take_screenshot() {
  local kind="${1:-debug_view}"
  local extra_name="${2:-}"
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local name="ss_${timestamp}"
  if [ -n "$extra_name" ]; then
    name="${name}_${extra_name}"
  fi
  sleep 1
  screenshot "$name"
}

# === Main ===

cmd="${1:-help}"

case "$cmd" in
  start)
    start_client
    ;;
  stop)
    stop_client
    ;;
  restart)
    restart_client "${2:-manual}"
    ;;
  screenshot)
    take_screenshot "${2:-debug_view}" "${3:-}"
    ;;
  status)
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      if kill -0 "$pid" 2>/dev/null; then
        echo "pwbot running (PID $pid)"
      else
        echo "PID file exists but process dead"
      fi
    else
      echo "pwbot not running"
    fi
    ;;
  *)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  start                Start pwbot client"
    echo "  stop                 Stop pwbot client"
    echo "  restart [reason]     Restart pwbot client"
    echo "  screenshot [kind] [name]  Take screenshot"
    echo "  status               Show client status"
    ;;
esac
