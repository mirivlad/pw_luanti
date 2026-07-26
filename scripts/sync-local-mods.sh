#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$ROOT/data/mods"

for mod in "$ROOT"/local_mods/*; do
  [ -d "$mod" ] || continue
  name="$(basename "$mod")"
  rm -rf "$ROOT/data/mods/$name"
  cp -a "$mod" "$ROOT/data/mods/$name"
  echo "Synced $name"
done
