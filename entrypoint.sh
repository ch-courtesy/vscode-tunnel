#!/usr/bin/env bash
set -euo pipefail

: "${TUNNEL_NAME:=vscode-tunnel}"
: "${TUNNEL_PROVIDER:=github}"
: "${VSCODE_CLI_DATA_DIR:=$HOME/.vscode-cli}"
: "${HEADLESS_RETRY_DELAY:=30}"
: "${TUNNEL_PERSIST_AUTH:=0}"

export VSCODE_CLI_DATA_DIR
mkdir -p "$VSCODE_CLI_DATA_DIR"
chmod 0700 "$VSCODE_CLI_DATA_DIR"

# VS Code CLI encrypts the on-disk auth token with a key derived from the
# container instance — meaning auth does NOT survive `docker rm` (or any new
# container) by default, even with a named volume. Opt-in plaintext storage
# trades the per-instance encryption for actual cross-container persistence.
# See docs/PLAN.md §9 for the security trade-off discussion.
if [[ "$TUNNEL_PERSIST_AUTH" == "1" || "$TUNNEL_PERSIST_AUTH" == "true" ]]; then
  export VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT=1
  echo ">>> TUNNEL_PERSIST_AUTH enabled: tokens stored as plaintext JSON in $VSCODE_CLI_DATA_DIR (mode 0700)."
fi

provider_marker="$VSCODE_CLI_DATA_DIR/.tunnel-provider"
needs_login=0

if [[ -f "$provider_marker" ]]; then
  prev=$(cat "$provider_marker")
  if [[ "$prev" != "$TUNNEL_PROVIDER" ]]; then
    echo ">>> TUNNEL_PROVIDER changed: ${prev} -> ${TUNNEL_PROVIDER}. Will re-login."
    needs_login=1
  fi
fi

if (( needs_login == 0 )) && ! code tunnel user show >/dev/null 2>&1; then
  needs_login=1
fi

if (( needs_login == 1 )); then
  if [[ -n "${VSCODE_CLI_ACCESS_TOKEN:-}" ]]; then
    echo ">>> Logging in non-interactively via VSCODE_CLI_ACCESS_TOKEN (provider: ${TUNNEL_PROVIDER})."
  elif [[ -t 0 || -t 1 ]]; then
    echo ">>> No VS Code tunnel auth state. Starting device-code login (provider: ${TUNNEL_PROVIDER})."
  else
    cat >&2 <<EOF
ERROR: No VS Code tunnel auth state and no TTY for interactive login.

First-time setup requires one of:
  - Run once with -it to complete the device-code flow:
      docker run -it --rm -v <vol>:/home/coder/.vscode-cli <image>
  - Or set VSCODE_CLI_ACCESS_TOKEN (provider: ${TUNNEL_PROVIDER}) for headless boot.

Sleeping ${HEADLESS_RETRY_DELAY}s before exit to throttle restart-policy loops
(set HEADLESS_RETRY_DELAY=0 to disable).
EOF
    if [[ "$HEADLESS_RETRY_DELAY" -gt 0 ]]; then
      sleep "$HEADLESS_RETRY_DELAY"
    fi
    exit 1
  fi

  # Let `code tunnel user login --provider X` handle identity replacement.
  # Not calling explicit `logout` first: if login fails (network blip,
  # cancelled device-code), the previous session stays usable. The marker
  # is only updated on success, so a partial failure retries next boot.
  if [[ -n "${VSCODE_CLI_ACCESS_TOKEN:-}" ]]; then
    code tunnel user login \
      --provider "$TUNNEL_PROVIDER" \
      --access-token "$VSCODE_CLI_ACCESS_TOKEN"
  else
    code tunnel user login --provider "$TUNNEL_PROVIDER"
  fi

  printf '%s' "$TUNNEL_PROVIDER" > "$provider_marker"
fi

echo ">>> Starting tunnel '${TUNNEL_NAME}'"
exec code tunnel \
  --accept-server-license-terms \
  --name "$TUNNEL_NAME" \
  "$@"
