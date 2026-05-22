#!/usr/bin/env bash
set -euo pipefail

: "${TUNNEL_NAME:=vscode-tunnel}"
: "${TUNNEL_PROVIDER:=github}"
: "${VSCODE_CLI_DATA_DIR:=$HOME/.vscode-cli}"

export VSCODE_CLI_DATA_DIR
mkdir -p "$VSCODE_CLI_DATA_DIR"
chmod 0700 "$VSCODE_CLI_DATA_DIR"

provider_marker="$VSCODE_CLI_DATA_DIR/.tunnel-provider"
needs_login=0

if [[ -f "$provider_marker" ]]; then
  prev=$(cat "$provider_marker")
  if [[ "$prev" != "$TUNNEL_PROVIDER" ]]; then
    echo ">>> TUNNEL_PROVIDER changed: ${prev} -> ${TUNNEL_PROVIDER}. Forcing re-login."
    code tunnel user logout >/dev/null 2>&1 || true
    needs_login=1
  fi
fi

if (( needs_login == 0 )) && ! code tunnel user show >/dev/null 2>&1; then
  needs_login=1
fi

if (( needs_login == 1 )); then
  if [[ -n "${VSCODE_CLI_ACCESS_TOKEN:-}" ]]; then
    echo ">>> Logging in non-interactively via VSCODE_CLI_ACCESS_TOKEN (provider: ${TUNNEL_PROVIDER})."
    code tunnel user login \
      --provider "$TUNNEL_PROVIDER" \
      --access-token "$VSCODE_CLI_ACCESS_TOKEN"
  elif [[ -t 0 || -t 1 ]]; then
    echo ">>> No VS Code tunnel auth state found. Starting device-code login (provider: ${TUNNEL_PROVIDER})."
    code tunnel user login --provider "$TUNNEL_PROVIDER"
  else
    cat >&2 <<EOF
ERROR: No VS Code tunnel auth state and no TTY for interactive login.

First-time setup requires one of:
  - Run once with -it to complete the device-code flow:
      docker run -it --rm -v <vol>:/home/coder/.vscode-cli <image>
  - Or set VSCODE_CLI_ACCESS_TOKEN (provider: ${TUNNEL_PROVIDER}) for headless boot.

Exiting. If you used --restart unless-stopped, disable it until first login is complete
to avoid burning auth requests in a tight loop.
EOF
    exit 1
  fi
  printf '%s' "$TUNNEL_PROVIDER" > "$provider_marker"
fi

echo ">>> Starting tunnel '${TUNNEL_NAME}'"
exec code tunnel \
  --accept-server-license-terms \
  --name "$TUNNEL_NAME" \
  "$@"
