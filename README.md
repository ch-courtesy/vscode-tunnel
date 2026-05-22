# vscode-tunnel

VS Code tunnel 서버(`code tunnel`)를 컨테이너로 패키징한 이미지. vscode.dev 또는 데스크톱 VS Code에서 컨테이너 내부 작업공간에 원격 접속할 수 있다.

설계 배경과 의사결정은 [`docs/PLAN.md`](docs/PLAN.md) 참고.

## 빌드

`versions.json`에 핀된 VS Code stable 빌드를 사용한다. 빌드 ARG를 같이 넘겨준다.

```bash
COMMIT=$(jq -r '.stable.commit'         versions.json)
VERSION=$(jq -r '.stable.version'        versions.json)
SHA_X64=$(jq -r '.stable.sha256.x64'     versions.json)
SHA_ARM64=$(jq -r '.stable.sha256.arm64' versions.json)

docker buildx build \
  --build-arg VSCODE_COMMIT="$COMMIT" \
  --build-arg VSCODE_VERSION="$VERSION" \
  --build-arg VSCODE_SHA256_X64="$SHA_X64" \
  --build-arg VSCODE_SHA256_ARM64="$SHA_ARM64" \
  --platform linux/amd64,linux/arm64 \
  -t vscode-tunnel:"$VERSION" \
  -t vscode-tunnel:"$VERSION-${COMMIT:0:7}" \
  --load .
```

(멀티 아키텍처 푸시는 CI에서 — [`.github/workflows/build.yml`](.github/workflows/build.yml).)

## 실행

```bash
docker run -d --name vscode-tunnel \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -v "$PWD":/workspace \
  -e TUNNEL_NAME=my-tunnel \
  --restart unless-stopped \
  vscode-tunnel:latest
```

### 최초 로그인 (device-code flow)

볼륨에 인증 상태가 없으면 entrypoint가 자동으로 device-code 로그인을 시작한다. 로그에서 URL과 코드를 확인하여 브라우저에서 인증한다.

```bash
docker logs -f vscode-tunnel
# >>> No VS Code tunnel auth state found. Starting device-code login (provider: github).
# To grant access to the server, please log into https://github.com/login/device and use code XXXX-XXXX
```

인증 완료 후 `https://vscode.dev/tunnel/<TUNNEL_NAME>` 또는 데스크톱 VS Code의 "Remote Tunnels" 확장에서 접속한다.

`vscode-tunnel-state` 볼륨이 유지되는 한 재시작 시 재인증은 불필요하다.

## 환경 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `TUNNEL_NAME` | `vscode-tunnel` | 터널 이름 (vscode.dev/tunnel/`<name>`) |
| `TUNNEL_PROVIDER` | `github` | 로그인 제공자 (`github` 또는 `microsoft`) |
| `VSCODE_CLI_DATA_DIR` | `/home/coder/.vscode-cli` | CLI 상태 디렉터리 |

## 볼륨

| 경로 | 용도 |
|---|---|
| `/home/coder/.vscode-cli` | 터널 인증 토큰 + CLI 상태 (영속화 필수) |
| `/workspace` | 작업 디렉터리 — 호스트 디렉터리를 마운트 |

## VS Code 버전 관리

`versions.json`이 현재 핀된 stable 릴리스를 정의한다. Renovate가 `microsoft/vscode` GitHub 릴리스를 추적해 자동으로 PR을 올린다 — [`renovate.json`](renovate.json) 참고.

## 라이선스

이미지는 MIT. 내장된 VS Code CLI는 Microsoft 라이선스를 따른다 (`--accept-server-license-terms` 플래그가 entrypoint에 포함됨).
