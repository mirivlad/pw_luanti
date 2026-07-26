#!/usr/bin/env bash
# Собрать Docker-образ Luanti с ncurses и всеми фичами.
set -euo pipefail

exec docker compose build "$@"
