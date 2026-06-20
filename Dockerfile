# Claude Code sandbox: the real CLI, locked inside a container.
# Base has Node (required by Claude Code) and a `node` user (uid 1000).
# Pinned by digest for reproducibility (update deliberately). Tag: node:20-bookworm.
FROM node:20-bookworm@sha256:8f693eaa7e0a8e71560c9a82b55fd54c2ae920a2ba5d2cde28bac7d1c01c9ba5

# Tools: tinyproxy (hostname-filtering egress proxy), iptables/iproute2 (force traffic
# through it), dev basics, gosu for dropping root. No `sudo`: the firewall is installed by the
# root entrypoint, never re-run by the unprivileged user (smaller post-start privilege surface).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ripgrep tmux less procps \
      curl ca-certificates dnsutils \
      tinyproxy iptables iproute2 \
      gosu socat \
    && rm -rf /var/lib/apt/lists/*

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

# The real Claude Code CLI, pinned at BUILD time (override with --build-arg). Runtime auto-update
# is DISABLED below (DISABLE_AUTOUPDATER) so the running CLI stays exactly this version — no
# unreviewed binary drift mid-session. To update Claude, bump the arg and rebuild.
# (The base image and ttyd are also pinned; apt packages come from moving Debian repos.)
ARG CLAUDE_CODE_VERSION=2.1.158
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# Codex CLI (OpenAI) for cross-vendor peer review, pinned at BUILD time. Authenticated separately
# with your ChatGPT/OpenAI subscription via ./codex-login.sh; egress is gated by ALLOW_OPENAI.
ARG CODEX_VERSION=0.140.0
RUN npm install -g "@openai/codex@${CODEX_VERSION}"

# bun — runtime for the cdd-skills TypeScript tools (metrics-baseline, golden-lint, coverage-review,
# scaffold-runner, conformance-validate) that /cdd and /cdd-evolve invoke via `bun run`. Those tools
# use only Node/Bun stdlib (no package.json), so the runtime alone is enough — no dependency install.
# Pinned to match the host; bump deliberately.
ARG BUN_VERSION=1.3.11
RUN npm install -g "bun@${BUN_VERSION}"

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
# Shared tmux launcher: attach to the 'claude' session, building the 2x2 grid on first use. Used by
# every entry point (browser ttyd + shell.sh/shell.ps1 --attach) so the grid is identical everywhere.
COPY tmux-grid.sh     /usr/local/bin/sandbox-tmux
# Strip any CR line endings so the container boots even if the build context was checked out on
# Windows with CRLF (a `bash\r` shebang otherwise fails with "no such file"). Belt-and-suspenders
# with .gitattributes (which forces LF on checkout); also normalize the proxy config copied above.
RUN sed -i 's/\r$//' /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
        /usr/local/bin/sandbox-tmux /etc/tinyproxy/tinyproxy.conf \
    && chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/sandbox-tmux

# Claude's view of your files: only what gets mounted here.
RUN mkdir -p /workspace && chown node:node /workspace
WORKDIR /workspace

# Runtime env baked into the image so EVERY launch — compose, `docker exec`, or a one-off
# `docker run` (the claude-safe alias) — routes through the proxy and persists config.
# Placed after all network-using build steps so the build itself doesn't try to use the proxy.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
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
