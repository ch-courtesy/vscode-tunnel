#!/usr/bin/env bash
# Manual / end-to-end tests for vscode-tunnel image.
# Usage: scripts/manual-tests.sh <step>
#   prep     - build image if missing
#   auto     - automated checks (CI parity)
#   bind     - bind-mount uid permission check (auto, no human)
#   login    - interactive device-code login (REQUIRES -it terminal + browser)
#   persist  - verify no re-auth after login
#   sigterm  - graceful SIGTERM via tini
#   provider - TUNNEL_PROVIDER switch (REQUIRES -it terminal)
#   cleanup  - remove test volumes + image
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-vscode-tunnel:smoke}
VOL_MAIN=${VOL_MAIN:-vscode-tunnel-state-test}
VOL_HEADLESS=${VOL_HEADLESS:-vscode-tunnel-state-test-headless}
WS_HOST=${WS_HOST:-/tmp/vscode-tunnel-ws}

readv() {
  COMMIT=$(jq -r '.stable.commit'      versions.json)
  VERSION=$(jq -r '.stable.version'     versions.json)
  SHA_X64=$(jq -r '.stable.sha256.x64'  versions.json)
  SHA_ARM64=$(jq -r '.stable.sha256.arm64' versions.json)
}

step_prep() {
  readv
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image already present: $IMAGE"
  else
    echo ">>> building $IMAGE for host platform"
    docker buildx build --platform "linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
      --build-arg VSCODE_COMMIT="$COMMIT" \
      --build-arg VSCODE_VERSION="$VERSION" \
      --build-arg VSCODE_SHA256_X64="$SHA_X64" \
      --build-arg VSCODE_SHA256_ARM64="$SHA_ARM64" \
      --load -t "$IMAGE" .
  fi
  docker volume create "$VOL_MAIN" >/dev/null
}

step_auto() {
  readv
  echo "::: (a) code --version matches versions.json"
  out=$(docker run --rm --entrypoint code "$IMAGE" --version)
  echo "$out"
  grep -qE "(^|[[:space:]])${VERSION}([[:space:]]|$)" <<<"$out" || { echo FAIL version; exit 1; }
  grep -q "commit ${COMMIT}" <<<"$out" || { echo FAIL commit; exit 1; }
  echo "OK"

  echo "::: (b) headless without auth → exit 1 with helpful message"
  if docker run --rm -e HEADLESS_RETRY_DELAY=0 "$IMAGE" > /tmp/entry.log 2>&1; then
    echo "FAIL: should have exited non-zero"
    cat /tmp/entry.log
    exit 1
  fi
  grep -q 'No VS Code tunnel auth state' /tmp/entry.log || { echo FAIL message; cat /tmp/entry.log; exit 1; }
  echo "OK"

  echo "::: (c) non-root + data dir mode 0700"
  docker run --rm --entrypoint sh "$IMAGE" -c \
    'id; stat -c "%a %U %G %n" "$VSCODE_CLI_DATA_DIR"'

  echo "::: (d) OCI labels"
  docker image inspect "$IMAGE" --format '{{json .Config.Labels}}' \
    | jq '."org.opencontainers.image.version", ."org.opencontainers.image.revision", ."org.opencontainers.image.source", ."org.opencontainers.image.url"'
}

step_bind() {
  echo "::: bind-mount uid mismatch handling"
  rm -rf "$WS_HOST" && mkdir -p "$WS_HOST"
  echo "before" > "$WS_HOST/host-file.txt"

  echo "-- 1) default (uid 1000): expect Permission denied on $WS_HOST"
  if docker run --rm -v "$WS_HOST":/workspace --entrypoint sh "$IMAGE" \
      -c 'echo from-container > /workspace/in-container.txt' 2>/tmp/bind.err; then
    echo "UNEXPECTED: write succeeded (host uid might be 1000 — skipping)"
  else
    if grep -qi 'permission denied' /tmp/bind.err; then
      echo "OK: permission denied as expected"
    else
      echo "FAIL: unexpected error"; cat /tmp/bind.err; exit 1
    fi
  fi

  echo "-- 2) with --user \$(id -u):\$(id -g): expect success"
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$WS_HOST":/workspace --entrypoint sh "$IMAGE" \
    -c 'echo from-container > /workspace/in-container.txt && cat /workspace/in-container.txt'
  echo "OK"

  rm -rf "$WS_HOST"
}

step_login() {
  echo "::: interactive device-code login (Ctrl+C after tunnel starts)"
  echo "    -> watch the URL/code, authenticate in browser, then Ctrl+C"
  docker run --rm -it \
    -v "$VOL_MAIN":/home/coder/.vscode-cli \
    -e TUNNEL_NAME=my-test-tunnel \
    "$IMAGE"
}

step_persist() {
  echo "::: re-run with same volume — no auth prompt expected"
  out=$(docker run --rm \
    -v "$VOL_MAIN":/home/coder/.vscode-cli \
    -e TUNNEL_NAME=my-test-tunnel \
    "$IMAGE" --version 2>&1 | head -5 || true)
  # Above will start the tunnel and block; the --version is ignored by `code tunnel`.
  # For a non-blocking check, use `code tunnel user show` instead.
  echo "-- direct: code tunnel user show"
  docker run --rm \
    -v "$VOL_MAIN":/home/coder/.vscode-cli \
    --entrypoint code "$IMAGE" tunnel user show
}

step_sigterm() {
  echo "::: SIGTERM graceful shutdown"
  docker rm -f vscode-tunnel-sig >/dev/null 2>&1 || true
  docker run -d --name vscode-tunnel-sig \
    -v "$VOL_MAIN":/home/coder/.vscode-cli \
    "$IMAGE" >/dev/null
  echo "started; waiting 5s for tunnel to spin up"
  sleep 5
  echo "-- docker logs (last 5):"
  docker logs --tail 5 vscode-tunnel-sig
  echo "-- docker stop (expect 1~3s; fail if >10s)"
  t0=$(date +%s)
  docker stop vscode-tunnel-sig >/dev/null
  t1=$(date +%s)
  echo "stop took $((t1 - t0))s"
  docker rm vscode-tunnel-sig >/dev/null
  if (( t1 - t0 > 10 )); then echo "FAIL: SIGTERM not propagated (SIGKILL took over)"; exit 1; fi
  echo "OK"
}

step_provider() {
  echo "::: TUNNEL_PROVIDER switch — expect re-login prompt"
  echo "    (only meaningful if VOL_MAIN already has github auth state)"
  docker run --rm -it \
    -v "$VOL_MAIN":/home/coder/.vscode-cli \
    -e TUNNEL_PROVIDER=microsoft \
    "$IMAGE"
}

step_cleanup() {
  docker rm -f vscode-tunnel-sig >/dev/null 2>&1 || true
  docker volume rm "$VOL_MAIN" "$VOL_HEADLESS" >/dev/null 2>&1 || true
  rm -rf "$WS_HOST"
  echo "cleaned. (image $IMAGE left in place — remove manually if you want)"
}

case "${1:-}" in
  prep)     step_prep ;;
  auto)     step_auto ;;
  bind)     step_bind ;;
  login)    step_login ;;
  persist)  step_persist ;;
  sigterm)  step_sigterm ;;
  provider) step_provider ;;
  cleanup)  step_cleanup ;;
  all-auto) step_prep; step_auto; step_bind ;;
  *) sed -n '1,12p' "$0" >&2; exit 1 ;;
esac
