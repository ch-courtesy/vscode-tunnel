#!/usr/bin/env bash
# Stop the vscode-tunnel + agents stack.
#
# Usage:
#   scripts/compose-stop.sh               # docker compose down (keeps volumes)
#   scripts/compose-stop.sh --volumes     # also remove named volumes (auth state lost!)

set -euo pipefail

cd "$(dirname "$0")/.."

down_flags=()

for arg in "$@"; do
  case "$arg" in
    --volumes|-v) down_flags+=(--volumes) ;;
    -h|--help)
      sed -n '2,7p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> docker compose down ${down_flags[*]:-}"
docker compose down "${down_flags[@]}"
