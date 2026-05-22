# Host install (without Docker)

단일 머신 개인 서버라면 Docker 없이 호스트에 `code tunnel`을 직접 설치하는 편이 단순합니다 — file-keychain 암호화 문제, uid mismatch, 볼륨 영속성 같은 컨테이너 특유 이슈가 모두 사라지고, 호스트의 OS 인증/keyring을 자연스럽게 활용합니다.

## 한 줄 설치

레포 루트에서:
```bash
./scripts/host-install.sh           # 설치만
./scripts/host-install.sh --enable  # 설치 + 부팅 시 자동 시작
```

스크립트가 하는 일:
1. `versions.json`에서 핀된 commit + sha256 읽기 (Docker 이미지와 동일한 소스)
2. 해당 commit의 `cli-linux-<arch>` tarball 다운로드 → sha256 검증
3. `$PREFIX/bin/code`에 설치 (기본 `~/.local/bin`, `PREFIX=/usr/local`로 시스템 전역도 가능)
4. systemd `--user` 서비스 유닛 생성 (`~/.config/systemd/user/vscode-tunnel.service`)
5. `--enable` 시 `loginctl enable-linger`로 부팅 자동 시작 설정

## 첫 부팅 (한 번만)

```bash
~/.local/bin/code tunnel user login --provider github
# 브라우저로 URL 열고 코드 입력
```

이후 어느 시점이든:
```bash
systemctl --user start vscode-tunnel       # 백그라운드 시작
journalctl --user -u vscode-tunnel -f      # 로그 확인
systemctl --user stop vscode-tunnel        # 중지
```

또는 시스템d 없이 그냥:
```bash
code tunnel --accept-server-license-terms --name $USER-tunnel
```

## Uninstall

```bash
./scripts/host-uninstall.sh              # 바이너리 + systemd 유닛 제거, 상태 보존
./scripts/host-uninstall.sh --purge      # 위 + ~/.vscode-cli 까지 삭제 (재인증/재다운로드 필요)
./scripts/host-uninstall.sh --keep-binary # 유닛/터널 등록만 제거, 바이너리는 둠
```

Uninstall이 하는 일:
1. `systemctl --user stop/disable vscode-tunnel.service` + 유닛 파일 삭제
2. `code tunnel kill` (실행 중인 터널 정지) + `tunnel unregister` (서버 측 등록 해제) + `tunnel user logout`
3. `$PREFIX/bin/code` 바이너리 삭제 (`--keep-binary` 시 보존)
4. `--purge` 시 `~/.vscode-cli` 통째 삭제

`PREFIX=/usr/local`로 설치했다면 uninstall에도 같은 `PREFIX`를 넘기세요.

## 업그레이드

`versions.json`이 갱신되면 (수동 또는 `update-vscode.yml` 자동 PR로) 동일 스크립트를 다시 실행:
```bash
./scripts/host-install.sh
systemctl --user restart vscode-tunnel  # 새 바이너리 적재
```

## Claude Code 같이 설치 (선택)

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
npm install -g @anthropic-ai/claude-code
claude /login
```

호스트 직접 설치라 `~/.claude/`도 그대로 영속 — 컨테이너처럼 볼륨 분리 신경 안 써도 됨.

## 호스트 설치 vs Docker 어느 쪽?

| | 호스트 직접 | Docker |
|---|---|---|
| 설치 단순성 | 한 명령 | 빌드/볼륨/uid 신경 | 
| 격리 | 호스트 권한 그대로 | 컨테이너 경계 |
| 멀티 머신 배포 | 머신마다 스크립트 | 같은 이미지 pull |
| 인증 영속성 | OS keyring 자동 | TUNNEL_PERSIST_AUTH 평문 트레이드오프 |
| 도구 추가(claude-code 등) | apt/npm 직접 | 다운스트림 이미지 빌드 |
| 자원 footprint | 가벼움 | Docker 데몬 + 이미지 |

**단일 개인 서버**: 호스트 직접 설치 권장.
**멀티 머신 / 팀 공유 / 호스트 격리 필요**: Docker.
