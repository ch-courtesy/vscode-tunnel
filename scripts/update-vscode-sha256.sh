#!/usr/bin/env bash
# Fetch upstream VS Code stable metadata and write versions.json.
# sha256 is computed from the actual tarball at `commit:<sha>/cli-linux-<arch>/stable`,
# not from a "latest" pointer — so the sha256 always matches the pinned commit.
set -euo pipefail

cd "$(dirname "$0")/.."

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

meta=$(curl -fsSL --retry 3 --retry-delay 2 \
  'https://update.code.visualstudio.com/api/update/cli-linux-x64/stable/latest')
version=$(jq -er '.productVersion' <<<"$meta")
commit=$(jq -er '.version' <<<"$meta")
echo "Upstream stable: ${version} @ ${commit}"

fetch_sha() {
  local arch=$1
  local url="https://update.code.visualstudio.com/commit:${commit}/cli-linux-${arch}/stable"
  local out="${workdir}/cli-${arch}.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
  sha256sum "$out" | awk '{print $1}'
}

sha_x64=$(fetch_sha x64)
sha_arm64=$(fetch_sha arm64)
echo "sha256.x64   = ${sha_x64}"
echo "sha256.arm64 = ${sha_arm64}"

jq -n \
  --arg version "$version" \
  --arg commit "$commit" \
  --arg sha_x64 "$sha_x64" \
  --arg sha_arm64 "$sha_arm64" \
  '{stable: {version: $version, commit: $commit, sha256: {x64: $sha_x64, arm64: $sha_arm64}}}' \
  > versions.json

echo "Wrote versions.json:"
cat versions.json
