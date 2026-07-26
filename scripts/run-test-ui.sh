#!/usr/bin/env bash
# run-test-ui.sh
# Host-side UI test manager for AliveWorld awbot.
# Orchestrates client lifecycle, screenshot capture, and restart recovery.
# Reads signal files written by the server-side ui_state module.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDPATH="$ROOT/data/worlds/aliveworld"
SIGNAL_FILE="$WORLDPATH/awbot_client.signal"
SCREENSHOT_DIR="$ROOT/artifacts"
DEBUG_LOG="$ROOT/data/debug.txt"
CLIENT_LOG="$ROOT/logs/test-ui.log"
PID_FILE="$ROOT/run/awbot.pid"

mkdir -p "$ROOT/run" "$SCREENSHOT_DIR"

# === Config ===
LUANTI_CLIENT="${LUANTI_CLIENT:-luanti}"
LTK_HOST="${LTK_HOST:-127.0.0.1}"
LTK_PORT="${LTK_PORT:-30000}"
LTK_USER="${LTK_USER:-awbot}"
LTK_PASSWORD_FILE="${LTK_PASSWORD_FILE:-$ROOT/secrets/awbot.password}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
OBSERVER_POS="${OBSERVER_POS:-245,23,-145}"
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
    # fallback: any xauth file
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
  # Find the Xvfb process that uses this xauth file and extract its display number
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

wait_for_player_online() {
  local timeout="${1:-30}"
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if grep -q "awbot.*online" "$DEBUG_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
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

  log "starting awbot client (display :$DISPLAY_NUM)"

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
  local pgid=$pid
  echo "$pid" > "$PID_FILE"
  log "client PID: $pid (PGID: $pgid)"

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
  # First, kick the player from the server so reconnection works immediately
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
  # Kill the entire process group (xvfb-run + Xvfb + luanti)
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

  # Clear restart signal on server side
  printf '' > "$SIGNAL_FILE"

  start_client
  if [ $? -ne 0 ]; then
    log "ERROR: restart failed"
    return 1
  fi

  log "restoring state after restart"
  sleep 3
  restore_state
}

# === State Restoration ===

restore_state() {
  log "restoring state: teleport, GPS, track"

  # Teleport via remote controller
  local teleport_json
  teleport_json=$(printf '{"command":"teleport","pos":{"x":%s,"y":%s,"z":%s},"player":"%s"}' \
    $(echo "$OBSERVER_POS" | tr ',' ' ') "$LTK_USER")
  printf '%s' "$teleport_json" > "$WORLDPATH/rc_cmd.json"
  sleep 1

  # GPS on
  rc_command "aw_gps" "on"
  sleep 1

  # Track
  rc_command "aw_track" "site_birch_ford"
  sleep 1

  # Verify
  rc_command "aw_gps_debug" ""
  sleep 2

  log "state restore commands sent"
}

# === Signal Polling ===

poll_restart_signal() {
  if [ -f "$SIGNAL_FILE" ] && [ -s "$SIGNAL_FILE" ]; then
    local content
    content=$(cat "$SIGNAL_FILE")
    if [ -n "$content" ]; then
      local action reason
      action=$(echo "$content" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','restart'))" 2>/dev/null || echo "restart")
      reason=$(echo "$content" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "parse_failed")
      rm -f "$SIGNAL_FILE"
      if [ "$action" = "tests_complete" ]; then
        log "tests complete, stopping client"
        stop_client
        return 0
      else
        log "restart signal received: $reason"
        restart_client "$reason"
      fi
      return 0
    fi
  fi
  return 1
}

# === Screenshot Workflow ===

take_screenshot() {
  local kind="${1:-debug_view}"
  local extra_name="${2:-}"
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local name="ss_${timestamp}"

  if [ -n "$extra_name" ]; then
    name="${name}_${extra_name}"
  fi

  local pre_shot_data=""
  local pre_shot_file="$WORLDPATH/awbot_pre_shot.json"

  if [ "$kind" = "world_view" ]; then
    # Step 1: Close any open formspec
    rc_command "aw_clean_ui" ""
    sleep 1

    # Check signal file: only restart if action is restart_awbot_client
    if [ -f "$SIGNAL_FILE" ] && [ -s "$SIGNAL_FILE" ]; then
      local signal_content signal_action signal_reason
      signal_content=$(cat "$SIGNAL_FILE")
      signal_action=$(echo "$signal_content" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo "")
      signal_reason=$(echo "$signal_content" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "read_failed")
      rm -f "$SIGNAL_FILE"
      if [ "$signal_action" = "restart_awbot_client" ]; then
        log "prepare_shot: restart signaled ($signal_reason), restarting"
        restart_client "$signal_reason"
        sleep 3
      elif [ "$signal_action" = "tests_complete" ]; then
        log "prepare_shot: tests already complete, proceeding"
      else
        log "prepare_shot: unknown signal ($signal_action), ignoring"
      fi
    fi

    # Step 2: Prepare screenshot (safety check, teleport, GPS/track)
    rm -f "$pre_shot_file"
    rc_command "aw_prepare_shot" ""
    sleep 1

    # Wait for pre-shot state file (poll up to 5s)
    local wait_seconds=0
    while [ $wait_seconds -lt 5 ]; do
      if [ -f "$pre_shot_file" ] && [ -s "$pre_shot_file" ]; then
        pre_shot_data=$(cat "$pre_shot_file")
        log "pre-shot data received"
        break
      fi
      sleep 1
      wait_seconds=$((wait_seconds + 1))
    done
    if [ -z "$pre_shot_data" ]; then
      log "WARNING: pre-shot data not available, continuing without it"
    fi
  fi

  sleep 1
  local path
  path=$(screenshot "$name" 2>/dev/null)
  path=$(echo "$path" | tail -1)

  # Build expanded metadata for world_view
  if [ -n "$path" ] && [ -f "$path" ]; then
    local meta_file="${path}.meta.json"
    local basename_path
    basename_path=$(basename "$path")

    if [ "$kind" = "world_view" ] && [ -n "$pre_shot_data" ]; then
      # Use Python to merge pre-shot data with metadata fields (avoids JSON syntax issues)
      local timestamp_utc
      timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      cat > "$meta_file" << 'PYEOF'
import sys, json, os
data_raw = os.environ.get('META_PRESHOT', '{}')
d = json.loads(data_raw)
meta = {
  'screenshot': os.environ.get('META_BASENAME', ''),
  'screenshot_kind': 'world_view',
  'timestamp': os.environ.get('META_TIMESTAMP', ''),
  'player_pos': '(%s,%s,%s)' % (d.get('player_pos',{}).get('x',''), d.get('player_pos',{}).get('y',''), d.get('player_pos',{}).get('z','')),
  'target_site': d.get('target_site',''),
  'target_pos': '(%s,%s,%s)' % (d.get('target_pos',{}).get('x',''), d.get('target_pos',{}).get('y',''), d.get('target_pos',{}).get('z','')) if d.get('target_pos') else None,
  'distance_to_target': d.get('distance_to_target'),
  'in_liquid': d.get('in_liquid', False),
  'on_ground': d.get('on_ground', False),
  'hp': d.get('hp'),
  'breath': d.get('breath'),
  'hostile_mobs_nearby': d.get('hostile_mobs_nearby', 0),
  'gps_enabled': d.get('gps_enabled', False),
  'active_tracks_count': d.get('active_tracks_count', 0),
  'tracking_hud_id': d.get('tracking_hud_id'),
  # Compatibility alias for older metadata consumers; not a 3D waypoint HUD.
  'waypoint_hud_id': d.get('waypoint_hud_id'),
  'radar_points_count': d.get('radar_points_count', 0),
  'radar_points': d.get('radar_points', []),
  'visual_expectation': d.get('visual_expectation', []),
  'path': os.environ.get('META_PATH', ''),
}
print(json.dumps(meta, indent=2))
PYEOF
      META_PRESHOT="$pre_shot_data" \
        META_BASENAME="$basename_path" \
        META_TIMESTAMP="$timestamp_utc" \
        META_PATH="$path" \
        python3 "$meta_file" > "$meta_file.tmp" 2>/dev/null && \
        mv "$meta_file.tmp" "$meta_file"
    else
      cat > "$meta_file" << EOF
{
  "screenshot": "$basename_path",
  "screenshot_kind": "$kind",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "path": "$path"
}
EOF
    fi
    log "metadata written: $meta_file"
  fi

  echo "$path"
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
  poll)
    poll_restart_signal
    ;;
  daemon)
    log "starting UI test daemon (poll every ${POLL_INTERVAL}s)"
    start_client
    trap 'log "shutting down"; stop_client; exit 0' INT TERM
    while true; do
      if poll_restart_signal; then
        if [ ! -f "$PID_FILE" ]; then
          log "client stopped, exiting daemon"
          exit 0
        fi
      fi
      sleep "$POLL_INTERVAL"
    done
    ;;
  world-screenshot)
    take_screenshot "world_view" "$2"
    ;;
  ui-screenshot)
    take_screenshot "ui_view" "$2"
    ;;
  debug-screenshot)
    take_screenshot "debug_view" "$2"
    ;;
  restore)
    restore_state
    ;;
  status)
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      if kill -0 "$pid" 2>/dev/null; then
        echo "awbot running (PID $pid)"
      else
        echo "PID file exists but process dead"
      fi
    else
      echo "awbot not running"
    fi
    ;;
  *)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  start                    Start awbot client"
    echo "  stop                     Stop awbot client"
    echo "  restart [reason]         Restart awbot client"
    echo "  screenshot [kind] [name] Take screenshot (kind: world_view|ui_view|debug_view)"
    echo "  world-screenshot [name]  Take clean world view screenshot"
    echo "  ui-screenshot [name]     Take UI view screenshot"
    echo "  debug-screenshot [name]  Take debug screenshot"
    echo "  poll                     Check for restart signal"
    echo "  daemon                   Run polling daemon (auto-restart on signal)"
    echo "  restore                  Restore state (teleport, GPS, track)"
    echo "  status                   Show client status"
    echo ""
    echo "Examples:"
    echo "  $0 start"
    echo "  $0 world-screenshot gps_test"
    echo "  $0 daemon &"
    ;;
esac
