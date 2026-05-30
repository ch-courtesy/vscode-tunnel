#!/usr/bin/env bash
# Start the vscode-tunnel + agents stack via docker compose.
# Delegates .env / build setup to compose-init.sh (idempotent).
#
# Usage:
#   scripts/compose-start.sh              # ensure setup, then up -d
#   scripts/compose-start.sh --logs       # tail logs after starting
#   scripts/compose-start.sh --no-cache   # force full rebuild (passed to compose-init.sh)

set -euo pipefail

cd "$(dirname "$0")/.."

follow_logs=0
no_cache=0

for arg in "$@"; do
  case "$arg" in
    --logs)     follow_logs=1 ;;
    --no-cache) no_cache=1 ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

init_args=()
[ "$no_cache" -eq 1 ] && init_args+=(--no-cache)
scripts/compose-init.sh ${init_args[@]+"${init_args[@]}"}

echo "==> docker compose up -d"
docker compose up -d

docker compose ps

if [ "$follow_logs" -eq 1 ]; then
  exec docker compose logs -f
fi
