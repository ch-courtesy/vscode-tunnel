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
- `ENV TUNNEL_NAME=vscode-tunnel`, `TUNNEL_PROVIDER=github`, `VSCODE_CLI_DATA_DIR=/home/coder/.vscode-cli`
- `VOLUME ["/home/coder/.vscode-cli"]` (작업공간 `/workspace`는 VOLUME 선언 제외 — bind mount 사용을 가정)
- `WORKDIR /workspace`
- `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]` — tini가 PID 1로서 SIGTERM 전파/좀비 reaping 담당, entrypoint는 `exec`으로 `code tunnel` 호출

## 4. entrypoint.sh 로직
- `TUNNEL_NAME`/`TUNNEL_PROVIDER`/`VSCODE_CLI_DATA_DIR` 환경변수로 동작 결정
- `$VSCODE_CLI_DATA_DIR`을 0700으로 보장 (token 평문 fallback 대비)
- 프로바이더 marker 파일(`.tunnel-provider`)로 `TUNNEL_PROVIDER` 변경 감지 → 변경 시 자동 logout + 재로그인
- 로그인 상태 미존재 시 분기:
  - `VSCODE_CLI_ACCESS_TOKEN` 설정 시 → 비대화식 `code tunnel user login --access-token`
  - TTY 존재 시 → device-code flow
  - 그 외 → 명확한 에러 메시지 + `exit 1` (crash loop 방지를 위해 사용자에게 first-boot 안내)
- `exec code tunnel --accept-server-license-terms --name "$TUNNEL_NAME"` — exec으로 PID 승계, tini가 신호 전파, 별도 trap 불필요

## 5. VS Code CLI 버전 관리 전략

### 5.1 핵심 원칙
1. **commit SHA로 핀** — VS Code 릴리스의 1차 식별자는 commit SHA, 버전 번호는 사람이 읽기 위한 라벨
2. **SHA256 검증** — 다운로드 후 체크섬 검증으로 supply-chain 방어. sha256은 **핀된 commit의 tarball을 직접 다운로드해 계산** (latest 포인터 의존 금지)
3. **이미지 태그에 버전 + commit 동시 반영** — 어떤 VS Code 빌드인지 태그만 보고 추적 가능
4. **전용 GitHub Actions cron으로 자동 업데이트** — Renovate `customManagers` + `postUpgradeTasks` 조합은 `github-releases` 데이터소스가 digest 갱신을 지원하지 않고 hosted Renovate가 `allowedCommands` 허용 안 함 → 신뢰 불가. 대신 `.github/workflows/update-vscode.yml`가 매주 upstream을 확인해 PR을 자동으로 연다.

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

### 5.5 자동 업데이트 (GitHub Actions cron)
전용 워크플로 `.github/workflows/update-vscode.yml`이 매주 월요일 09:00 UTC에 동작:
1. `scripts/update-vscode-sha256.sh` 실행 — `https://update.code.visualstudio.com/api/update/cli-linux-x64/stable/latest`에서 productVersion+commit 가져오기
2. 해당 commit의 `cli-linux-x64`/`cli-linux-arm64` tarball을 직접 다운로드 → sha256 계산 (latest 포인터 재조회 금지)
3. `versions.json` 재작성
4. 변경 있으면 `peter-evans/create-pull-request@v6`로 PR 자동 생성 (`GH_TOKEN` 사용 — `GITHUB_TOKEN`은 PR-from-workflow가 후속 워크플로를 트리거 못 함)

Renovate(`renovate.json`)는 GitHub Actions/base 이미지 등 일반 의존성만 추적, VS Code customManager는 사용하지 않음.

### 5.6 이미지 태그 정책
| 태그 | 의미 | 용도 |
|---|---|---|
| `:1.95.0` | VS Code 버전 | 일반 사용자 |
| `:1.95.0-4949701` | 버전 + 단축 commit | 완전 재현 빌드 핀 |
| `:1.95` / `:1` | semver float | 자동 minor/patch 수신 — `:1`은 메이저 동일 minor 변동 수신함 주의 |
| `:latest` | 항상 최신 stable | **자동 푸시하지 않음** — `workflow_dispatch` 입력 `push_latest=true`일 때만 푸시 |
| `:insiders-<commit>` | insiders 채널 | 별도 워크플로 (선택) |

## 6. 운영 산출물
- `Dockerfile` — multi-stage, sha256 검증, non-root, tini PID 1
- `entrypoint.sh` — exec 기반 신호 전파, TTY/token 분기, provider marker
- `versions.json` — VS Code 버전/commit/sha256 매핑
- `scripts/update-vscode-sha256.sh` — upstream API + 핀된 commit tarball 다운로드로 sha256 계산
- `.dockerignore` — `.git`, `*.md`, `docs/` 제외
- `renovate.json` — 일반 의존성(Actions, base 이미지) 추적
- `.github/workflows/build.yml` — shellcheck → smoke (amd64+arm64 QEMU) → push
- `.github/workflows/update-vscode.yml` — 주간 cron + 수동 트리거로 versions.json 갱신 PR
- `README.md` — 빌드/실행/최초 로그인/bind mount 권한 안내

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
- **인증 영속성 vs 평문 토큰**: VS Code CLI는 file-keychain fallback에서도 컨테이너 인스턴스 keyring 기반으로 토큰을 암호화한다 — 즉 named volume에 저장된 token.json은 새 컨테이너에서 복호화 불가. 해결: `VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT=1`을 설정하면 평문 JSON으로 저장돼 cross-container 재사용 가능. entrypoint는 `TUNNEL_PERSIST_AUTH=1`로 opt-in. 트레이드오프: 디렉터리 0700이지만 같은 uid/root 호스트 사용자는 평문 토큰을 읽을 수 있음. 결정 필요: 기본값을 enable로 바꿀지, 또는 docker secret/K8s secret 기반 `VSCODE_CLI_ACCESS_TOKEN` 주입을 표준 권장 워크플로로 할지.
- **device-code flow vs VSCODE_CLI_ACCESS_TOKEN**: 무인 부팅용 토큰 발급 절차/회전 정책 미정.
- **라이선스 자동 동의**: `--accept-server-license-terms` 자동 부착 — 사용자 명시 동의 정책 결정 필요.
- **insiders 채널 지원 여부**: stable만 운영할지, 양쪽 다 빌드할지.
- **`:1` 메이저 floating 태그**: 메이저 동일 minor 변동까지 수신 — 사용자 안내 정책 결정 필요.
- **bind mount uid mismatch**: README에 `--user $(id -u):$(id -g)` 우회 안내했으나 가이드 충분성 검토 필요.
- **`GH_TOKEN` 스코프 / 회전**: README에 권장 권한(repo+workflow+write:packages 또는 fine-grained 동등) 명시. PAT 만료/회전 자동화 정책 미정.
- **SBOM/provenance 검증 정책**: 이미지에 부착하지만 검증(cosign 등) 절차는 별도 미정.

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
