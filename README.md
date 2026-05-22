# vscode-tunnel

VS Code tunnel 서버(`code tunnel`)를 컨테이너로 패키징한 이미지. vscode.dev 또는 데스크톱 VS Code에서 컨테이너 내부 작업공간에 원격 접속할 수 있다.

설계 배경과 의사결정은 [`docs/PLAN.md`](docs/PLAN.md) 참고.

## 빌드 (로컬)

`versions.json`에 핀된 VS Code stable 빌드를 사용한다. 로컬에서는 `--load`가 단일 플랫폼만 지원하므로 호스트 아키텍처에 맞춰 하나만 적재한다.

```bash
COMMIT=$(jq -r '.stable.commit'         versions.json)
VERSION=$(jq -r '.stable.version'        versions.json)
SHA_X64=$(jq -r '.stable.sha256.x64'     versions.json)
SHA_ARM64=$(jq -r '.stable.sha256.arm64' versions.json)

# 호스트 아키텍처 자동 선택 (linux/amd64 또는 linux/arm64)
PLATFORM="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

docker buildx build \
  --platform "$PLATFORM" \
  --build-arg VSCODE_COMMIT="$COMMIT" \
  --build-arg VSCODE_VERSION="$VERSION" \
  --build-arg VSCODE_SHA256_X64="$SHA_X64" \
  --build-arg VSCODE_SHA256_ARM64="$SHA_ARM64" \
  -t vscode-tunnel:"$VERSION" \
  -t vscode-tunnel:"$VERSION-${COMMIT:0:7}" \
  --load .
```

멀티 아키텍처 빌드 및 GHCR 푸시는 CI에서 처리한다 — [`.github/workflows/build.yml`](.github/workflows/build.yml).

## 실행

```bash
VERSION=$(jq -r '.stable.version' versions.json)

docker run -d --name vscode-tunnel \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -v "$PWD":/workspace \
  -e TUNNEL_NAME=my-tunnel \
  --restart unless-stopped \
  vscode-tunnel:"$VERSION"
```

### 최초 로그인 (device-code flow)

볼륨에 인증 상태가 없으면 entrypoint가 자동으로 device-code 로그인을 시작한다. **단, TTY가 없는 헤드리스 환경에서는 entrypoint가 즉시 종료하므로 첫 부팅은 인터랙티브로 진행하거나 `VSCODE_CLI_ACCESS_TOKEN`을 주입한다.**

#### 옵션 A — 인터랙티브 첫 부팅 (권장)

```bash
# 첫 실행은 -it로 (restart 정책은 잠시 꺼둔다)
docker run -it --rm \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -e TUNNEL_NAME=my-tunnel \
  vscode-tunnel:"$VERSION"
# 로그에 표시되는 URL과 코드를 브라우저에서 입력해 인증 → Ctrl+C로 빠져나옴

# 이후 detached + restart로 정식 기동
docker run -d --name vscode-tunnel \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -v "$PWD":/workspace \
  -e TUNNEL_NAME=my-tunnel \
  --restart unless-stopped \
  vscode-tunnel:"$VERSION"
```

#### 옵션 B — 비대화식 로그인

미리 발급받은 토큰을 환경변수로 주입한다.

```bash
docker run -d --name vscode-tunnel \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -e TUNNEL_NAME=my-tunnel \
  -e TUNNEL_PROVIDER=github \
  -e VSCODE_CLI_ACCESS_TOKEN="$YOUR_PAT" \
  --restart unless-stopped \
  vscode-tunnel:"$VERSION"
```

인증 완료 후 `https://vscode.dev/tunnel/<TUNNEL_NAME>` 또는 데스크톱 VS Code의 "Remote Tunnels" 확장에서 접속한다. 볼륨이 유지되는 한 재시작 시 재인증은 불필요하다.

### bind mount 권한 주의

컨테이너는 `coder` 사용자(uid 1000)로 실행된다. 호스트의 `$PWD` 소유자가 uid 1000이 아니면 `/workspace`에 쓸 수 없다. 대처:

```bash
# 호스트 uid가 1000이 아닐 때: 호스트 uid/gid로 컨테이너 실행
docker run -d --name vscode-tunnel \
  --user "$(id -u):$(id -g)" \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -v "$PWD":/workspace \
  vscode-tunnel:"$VERSION"
```

`--user` 사용 시 `/home/coder/.vscode-cli`도 같이 chown 필요할 수 있다 — named volume이 아닌 bind mount 사용 시 호스트 디렉터리를 미리 `chmod 0700`로 만들어두는 것을 권장.

## 환경 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `TUNNEL_NAME` | `vscode-tunnel` | 터널 이름 (vscode.dev/tunnel/`<name>`) |
| `TUNNEL_PROVIDER` | `github` | 로그인 제공자 (`github` 또는 `microsoft`) — 변경 시 자동 재로그인 |
| `VSCODE_CLI_ACCESS_TOKEN` | (없음) | 비대화식 로그인용 토큰 |
| `VSCODE_CLI_DATA_DIR` | `/home/coder/.vscode-cli` | CLI 상태 디렉터리 |

## 볼륨

| 경로 | 용도 |
|---|---|
| `/home/coder/.vscode-cli` | 터널 인증 토큰 + CLI 상태 (영속화 필수, 권한 0700) |
| `/workspace` | 작업 디렉터리 — 호스트 디렉터리를 bind mount (위 권한 주의 참고) |

## VS Code 버전 관리

`versions.json`이 핀된 stable 릴리스를 정의한다. `.github/workflows/update-vscode.yml`이 매주 월요일 09:00 UTC에 upstream을 확인해 새 릴리스가 있으면 sha256을 핀된 commit에서 직접 계산해 PR을 자동으로 연다.

Renovate(`renovate.json`)는 GitHub Actions/base 이미지 등 일반 의존성만 관리한다.

## 라이선스

이미지는 MIT. 내장된 VS Code CLI는 Microsoft 라이선스를 따른다 (`--accept-server-license-terms`가 entrypoint에 포함되어 있다).
