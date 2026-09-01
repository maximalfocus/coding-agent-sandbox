# Build affected Go CLIs from immutable upstream commits. The builder is discarded; only the
# architecture-native static binaries enter the runtime image. Go and source pins move together.
FROM golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651 AS go-cli-builder
ARG TARGETOS=linux
ARG TARGETARCH
ARG GH_SOURCE_COMMIT=01b79dd983af0859e4e3d7454961ad3f08cf88b4
ARG BUILDX_SOURCE_COMMIT=05a1121b29302f90e5b8457de21a1c0ce6ccecba
ARG COMPOSE_SOURCE_COMMIT=37dea37d6751d0a98640c2b4c27066ace2688399
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates
COPY scripts/build-pinned-go-clis.sh /usr/local/bin/build-pinned-go-clis
RUN chmod +x /usr/local/bin/build-pinned-go-clis \
    && /usr/local/bin/build-pinned-go-clis /out

# Claude Code sandbox: the real CLI, locked inside a container.
# Base has Node (required by the bundled coding agents) and a `node` user (uid 1000).
# Pinned by digest for reproducibility (update deliberately). Tag: node:22-bookworm.
# Pi requires Node >=22.19.0.
FROM node:22-bookworm@sha256:5647be709086c696ff32edaaf1c70cd26d1da6ab2b39c32f3c7b4c4a31957e37

# Tools: tinyproxy (hostname-filtering egress proxy), iptables/iproute2 (force traffic
# through it), dev basics, gosu for dropping root. No `sudo`: the firewall is installed by the
# root entrypoint, never re-run by the unprivileged user (smaller post-start privilege surface).
# Bump the refresh date deliberately when Debian security packages must invalidate this cached
# layer even though the immutable Node base digest has not changed.
ARG DEBIAN_SECURITY_REFRESH=2026-07-24
RUN : "${DEBIAN_SECURITY_REFRESH}" \
    && apt-get update && apt-get install -y --no-install-recommends \
      git ripgrep fd-find tmux less procps \
      curl ca-certificates dnsutils unzip \
      tinyproxy iptables iproute2 \
      gosu socat \
      openjdk-17-jdk-headless maven \
      imagemagick imagemagick-6-common imagemagick-6.q16 \
      libmagickcore-6-arch-config libmagickcore-6-headers \
      libmagickcore-6.q16-6 libmagickcore-6.q16-6-extra \
      libmagickcore-6.q16-dev libmagickcore-dev \
      libmagickwand-6-headers libmagickwand-6.q16-6 \
      libmagickwand-6.q16-dev libmagickwand-dev linux-libc-dev \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && mkdir -p /opt/java \
    && ln -s "$(dirname "$(dirname "$(readlink -f /usr/bin/java)")")" /opt/java/openjdk \
    && rm -f /etc/maven/settings.xml \
    && rm -rf /var/lib/apt/lists/*

# Java/Maven backend toolchain. The architecture-neutral JAVA_HOME symlink above works on both
# amd64 and arm64 (Debian's real JDK directory includes the architecture in its name).
ENV JAVA_HOME=/opt/java/openjdk

# Optional: trust corporate / TLS-inspecting-proxy root CA(s) — Cloudflare WARP, Zscaler, etc. —
# so BUILD-time npm/curl (the ttyd download + every `npm install` below use DIRECT, un-proxied
# egress) AND runtime claude/codex/git work behind TLS interception. Drop PEM files as
# `certs/*.crt`; this is a NO-OP when certs/ holds only .gitkeep. Must precede the ttyd download.
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates
# Node's bundled-CA `fetch`/undici ignores NODE_EXTRA_CA_CERTS, so point Node at the system
# OpenSSL store (where update-ca-certificates lands the CA). Harmless without a custom CA — the
# system bundle already holds every public root. Same approach the mitm variant uses.
ENV NODE_OPTIONS=--use-openssl-ca

# AWS CLI v2 — exact release and per-architecture installer digests. AWS does not publish
# checksum sidecars for these versioned zips, so both SHA-256 values are pinned here and verified
# before extraction. The root-owned install is immutable to the runtime node user.
ARG AWS_CLI_VERSION=2.36.7
ARG AWS_CLI_SHA256_AMD64=d641283d37f1a2168457a9f26a20d4e29167652e9ab1719b37114ef1ebe859f4
ARG AWS_CLI_SHA256_ARM64=85826b67912b44bb45d1e46c6e66f383c14405ee0b2f4686f73bdf949c93bd61
ARG TARGETARCH
RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) AWS_ARCH=x86_64; AWS_SHA="$AWS_CLI_SHA256_AMD64" ;; \
      arm64) AWS_ARCH=aarch64; AWS_SHA="$AWS_CLI_SHA256_ARM64" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" \
      -o /tmp/awscliv2.zip; \
    echo "${AWS_SHA}  /tmp/awscliv2.zip" | sha256sum -c -; \
    unzip -q /tmp/awscliv2.zip -d /tmp/aws-cli-install; \
    /tmp/aws-cli-install/aws/install; \
    test "$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)" = "$AWS_CLI_VERSION"; \
    rm -rf /tmp/awscliv2.zip /tmp/aws-cli-install

COPY maven-settings.xml /etc/maven/settings.xml

# Docker client toolchain only: daemon access is deliberately NOT present in the base Compose
# configuration. docker-compose.host.yml is the conspicuous, opt-in host-daemon capability grant.
# Versions are pinned to exact packages from Docker's official Debian repository.
ARG DOCKER_CLI_VERSION=5:29.6.2-1~debian.12~bookworm
ARG DOCKER_BUILDX_VERSION=0.35.0-1~debian.12~bookworm
ARG DOCKER_COMPOSE_VERSION=5.3.1-1~debian.12~bookworm
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       "docker-ce-cli=${DOCKER_CLI_VERSION}" \
       "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}" \
       "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Hostname allowlist proxy config + writable runtime dirs (the `tinyproxy` user is created
# by the package). The egress filter file itself is generated at startup from your domains.
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
RUN mkdir -p /run/tinyproxy /var/log/tinyproxy \
    && chown tinyproxy:tinyproxy /run/tinyproxy /var/log/tinyproxy

# ttyd (web terminal) — static binary, arch-matched, sha256-pinned against the published
# checksums for this version (integrity check, guards a corrupted/swapped download).
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
ARG TARGETARCH
RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) TTYD_ARCH=x86_64;  TTYD_SHA="$TTYD_SHA256_AMD64" ;; \
      arm64) TTYD_ARCH=aarch64; TTYD_SHA="$TTYD_SHA256_ARM64" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
      -o /usr/local/bin/ttyd; \
    echo "${TTYD_SHA}  /usr/local/bin/ttyd" | sha256sum -c - ; \
    chmod +x /usr/local/bin/ttyd

# ttyd 1.7.7's embedded xterm.js ignores OSC 52, so Herdr cannot copy selected text back to the
# host clipboard. This custom index is ttyd's ClipboardAddon-enabled web client built
# from immutable upstream commit 647d55ad865f5ad85ad89ba5e1b28d9b6ac8fd55, plus the compatibility
# patch documented in ttyd/README.md. Serve it through 1.7.7's --index option; the released server
# binary remains architecture/checksum-pinned above.
COPY ttyd/index.html /usr/local/share/ttyd/index.html
RUN echo "85baf6f288791e6012feec6257a8dd3665a449891692e7142debffbe24f99003  /usr/local/share/ttyd/index.html" \
    | sha256sum -c -

# Upgrade npm as one pinned distribution before installing the global CLIs. This keeps npm's
# internal dependency tree coherent while picking up security fixes absent from the base image.
ARG NPM_VERSION=11.18.0
RUN npm install -g "npm@${NPM_VERSION}" \
    && test "$(npm --version)" = "${NPM_VERSION}"

# The real Claude Code CLI, pinned at BUILD time (override with --build-arg). Runtime auto-update
# is DISABLED below (DISABLE_AUTOUPDATER) so the running CLI stays exactly this version — no
# unreviewed binary drift mid-session. To update Claude, bump the arg and rebuild.
# (The base image, npm, and ttyd are also pinned; apt packages come from moving Debian repos.)
ARG CLAUDE_CODE_VERSION=2.1.233
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm ls -g --depth=0 "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" >/dev/null

# Codex CLI (OpenAI) for cross-vendor peer review, pinned at BUILD time. Authenticated separately
# with your ChatGPT/OpenAI subscription via ./scripts/auth/codex-login.sh; egress is gated by ALLOW_OPENAI.
ARG CODEX_VERSION=0.140.0
RUN npm install -g "@openai/codex@${CODEX_VERSION}"

# Additional agent frontends, pinned at build time like Claude and Codex. OpenCode's npm package
# selects the matching native binary; Pi needs no lifecycle scripts for a normal global install.
ARG OPENCODE_VERSION=1.18.4
ARG PI_VERSION=0.81.1
RUN npm install -g --allow-scripts=opencode-ai "opencode-ai@${OPENCODE_VERSION}" \
    && npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

# Herdr agent multiplexer — a single static, architecture-matched binary, pinned by release and
# sha256 so GitHub cannot silently substitute build-time bytes.
# The project was renamed from ogulcancelik/herdr to herdrdev/herdr. The old path still resolves,
# but only through GitHub's rename redirect, which this project does not control — so name the
# canonical owner. Move these three lines together with scripts/update-agent-clis.sh --apply herdr;
# a version bumped without its checksums fails every later build.
ARG HERDR_VERSION=0.7.5
ARG HERDR_SHA256_AMD64=3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253
ARG HERDR_SHA256_ARM64=32e763a1499a6b694b1d708e4f062b743be1da9f34fcfa4d212d6db6fe09a8b9
RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) HERDR_ARCH=x86_64;  HERDR_SHA="$HERDR_SHA256_AMD64" ;; \
      arm64) HERDR_ARCH=aarch64; HERDR_SHA="$HERDR_SHA256_ARM64" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${HERDR_ARCH}" \
      -o /usr/local/bin/herdr; \
    echo "${HERDR_SHA}  /usr/local/bin/herdr" | sha256sum -c -; \
    chmod +x /usr/local/bin/herdr

# GitHub CLI (gh) — the PERMANENT fix for pushing GitHub Actions workflow files. A plain
# `repo`/Contents PAT (GITHUB_TOKEN) cannot create/update `.github/workflows/*`: GitHub rejects it
# without the `workflow` scope, and a classic PAT's scopes are immutable after creation, so it
# can't be fixed from inside the sandbox. `gh auth login`'s token DOES carry `workflow`, so authing
# once via ./scripts/auth/gh-login.sh (device flow, persisted in the gh-config volume) makes such pushes just
# work, every session — the entrypoint runs `gh auth setup-git` when that login is present so git
# uses gh's token for github.com. Installed from the official gh apt repo (arch-correct).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Replace only affected Go binaries after package installation. Keep docker-ce-cli at its exact
# package pin; issue #30 reports no finding in /usr/bin/docker itself.
COPY --from=go-cli-builder /out/gh /usr/bin/gh
COPY --from=go-cli-builder /out/docker-buildx /usr/libexec/docker/cli-plugins/docker-buildx
COPY --from=go-cli-builder /out/docker-compose /usr/libexec/docker/cli-plugins/docker-compose

# bun — runtime for the cdd-skills TypeScript tools (metrics-baseline, golden-lint, coverage-review,
# scaffold-runner, conformance-validate) that /cdd and /cdd-evolve invoke via `bun run`. Those tools
# use only Node/Bun stdlib (no package.json), so the runtime alone is enough — no dependency install.
# Pinned to match the host; bump deliberately.
ARG BUN_VERSION=1.3.11
RUN npm install -g --allow-scripts=bun "bun@${BUN_VERSION}"

# Playwright + Chromium for cdd's UI acceptance testing (`npx playwright test --project=chromium`).
# Browsers go to a SHARED path (not root's ~/.cache) so the unprivileged `node` user finds them;
# --with-deps apt-installs Chromium's system libraries. Pinned to match the host; bump deliberately.
# (Projects pinning a different Playwright version may re-download their browser at runtime — that
#  needs the Playwright CDN allowlisted via EXTRA_ALLOWED_DOMAINS.)
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ARG PLAYWRIGHT_VERSION=1.58.2
RUN npm install -g "@playwright/test@${PLAYWRIGHT_VERSION}" \
    && playwright install --with-deps chromium \
    && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
# Single source of truth for symlinking skill repos into Claude's skills dir — called by the
# entrypoint (auto-load on every boot) and by scripts/skills/skills-setup.sh/.ps1 (host helpers).
COPY scripts/skills/link-skills.sh /usr/local/bin/sandbox-link-skills
COPY scripts/network/aws-sso-domains.sh /usr/local/bin/aws-sso-domains
# First-run setup reminder, sourced by every interactive shell (login shells via profile.d; the
# /etc/bash.bashrc line below covers interactive non-login shells such as Herdr panes). It prints
# ~/.sandbox-todo, which the entrypoint writes only while a manual setup step is still unmet.
COPY scripts/skills/sandbox-todo-hint.sh /etc/profile.d/zz-sandbox-todo.sh
RUN printf '\n# Sandbox first-run setup reminder (interactive non-login shells, e.g. Herdr panes).\n[ -r /etc/profile.d/zz-sandbox-todo.sh ] && . /etc/profile.d/zz-sandbox-todo.sh\n' >> /etc/bash.bashrc
# Strip any CR line endings so the container boots even if the build context was checked out on
# Windows with CRLF (a `bash\r` shebang otherwise fails with "no such file"). Belt-and-suspenders
# with .gitattributes (which forces LF on checkout); also normalize the proxy config copied above.
RUN sed -i 's/\r$//' /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
        /usr/local/bin/sandbox-link-skills /usr/local/bin/aws-sso-domains \
        /etc/profile.d/zz-sandbox-todo.sh /etc/tinyproxy/tinyproxy.conf \
    && chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
        /usr/local/bin/sandbox-link-skills /usr/local/bin/aws-sso-domains

# Claude's view of your files: only what gets mounted here.
RUN mkdir -p /workspace && chown node:node /workspace
WORKDIR /workspace

# Runtime env baked into the image so EVERY launch — compose, `docker exec`, or a one-off
# `docker run` (the claude-safe alias) — routes through the proxy and persists config.
# Placed after all network-using build steps so the build itself doesn't try to use the proxy.
# Herdr chooses new pane shells from $SHELL; set Bash explicitly so command and path completion work.
ENV SHELL=/bin/bash \
    CLAUDE_CONFIG_DIR=/home/node/.claude \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    DISABLE_AUTOUPDATER=1 \
    HTTP_PROXY=http://127.0.0.1:8888  HTTPS_PROXY=http://127.0.0.1:8888 \
    http_proxy=http://127.0.0.1:8888  https_proxy=http://127.0.0.1:8888 \
    NO_PROXY=localhost,127.0.0.1,::1  no_proxy=localhost,127.0.0.1,::1

EXPOSE 7681

# Healthy = the proxy is alive AND actively refusing non-allowlisted hosts. Asserts a real HTTP
# 403 from tinyproxy (a plain-HTTP request is filtered before DNS), which distinguishes
# "proxy filtering" from "proxy down" (a dead proxy yields 000, not 403). Needs no internet.
HEALTHCHECK --interval=30s --timeout=10s --start-period=25s --retries=3 \
  CMD pgrep -x tinyproxy >/dev/null 2>&1 \
      && [ "$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -x http://127.0.0.1:8888 http://example.com/ 2>/dev/null)" = "403" ]

# Starts as root to install firewall rules, drops to `node`, then runs the given command
# (e.g. `claude`) or, with no command, the ttyd web terminal.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
