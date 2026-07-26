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
for m in pw_core pw_compat_mcl pw_planner pw_structures pw_roads pw_settlements pw_population pw_debug pw_tests; do
  check_file "local_mods/perfectworld/$m/init.lua"
  check_file "local_mods/perfectworld/$m/mod.conf"
done

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
