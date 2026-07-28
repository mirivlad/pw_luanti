#!/usr/bin/env bash
# pw-village-check.sh — build villages and report what they were actually made of.
#
# The tests check the *plan*: that a village is offered one style's schemes and
# no others. That is not the same as a village standing in the world built from
# them. This brings a client up, runs a batch build, and reads back the
# structures the planner recorded, so "villages use the catalogue" is a claim
# about the world rather than about a table.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLD="$ROOT/data/worlds/perfectworld"
PLAYER="${PW_BOT_PLAYER:-pwbot}"
DISPLAY_NUMBER="${PW_CHECK_DISPLAY:-123}"
RADIUS="${1:-2}"

say() { echo "[village-check $(date +%T)] $*"; }

cleanup() {
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null || true
    sleep 2
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

rc() {
    printf '{"command":"runchat","chatcmd":"%s","params":"%s","player":"%s","nonce":"%s"}' \
        "$1" "$2" "$PLAYER" "$(date +%s%N)" > "$WORLD/rc_cmd.json"
    sleep "${3:-3}"
}

if ! pgrep -f "luanti[ ]--go" >/dev/null 2>&1; then
    say "starting a client on :$DISPLAY_NUMBER"
    JOINS_BEFORE="$(docker logs perfectworld-dev 2>&1 | grep -c "$PLAYER.*joins game" || true)"
    Xvfb ":$DISPLAY_NUMBER" -screen 0 640x480x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 2
    DISPLAY=":$DISPLAY_NUMBER" /usr/games/luanti --go \
        --address 127.0.0.1 --port 30000 --name "$PLAYER" \
        --password-file "$ROOT/secrets/pwbot.password" \
        > "$ROOT/logs/pw-village-check-client.log" 2>&1 &
    CLIENT_PID=$!
    for _ in $(seq 1 60); do
        NOW="$(docker logs perfectworld-dev 2>&1 | grep -c "$PLAYER.*joins game" || true)"
        [ "${NOW:-0}" -gt "${JOINS_BEFORE:-0}" ] && break
        kill -0 "$CLIENT_PID" 2>/dev/null || break
        sleep 1
    done
    sleep 3
    docker exec perfectworld-dev sh -c "echo \"/grant $PLAYER all\" > /proc/1/fd/0" >/dev/null 2>&1
    sleep 1
else
    say "using the client already running"
fi

say "building villages within radius $RADIUS"
rc "pw_village_batch" "$RADIUS" 45

say "exporting what was built"
rc "pw_village_export" "" 8

python3 - "$WORLD" <<'PY'
import glob, json, os, sys, collections

world = sys.argv[1]
exports = sorted(glob.glob(os.path.join(world, "pw_settlements_*.json")),
                 key=os.path.getmtime)
if not exports:
    print("no export written; is pw_village_export available?")
    raise SystemExit(1)

document = json.load(open(exports[-1], encoding="utf-8"))
print(f"\nexport: {os.path.basename(exports[-1])}")

records = document if isinstance(document, list) else (
    document.get("settlements") or document.get("villages") or [])

styles = collections.Counter()
built = collections.Counter()
mixed = []
for record in records:
    names = []
    for lot in (record.get("lots") or []):
        name = lot.get("structure_name")
        if name:
            names.append(name)
            built[name] += 1
    prefixes = {n.split("_")[0] for n in names if not n.startswith("pw_")}
    if len(prefixes) > 1:
        mixed.append((record.get("settlement_id") or record.get("id"), sorted(prefixes)))
    for p in prefixes:
        styles[p] += 1

print(f"settlements: {len(records)}")
print(f"style prefixes seen: {dict(styles)}")
scheme_built = sum(c for n, c in built.items() if not n.startswith("pw_"))
legacy_built = sum(c for n, c in built.items() if n.startswith("pw_"))
print(f"buildings from the catalogue: {scheme_built}")
print(f"buildings from the old set:   {legacy_built}")
if mixed:
    print(f"MIXED STYLES in {len(mixed)} settlement(s): {mixed[:3]}")
else:
    print("no settlement mixed two styles")
print("\nmost used:")
for name, count in built.most_common(12):
    print(f"  {count:>3}  {name}")
PY
