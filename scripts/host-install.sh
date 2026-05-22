#!/usr/bin/env bash
# Install VS Code CLI on the host and set up a systemd --user service.
# Reads version + sha256 from versions.json at the repo root.
#
# Usage:
#   scripts/host-install.sh                   # install + setup, no autostart
#   scripts/host-install.sh --enable          # install + setup + enable on boot
#   PREFIX=/usr/local scripts/host-install.sh # system-wide (needs sudo)
#
# Idempotent: re-running upgrades the binary in place.

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX=${PREFIX:-$HOME/.local}
ENABLE=0
for arg in "$@"; do
  case "$arg" in
    --enable) ENABLE=1 ;;
    -h|--help) sed -n '1,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# 1) Detect arch
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armhf ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
}
ARCH=$(host_arch)

# 2) Read pinned version
COMMIT=$(jq -r '.stable.commit'  versions.json)
VERSION=$(jq -r '.stable.version' versions.json)
case "$ARCH" in
  x64)   EXPECTED_SHA=$(jq -r '.stable.sha256.x64'   versions.json) ;;
  arm64) EXPECTED_SHA=$(jq -r '.stable.sha256.arm64' versions.json) ;;
  armhf) EXPECTED_SHA="" ;;  # not pinned in versions.json — verify manually
esac

echo ">>> Installing VS Code CLI ${VERSION} @ ${COMMIT:0:7} (arch=${ARCH})"
echo ">>> PREFIX=${PREFIX}"

mkdir -p "$PREFIX/bin"

# 3) Download + verify
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
url="https://update.code.visualstudio.com/commit:${COMMIT}/cli-linux-${ARCH}/stable"
echo ">>> Downloading $url"
curl -fsSL --retry 3 --retry-delay 2 -o "$workdir/code.tar.gz" "$url"

if [[ -n "$EXPECTED_SHA" ]]; then
  echo "${EXPECTED_SHA}  $workdir/code.tar.gz" | sha256sum -c -
else
  echo ">>> No pinned sha256 for $ARCH — skipping verification"
fi

tar -xzf "$workdir/code.tar.gz" -C "$workdir"
install -m 0755 "$workdir/code" "$PREFIX/bin/code"
echo ">>> Installed: $("$PREFIX/bin/code" --version | head -1)"

# 4) systemd --user unit (Linux only)
if command -v systemctl >/dev/null 2>&1 && [[ "$(uname -s)" == "Linux" ]]; then
  unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  unit_path="$unit_dir/vscode-tunnel.service"

  cat > "$unit_path" <<EOF
[Unit]
Description=VS Code tunnel (%u)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$PREFIX/bin/code tunnel --accept-server-license-terms --name %u-tunnel
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  echo ">>> Wrote $unit_path"

  systemctl --user daemon-reload
  if (( ENABLE )); then
    # Enable lingering so the service starts on boot without an active login
    if command -v loginctl >/dev/null 2>&1; then
      sudo loginctl enable-linger "$USER" 2>/dev/null \
        || echo ">>> Could not enable-linger; service will only run while logged in."
    fi
    systemctl --user enable vscode-tunnel.service
    echo ">>> Enabled vscode-tunnel.service (will start on boot once authenticated)"
  fi
else
  echo ">>> systemd not available — skipping unit setup. Use:"
  echo "      $PREFIX/bin/code tunnel --accept-server-license-terms --name <name>"
fi

# 5) Next-steps
cat <<EOF

================================================================================
NEXT STEPS

1. One-time login (device-code via GitHub):
     $PREFIX/bin/code tunnel user login --provider github
   Open the printed URL in any browser and enter the code.

2. Start the tunnel:
     - foreground:  $PREFIX/bin/code tunnel --accept-server-license-terms --name \$USER-tunnel
     - via systemd: systemctl --user start vscode-tunnel
     - logs:        journalctl --user -u vscode-tunnel -f

3. Connect from VS Code desktop ("Remote Tunnels" extension) or
   https://vscode.dev/tunnel/\$USER-tunnel

OPTIONAL: Claude Code on the same host
     curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
     sudo apt-get install -y nodejs
     npm install -g @anthropic-ai/claude-code
     claude /login

To upgrade later: re-run this script (pulls new versions.json values).
================================================================================
EOF
