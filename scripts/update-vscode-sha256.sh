#!/usr/bin/env bash
# Fetch sha256 for the current commit pinned in versions.json and update the file in-place.
# Run after Renovate bumps the version/commit fields.
set -euo pipefail

cd "$(dirname "$0")/.."

commit=$(jq -r '.stable.commit' versions.json)
if [[ -z "$commit" || "$commit" == "null" ]]; then
  echo "versions.json has no stable.commit" >&2
  exit 1
fi

fetch_sha() {
  local arch=$1
  curl -fsSL "https://update.code.visualstudio.com/api/update/cli-linux-${arch}/stable/latest" \
    | jq -er '.sha256hash'
}

sha_x64=$(fetch_sha x64)
sha_arm64=$(fetch_sha arm64)

tmp=$(mktemp)
jq \
  --arg sx "$sha_x64" \
  --arg sa "$sha_arm64" \
  '.stable.sha256.x64 = $sx | .stable.sha256.arm64 = $sa' \
  versions.json > "$tmp"
mv "$tmp" versions.json

echo "Updated versions.json sha256 for commit ${commit:0:7}"
