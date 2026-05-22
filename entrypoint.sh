#!/usr/bin/env bash
set -euo pipefail

: "${TUNNEL_NAME:=vscode-tunnel}"
: "${TUNNEL_PROVIDER:=github}"
: "${VSCODE_CLI_DATA_DIR:=$HOME/.vscode-cli}"

export VSCODE_CLI_DATA_DIR
mkdir -p "$VSCODE_CLI_DATA_DIR"

# Forward SIGTERM/SIGINT to the tunnel process for graceful shutdown
tunnel_pid=""
shutdown() {
  if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill -TERM "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown TERM INT

# Login if no auth state exists. `code tunnel user show` exits non-zero when logged out.
if ! code tunnel user show >/dev/null 2>&1; then
  echo ">>> No VS Code tunnel auth state found. Starting device-code login (provider: ${TUNNEL_PROVIDER})."
  echo ">>> Follow the URL printed below to authenticate. The code is one-time use."
  code tunnel user login --provider "$TUNNEL_PROVIDER"
fi

echo ">>> Starting tunnel '${TUNNEL_NAME}'"
code tunnel \
  --accept-server-license-terms \
  --name "$TUNNEL_NAME" \
  --random-name=false \
  "$@" &
tunnel_pid=$!
wait "$tunnel_pid"
