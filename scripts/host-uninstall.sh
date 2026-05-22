#!/usr/bin/env bash
# Uninstall code CLI installed by host-install.sh.
# Usage:
#   scripts/host-uninstall.sh                   # remove binary + systemd unit; keep state
#   scripts/host-uninstall.sh --purge           # also delete ~/.vscode-cli (auth + server bundles)
#   scripts/host-uninstall.sh --keep-binary     # only tear down systemd unit + tunnel registration
#   PREFIX=/usr/local scripts/host-uninstall.sh # match the prefix used at install

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX=${PREFIX:-$HOME/.local}
PURGE=0
KEEP_BINARY=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --keep-binary) KEEP_BINARY=1 ;;
    -h|--help) sed -n '1,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

CODE_BIN="$PREFIX/bin/code"
UNIT_PATH="$HOME/.config/systemd/user/vscode-tunnel.service"
DATA_DIR="${VSCODE_CLI_DATA_DIR:-$HOME/.vscode-cli}"

# 1) systemd --user unit
if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNIT_PATH" ]]; then
  echo ">>> Stopping + disabling vscode-tunnel.service"
  systemctl --user stop    vscode-tunnel.service 2>/dev/null || true
  systemctl --user disable vscode-tunnel.service 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl --user daemon-reload
  echo ">>> Removed $UNIT_PATH"

  # loginctl linger only if we appear to be the only user of it — be conservative
  # and just leave it. User can run `sudo loginctl disable-linger $USER` if desired.
fi

# 2) Tunnel server-side cleanup (best effort while binary still exists)
if [[ -x "$CODE_BIN" ]]; then
  echo ">>> Stopping running tunnel + unregistering machine"
  "$CODE_BIN" tunnel kill       2>/dev/null || true
  "$CODE_BIN" tunnel unregister 2>/dev/null || true
  "$CODE_BIN" tunnel user logout 2>/dev/null || true
fi

# 3) Binary removal
if (( KEEP_BINARY == 0 )) && [[ -f "$CODE_BIN" ]]; then
  echo ">>> Removing $CODE_BIN"
  rm -f "$CODE_BIN"
fi

# 4) State directory (only with --purge)
if (( PURGE )); then
  if [[ -d "$DATA_DIR" ]]; then
    echo ">>> Purging $DATA_DIR"
    rm -rf "$DATA_DIR"
  fi
fi

echo
echo "uninstall complete."
if (( PURGE == 0 )) && [[ -d "$DATA_DIR" ]]; then
  echo "(state at $DATA_DIR preserved; rerun with --purge to remove)"
fi
