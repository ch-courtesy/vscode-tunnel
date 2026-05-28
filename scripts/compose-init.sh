#!/usr/bin/env bash
# First-time setup for the vscode-tunnel + agents stack.
#
# Steps:
#   1. Seed .env from .env.example (if missing)
#   2. Build the docker image
#   3. Run interactive VS Code tunnel device-code login (requires a TTY)
#   4. Print next-step hints for claude / codex login inside the tunnel
#
# Usage:
#   scripts/compose-init.sh               # full first-time setup
#   scripts/compose-init.sh --skip-auth   # build only, skip device-code login
#   scripts/compose-init.sh --rebuild     # force rebuild even if image exists

set -euo pipefail

cd "$(dirname "$0")/.."

skip_auth=0
rebuild=0

for arg in "$@"; do
  case "$arg" in
    --skip-auth) skip_auth=1 ;;
    --rebuild)   rebuild=1 ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH" >&2
  exit 1
fi

# 1. .env
if [ -f .env ]; then
  echo "==> .env already present, leaving as-is"
else
  if [ ! -f .env.example ]; then
    echo "ERROR: neither .env nor .env.example found" >&2
    exit 1
  fi
  echo "==> creating .env from .env.example"
  cp .env.example .env
fi

# 2. build
image_tag="$(grep -E '^IMAGE=' .env | tail -1 | cut -d= -f2- || true)"
image_tag="${image_tag:-vscode-tunnel-claude:local}"

if [ "$rebuild" -eq 1 ] || ! docker image inspect "$image_tag" >/dev/null 2>&1; then
  echo "==> building image ($image_tag)"
  docker compose build
else
  echo "==> image $image_tag already exists (use --rebuild to force)"
fi

# 3. device-code auth (must run with TTY); auto-skip if state volume non-empty
project="${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}"
tunnel_volume="${project}_vscode-tunnel-state"

tunnel_authed() {
  docker volume inspect "$tunnel_volume" >/dev/null 2>&1 || return 1
  docker run --rm --entrypoint sh -v "$tunnel_volume:/s" "$image_tag" \
    -c 'test -n "$(ls -A /s 2>/dev/null)"' >/dev/null 2>&1
}

if [ "$skip_auth" -eq 1 ]; then
  echo "==> skipping device-code login (--skip-auth)"
elif tunnel_authed; then
  echo "==> VS Code tunnel already authenticated (state volume non-empty)"
elif [ ! -t 0 ] || [ ! -t 1 ]; then
  cat <<EOF >&2
==> SKIP: no TTY detected; cannot run interactive device-code login.
    Re-run this script from an interactive terminal, or run manually:
      docker compose run --rm -it tunnel
EOF
else
  echo "==> launching device-code login (Ctrl+C after authenticating in browser)"
  docker compose run --rm -it tunnel || true
fi

# 4. next steps
cat <<EOF

Setup complete. Next steps:

  scripts/compose-start.sh         # start the tunnel in the background
  docker compose logs -f           # watch logs

Inside the tunneled VS Code terminal, sign in to the agents once:

  claude /login                    # persists to claude-code-state volume
  codex login                      # persists to codex-state volume
EOF
