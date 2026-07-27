#!/usr/bin/env bash
# smoke-test.sh — Structural checks for PerfectWorld
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

check_file() { [ -f "$ROOT/$1" ] || { echo "MISSING: $1"; errors=$((errors+1)); }; }
check_pattern() { grep -q "$2" "$ROOT/$1" || { echo "MISSING pattern '$2' in $1"; errors=$((errors+1)); }; }

echo "=== PerfectWorld smoke test ==="

# Core files
check_file "Dockerfile"
check_file "docker-compose.yml"
check_file "docker-compose.test.yml"
check_file "README.md"
check_file "MIGRATION.md"
check_file ".gitignore"

# Config
check_file "config/luanti.conf"
check_file "config/world.mt.example"

# PerfectWorld modpack
check_file "local_mods/perfectworld/modpack.conf"
for m in pw_core pw_compat_mcl pw_planner pw_structures pw_roads pw_settlements pw_population pw_debug pw_bot_bridge pw_player_bot pw_tests; do
  check_file "local_mods/perfectworld/$m/init.lua"
  check_file "local_mods/perfectworld/$m/mod.conf"
done

# Bot bridge: perception must stay split across modules, never one big init.lua
for f in api registry permissions capabilities perception player_perception \
         oracle_perception semantics entities events protocol transport validation; do
  check_file "local_mods/perfectworld/pw_bot_bridge/$f.lua"
done
check_file "local_mods/perfectworld/pw_bot_bridge/settingtypes.txt"
check_file "local_mods/perfectworld/pw_bot_bridge/tests/init.lua"
check_pattern "local_mods/perfectworld/pw_bot_bridge/capabilities.lua" "pw_bot_bridge/v1"
check_pattern "local_mods/perfectworld/pw_bot_bridge/permissions.lua" "pw_bot_admin"

# The bridge observes; it must never act for the player. Only its own tests may
# stand in for the client, and they say so.
ACTING=':set_pos\(|:set_look_horizontal\(|:set_look_vertical\(|:set_attach\(|:set_detach\(|:set_velocity\(|:add_velocity\(|:set_physics_override\(|:set_hp\(|:punch\(|:right_click\(|:move_to\(|set_node\(|remove_node\('
if grep -REn "$ACTING" "$ROOT/local_mods/perfectworld/pw_bot_bridge" --include="*.lua" \
     --exclude-dir=tests >/dev/null 2>&1; then
  echo "FAIL: pw_bot_bridge contains world- or player-acting calls outside its tests"
  grep -REn "$ACTING" "$ROOT/local_mods/perfectworld/pw_bot_bridge" --include="*.lua" \
    --exclude-dir=tests
  errors=$((errors+1))
else
  echo "OK: pw_bot_bridge never moves, turns, attaches a player or writes a node"
fi

# No screenshot pipeline and no external process: perception is programmatic.
if grep -REn "os\.execute|io\.popen|imagemagick|opencv|import -window" \
     "$ROOT/local_mods/perfectworld/pw_bot_bridge" --include="*.lua" >/dev/null 2>&1; then
  echo "FAIL: pw_bot_bridge shells out or depends on an image pipeline"
  errors=$((errors+1))
else
  echo "OK: pw_bot_bridge has no screenshot-based perception"
fi

# Player bot: decides, never acts. Same guard, and one more that matters as much
# — the brain must reach the world through the bridge, never through the map.
for f in memory beliefs navigation needs goals utility brain intent api; do
  check_file "local_mods/perfectworld/pw_player_bot/$f.lua"
done
check_file "local_mods/perfectworld/pw_player_bot/settingtypes.txt"
check_file "local_mods/perfectworld/pw_player_bot/tests/init.lua"
check_pattern "local_mods/perfectworld/pw_player_bot/intent.lua" "pw_player_bot/v1"

if grep -REn "$ACTING" "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" \
     --exclude-dir=tests >/dev/null 2>&1; then
  echo "FAIL: pw_player_bot contains world- or player-acting calls outside its tests"
  grep -REn "$ACTING" "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" \
    --exclude-dir=tests
  errors=$((errors+1))
else
  echo "OK: pw_player_bot decides but never acts"
fi

if grep -REn "minetest\.get_node|core\.get_node|get_node_or_nil|VoxelManip|get_objects_inside_radius" \
     "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" \
     --exclude-dir=tests >/dev/null 2>&1; then
  echo "FAIL: pw_player_bot reads the map directly instead of through pw_bot_bridge"
  grep -REn "minetest\.get_node|core\.get_node|get_node_or_nil|VoxelManip|get_objects_inside_radius" \
    "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" --exclude-dir=tests
  errors=$((errors+1))
else
  echo "OK: pw_player_bot knows the world only through what it observed"
fi

# Actual calls, not the words: both modules name math.random and screenshots in
# prose, precisely to say they do not use them.
if grep -REn "math\.random *\(|math\.randomseed *\(|PseudoRandom *\(" \
     "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" >/dev/null 2>&1; then
  echo "FAIL: pw_player_bot uses randomness; decisions must be reproducible"
  grep -REn "math\.random *\(|math\.randomseed *\(|PseudoRandom *\(" \
    "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua"
  errors=$((errors+1))
else
  echo "OK: pw_player_bot decisions are deterministic"
fi

if grep -REn "os\.execute|io\.popen|imagemagick|opencv|import -window" \
     "$ROOT/local_mods/perfectworld/pw_player_bot" --include="*.lua" >/dev/null 2>&1; then
  echo "FAIL: pw_player_bot shells out or depends on an image pipeline"
  errors=$((errors+1))
else
  echo "OK: pw_player_bot has no screenshot-based perception"
fi

# The bridge must not silently request an insecure environment.
if grep -Rn "request_insecure_environment" "$ROOT/local_mods/perfectworld/pw_bot_bridge" \
     --include="*.lua" >/dev/null 2>&1; then
  echo "FAIL: pw_bot_bridge requests an insecure environment"
  errors=$((errors+1))
else
  echo "OK: pw_bot_bridge needs no insecure environment"
fi

# TestKit
check_file "local_mods/luanti_testkit/init.lua"
check_file "local_mods/luanti_testkit/mod.conf"
check_file "local_mods/luanti_testkit/tests/smoke.lua"

# Remote control
check_file "local_mods/pw_remote_control/init.lua"
check_file "local_mods/pw_remote_control/mod.conf"

# No aliveworld dependencies in code
if grep -Rl "aliveworld" "$ROOT/local_mods/" --include="*.lua" --include="*.conf" 2>/dev/null; then
  echo "FAIL: aliveworld references found in code"
  errors=$((errors+1))
else
  echo "OK: no aliveworld references in code"
fi

echo "=== Smoke test done: $errors errors ==="
exit $errors
