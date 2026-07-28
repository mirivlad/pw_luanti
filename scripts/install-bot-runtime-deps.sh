#!/usr/bin/env bash
# install-bot-runtime-deps.sh — install what PW Bot's runtime needs to drive a
# real Luanti client.
#
# Idempotent: it checks each dependency first and only installs what is missing.
# It asks for sudo once, and only if there is actually something to install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=0
VISIBLE=1
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: scripts/install-bot-runtime-deps.sh [-y] [--headless-only] [--dry-run]

  -y                 do not prompt before installing
  --headless-only    skip what only visible mode needs (Xephyr, ffmpeg)
  --dry-run          print what would be installed and stop
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --headless-only) VISIBLE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# --- what we need, and which package provides it ---------------------------
# Format: "binary-or-module:apt:dnf:pacman:why"
REQUIRED=(
    "luanti:luanti:luanti:luanti:the real client the bot drives"
    "Xvfb:xvfb:xorg-x11-server-Xvfb:xorg-server-xvfb:isolated headless display"
    "xdotool:xdotool:xdotool:xdotool:window identification"
    "import:imagemagick:ImageMagick:imagemagick:screenshots for humans"
)
VISIBLE_ONLY=(
    "Xephyr:xserver-xephyr:xorg-x11-server-Xephyr:xorg-server-xephyr:nested X server for visible mode"
    "ffplay:ffmpeg:ffmpeg:ffmpeg:fallback visible mirror"
)

detect_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown; fi
}

MANAGER="$(detect_manager)"
case "$MANAGER" in
    apt) FIELD=2 ;;
    dnf) FIELD=3 ;;
    pacman) FIELD=4 ;;
    *) FIELD=2 ;;
esac

echo "=== PW Bot runtime dependencies ==="
echo "package manager: $MANAGER"
echo

MISSING=()
check_entry() {
    local entry="$1"
    local binary package why
    binary="$(echo "$entry" | cut -d: -f1)"
    package="$(echo "$entry" | cut -d: -f$FIELD)"
    why="$(echo "$entry" | cut -d: -f5)"
    if command -v "$binary" >/dev/null 2>&1; then
        printf "  [ok  ] %-10s %s\n" "$binary" "$(command -v "$binary")"
    else
        printf "  [need] %-10s %s (%s)\n" "$binary" "$package" "$why"
        MISSING+=("$package")
    fi
}

for entry in "${REQUIRED[@]}"; do check_entry "$entry"; done
if [ "$VISIBLE" = "1" ]; then
    for entry in "${VISIBLE_ONLY[@]}"; do check_entry "$entry"; done
fi

# python-xlib is the preferred input backend; xdotool covers it if absent.
if python3 -c "import Xlib" >/dev/null 2>&1; then
    printf "  [ok  ] %-10s python-xlib present (preferred input backend)\n" "python-xlib"
else
    case "$MANAGER" in
        apt) PXLIB=python3-xlib ;;
        dnf) PXLIB=python3-xlib ;;
        pacman) PXLIB=python-xlib ;;
        *) PXLIB=python3-xlib ;;
    esac
    printf "  [need] %-10s %s (faster input backend; xdotool works without it)\n" "python-xlib" "$PXLIB"
    MISSING+=("$PXLIB")
fi

PY_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    printf "  [ok  ] %-10s %s\n" "python3" "$PY_VERSION"
else
    printf "  [FAIL] %-10s %s — 3.11 or newer is required (tomllib)\n" "python3" "$PY_VERSION"
    echo
    echo "Upgrade Python before continuing." >&2
    exit 1
fi

echo
if [ ${#MISSING[@]} -eq 0 ]; then
    echo "Everything is already installed."
    echo "Next:  python3 -m pw_bot_runtime doctor --config runtime/pwbot.toml"
    exit 0
fi

echo "Missing packages: ${MISSING[*]}"
case "$MANAGER" in
    apt) COMMAND=(sudo apt-get install -y "${MISSING[@]}") ;;
    dnf) COMMAND=(sudo dnf install -y "${MISSING[@]}") ;;
    pacman) COMMAND=(sudo pacman -S --needed --noconfirm "${MISSING[@]}") ;;
    *) echo "Unknown package manager; install these yourself: ${MISSING[*]}" >&2; exit 1 ;;
esac

echo "Command: ${COMMAND[*]}"
if [ "$DRY_RUN" = "1" ]; then
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    printf "Install now? [y/N] "
    read -r answer
    case "$answer" in [yY]*) ;; *) echo "nothing installed"; exit 1 ;; esac
fi

"${COMMAND[@]}"
echo
echo "Done. Verify with:"
echo "  python3 -m pw_bot_runtime doctor --config runtime/pwbot.toml"
