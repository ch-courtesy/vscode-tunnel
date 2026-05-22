# syntax=docker/dockerfile:1.7

# ----- fetcher stage: download + verify VS Code CLI tarball -----
FROM debian:bookworm-slim AS fetcher

ARG VSCODE_COMMIT
ARG VSCODE_SHA256_X64
ARG VSCODE_SHA256_ARM64
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x64;   expected_sha="$VSCODE_SHA256_X64"  ;; \
      arm64) arch=arm64; expected_sha="$VSCODE_SHA256_ARM64" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    if [ -z "$VSCODE_COMMIT" ] || [ "$VSCODE_COMMIT" = "null" ] \
       || [ -z "$expected_sha" ] || [ "$expected_sha" = "null" ]; then \
      echo "VSCODE_COMMIT and matching VSCODE_SHA256_* build args are required (got commit='$VSCODE_COMMIT', sha='$expected_sha')" >&2; \
      exit 1; \
    fi; \
    url="https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/cli-linux-${arch}/stable"; \
    echo "Downloading $url"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/code.tar.gz "$url"; \
    echo "${expected_sha}  /tmp/code.tar.gz" | sha256sum -c -; \
    mkdir -p /out; \
    tar -xzf /tmp/code.tar.gz -C /out; \
    chmod +x /out/code; \
    /out/code --version

# ----- runtime stage -----
FROM debian:bookworm-slim AS runtime

ARG VSCODE_COMMIT
ARG VSCODE_VERSION

LABEL org.opencontainers.image.title="vscode-tunnel" \
      org.opencontainers.image.description="VS Code tunnel server (code tunnel) packaged as a container" \
      org.opencontainers.image.version="${VSCODE_VERSION}" \
      org.opencontainers.image.revision="${VSCODE_COMMIT}" \
      org.opencontainers.image.source="https://github.com/microsoft/vscode" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TUNNEL_NAME=vscode-tunnel \
    TUNNEL_PROVIDER=github \
    VSCODE_CLI_DATA_DIR=/home/coder/.vscode-cli

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        locales \
        libsecret-1-0 \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --uid 1000 coder \
    && mkdir -p /workspace "$VSCODE_CLI_DATA_DIR" \
    && chmod 0700 "$VSCODE_CLI_DATA_DIR" \
    && chown -R coder:coder /workspace "$VSCODE_CLI_DATA_DIR"

COPY --from=fetcher /out/code /usr/local/bin/code
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/code /usr/local/bin/entrypoint.sh

USER coder
WORKDIR /workspace
VOLUME ["/home/coder/.vscode-cli"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
