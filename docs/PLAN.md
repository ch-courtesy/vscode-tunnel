# VS Code Tunnel Docker 이미지 계획

## 1. 목표
`code tunnel` CLI를 컨테이너로 띄워 vscode.dev 또는 데스크톱 VS Code에서 원격 접속 가능한 개발 환경을 제공한다.

## 2. 기술 선택

| 항목 | 선택 | 이유 |
|---|---|---|
| Base image | `debian:bookworm-slim` | VS Code CLI는 glibc 기반 동적 바이너리 — Alpine(musl) 부적합 |
| VS Code CLI | 공식 update 서버 tarball (commit pin) | 버전 고정 + 재현 빌드 |
| 멀티 아키텍처 | `linux/amd64`, `linux/arm64` | M1 Mac / ARM 서버 대응 |
| 실행 사용자 | non-root (`coder`, uid 1000) | 보안 + 호스트 볼륨 권한 정렬 |
| 인증 | 런타임 device-code flow (GitHub) | 이미지에 토큰 굽지 않음 |

## 3. Dockerfile 구조

### 3.1 멀티 스테이지
1. **fetcher stage**
   - `curl`로 commit-pinned tarball 다운로드
   - `TARGETARCH` 기반 아키텍처 분기 (`amd64` → `x64`, `arm64` → `arm64`)
   - SHA256 검증 (`versions.json` 매핑 사용)
   - 압축 해제 → `/usr/local/bin/code`
2. **runtime stage**
   - 최소 의존성: `ca-certificates`, `git`, `openssh-client`, `curl`, `locales`, `libsecret-1-0`
   - non-root user `coder` 생성 (`/home/coder`)
   - fetcher에서 `code` 바이너리 복사
   - entrypoint 스크립트 복사

### 3.2 메타데이터 / 볼륨
- OCI 라벨:
  - `org.opencontainers.image.version` = `${VSCODE_VERSION}`
  - `org.opencontainers.image.revision` = `${VSCODE_COMMIT}`
  - `org.opencontainers.image.source` = `https://github.com/microsoft/vscode`
- `ENV TUNNEL_NAME=vscode-tunnel`
- `VOLUME ["/home/coder/.vscode-cli", "/workspace"]`
- `WORKDIR /workspace`
- `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`

## 4. entrypoint.sh 로직
- `TUNNEL_NAME` 환경변수로 터널 이름 결정
- `$HOME/.vscode-cli` 디렉터리 존재 보장
- 로그인 상태 미존재 시: device-code URL 안내 후 `code tunnel user login --provider github`
- `code tunnel --accept-server-license-terms --name "$TUNNEL_NAME" --random-name false`
- SIGTERM 시 graceful shutdown (trap)

## 5. VS Code CLI 버전 관리 전략

### 5.1 핵심 원칙
1. **commit SHA로 핀** — VS Code 릴리스의 1차 식별자는 commit SHA, 버전 번호는 사람이 읽기 위한 라벨
2. **SHA256 검증** — 다운로드 후 체크섬 검증으로 supply-chain 방어
3. **이미지 태그에 버전 + commit 동시 반영** — 어떤 VS Code 빌드인지 태그만 보고 추적 가능
4. **Renovate 자동 PR로 정기 업데이트** — 수동 추적 제거

### 5.2 다운로드 URL 패턴
```
https://update.code.visualstudio.com/commit:<COMMIT_SHA>/cli-linux-<arch>/stable
```
- `<arch>`: `x64`, `arm64`, `armhf`
- commit 기반 URL은 해당 빌드가 보존되는 한 영구 유효
- `latest` 포인터는 ARG 기본값으로만 사용, CI 빌드는 항상 명시적 commit 지정

### 5.3 `versions.json` 스키마
레포 루트에 두고 Renovate가 갱신:
```jsonc
{
  "stable": {
    "version": "1.95.0",
    "commit": "4949701c880d4bdb949e3c0e6b400b94d423d4b1",
    "sha256": {
      "x64":   "<sha256>",
      "arm64": "<sha256>"
    }
  }
}
```

### 5.4 빌드 ARG
```dockerfile
ARG VSCODE_COMMIT
ARG VSCODE_VERSION
ARG VSCODE_SHA256_X64
ARG VSCODE_SHA256_ARM64
```
CI에서 `versions.json`을 읽어 `--build-arg`로 주입.

### 5.5 자동 업데이트 (Renovate)
`renovate.json`에 custom regex manager 추가:
```jsonc
{
  "customManagers": [{
    "customType": "regex",
    "fileMatch": ["^versions\\.json$"],
    "matchStrings": ["\"commit\":\\s*\"(?<currentDigest>[a-f0-9]{40})\""],
    "depNameTemplate": "microsoft/vscode",
    "datasourceTemplate": "github-releases",
    "currentValueTemplate": "stable"
  }]
}
```
PR 생성 시 CI가 새 commit의 sha256을 fetch → `versions.json` 갱신 → 빌드 + 스모크 테스트 → 머지.

Renovate가 닿지 않는 경우 GitHub Actions cron이 `https://update.code.visualstudio.com/api/releases/stable` 폴링하는 대체 워크플로.

### 5.6 이미지 태그 정책
| 태그 | 의미 | 용도 |
|---|---|---|
| `:1.95.0` | VS Code 버전 | 일반 사용자 |
| `:1.95.0-4949701` | 버전 + 단축 commit | 완전 재현 빌드 핀 |
| `:1.95` / `:1` | semver float | 자동 패치 수신 |
| `:latest` | 항상 최신 stable | 데모용 — 프로덕션 비권장 |
| `:insiders-<commit>` | insiders 채널 | 별도 워크플로 (선택) |

## 6. 운영 산출물
- `Dockerfile`
- `entrypoint.sh`
- `versions.json` — VS Code 버전/commit/sha256 매핑
- `.dockerignore` — `.git`, `*.md`, `docs/` 제외
- `docker-compose.yml` (선택) — 볼륨/환경변수/재시작 정책 샘플
- `renovate.json` — 자동 업데이트 설정
- `.github/workflows/build.yml` — 멀티 아키텍처 빌드 + 푸시
- `.github/workflows/update-vscode.yml` — (선택) Renovate 대체 cron
- `README.md` 갱신 — 빌드/실행/최초 로그인 방법

## 7. 빌드/실행 예시
```bash
# 빌드
docker buildx build \
  --build-arg VSCODE_COMMIT=4949701c880d4bdb949e3c0e6b400b94d423d4b1 \
  --build-arg VSCODE_VERSION=1.95.0 \
  --build-arg VSCODE_SHA256_X64=<sha> \
  --build-arg VSCODE_SHA256_ARM64=<sha> \
  -t ghcr.io/me/vscode-tunnel:1.95.0 \
  -t ghcr.io/me/vscode-tunnel:1.95.0-4949701 \
  --platform linux/amd64,linux/arm64 .

# 실행
docker run -d --name vscode-tunnel \
  -v vscode-tunnel-state:/home/coder/.vscode-cli \
  -v "$PWD":/workspace \
  -e TUNNEL_NAME=my-tunnel \
  --restart unless-stopped \
  ghcr.io/me/vscode-tunnel:1.95.0

# 최초 로그인용 device-code URL 확인
docker logs -f vscode-tunnel
```

## 8. 검증 체크리스트
- [ ] `docker buildx build`가 amd64/arm64 모두에서 성공
- [ ] 컨테이너 기동 시 device-code URL 로그 출력
- [ ] GitHub 인증 후 `vscode.dev/tunnel/<name>` 접속 성공
- [ ] 컨테이너 재시작 후 재인증 불필요 (볼륨 영속성)
- [ ] non-root 사용자로 동작 확인 (`id` in container)
- [ ] 이미지 크기 ~200MB 이하
- [ ] `code --version` 출력이 `versions.json`의 값과 일치
- [ ] SHA256 검증이 실제로 동작 (잘못된 sha 주입 시 빌드 실패 확인)
- [ ] Renovate PR이 dry-run에서 정상 매칭

## 9. 잠재 이슈 / 결정 보류 항목
- **libsecret/keyring 부재**: 헤드리스 컨테이너엔 D-Bus 없음 → 토큰이 평문 파일로 fallback 저장됨(볼륨에 보관). 이게 허용 가능한 보안 수준인지 결정 필요.
- **device-code flow 강제**: 완전 무인 부팅 불가 — 최초 1회 브라우저 인증 필요.
- **라이선스 자동 동의**: `--accept-server-license-terms` 자동 부착 정책.
- **insiders 채널 지원 여부**: stable만 운영할지, 양쪽 다 빌드할지.
- **`:latest` 태그 유지 여부**: 편의 vs 비재현성.

## 10. 작업 순서
1. `versions.json` 초기값 작성 (현재 stable commit + sha256 조사)
2. `entrypoint.sh` 작성
3. `Dockerfile` 작성 (multi-stage, multi-arch ARG)
4. 로컬에서 `docker buildx` 단일 아키텍처 빌드 → 스모크 테스트
5. `.dockerignore` 작성
6. `README.md` 갱신
7. `.github/workflows/build.yml` 작성 (멀티 아키텍처 + GHCR 푸시)
8. `renovate.json` 작성 + Renovate 활성화
9. PR → 머지
