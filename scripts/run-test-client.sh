#!/usr/bin/env bash
# run-test-client.sh
# Universal Luanti test client launcher.
# Connects a headless/full Luanti client to a test server.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# === Configuration (override via env) ===
LUANTI_CLIENT="${LUANTI_CLIENT:-luanti}"
LTK_HOST="${LTK_HOST:-127.0.0.1}"
LTK_PORT="${LTK_PORT:-30000}"
LTK_USER="${LTK_USER:-pwbot}"
LTK_PASSWORD_FILE="${LTK_PASSWORD_FILE:-$ROOT/secrets/pwbot.password}"
HEADLESS="${HEADLESS:-1}"
LTK_LOG="${LTK_LOG:-$ROOT/logs/test-client.log}"

# === Checks ===
if [ ! -f "$LTK_PASSWORD_FILE" ]; then
    echo "ERROR: Password file not found: $LTK_PASSWORD_FILE"
    echo "Create it from the example:"
    echo "  cp $ROOT/secrets/pwbot.password.example $LTK_PASSWORD_FILE"
    echo "  # Edit $LTK_PASSWORD_FILE with the actual password"
    echo "  # Then on the server: /setpassword $LTK_USER"
    echo "  # And: /grant $LTK_USER all"
    exit 1
fi

if ! command -v "$LUANTI_CLIENT" &>/dev/null; then
    echo "ERROR: Luanti client binary not found: $LUANTI_CLIENT"
    echo "Install it or set LUANTI_CLIENT env var to the correct path."
    echo "Examples:"
    echo "  LUANTI_CLIENT=/usr/games/luanti"
    echo "  LUANTI_CLIENT=~/apps/luanti/bin/luanti"
    exit 1
fi

# === Prepare log dir ===
mkdir -p "$(dirname "$LTK_LOG")"

# === Determine headless mode ===
LAUNCHER=()
if [ "$HEADLESS" = "1" ]; then
    if command -v xvfb-run &>/dev/null; then
        LAUNCHER=(xvfb-run --auto-servernum)
        echo "Using xvfb-run for headless mode"
    else
        echo "WARNING: HEADLESS=1 but xvfb-run not found. Client will open a window."
        echo "Install xvfb: sudo apt-get install xvfb"
    fi
fi

# === Run client ===
echo "Starting test client '$LTK_USER' -> $LTK_HOST:$LTK_PORT"
echo "Logging to: $LTK_LOG"

"${LAUNCHER[@]}" "$LUANTI_CLIENT" \
    --go \
    --address "$LTK_HOST" \
    --port "$LTK_PORT" \
    --name "$LTK_USER" \
    --password-file "$LTK_PASSWORD_FILE" \
    >> "$LTK_LOG" 2>&1 &

CLIENT_PID=$!
echo "Test client PID: $CLIENT_PID"
echo "Run 'tail -f $LTK_LOG' to see client output."
echo "Run 'kill $CLIENT_PID' to stop the client."
echo "---"
echo "Client connecting..."
sleep 2
echo "Check server: docker logs perfectworld-dev | tail -5"
