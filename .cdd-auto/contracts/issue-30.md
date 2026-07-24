# Issue 30 acceptance contract — fixed embedded Go dependencies in CLI binaries

Source of truth: https://github.com/maximalfocus/coding-agent-sandbox/issues/30

## Reproduction

Build `coding-agent-sandbox:latest` from the current pins. Trivy reports the issue's fixed HIGH findings in `/usr/bin/gh`, `/usr/libexec/docker/cli-plugins/docker-buildx`, and `/usr/libexec/docker/cli-plugins/docker-compose`.

## Scenario 1 — GitHub CLI findings are absent

**Given** a freshly rebuilt image using a fixed stable upstream GitHub CLI package
**When** a successful Trivy HIGH/CRITICAL scan inspects `/usr/bin/gh`
**Then** `GHSA-hrxh-6v49-42gf` and `CVE-2026-39822` are absent
**And** the embedded gRPC and Go versions are at least 1.82.1 and 1.26.5 respectively.

## Scenario 2 — Docker Buildx findings are absent

**Given** the rebuilt image using a fixed stable upstream Buildx package
**When** the successful scan inspects the Buildx plugin
**Then** CVE-2026-53488, CVE-2026-53489, CVE-2026-53492, CVE-2026-34040, GHSA-hrxh-6v49-42gf, and CVE-2026-39822 are absent
**And** the embedded containerd/v2, docker/docker, gRPC, and Go versions meet Trivy's fixed floors.

## Scenario 3 — Docker Compose findings are absent

**Given** the rebuilt image using a fixed stable upstream Compose package
**When** the successful scan inspects the Compose plugin
**Then** CVE-2026-34040, GHSA-hrxh-6v49-42gf, and CVE-2026-39822 are absent
**And** the embedded docker/docker, gRPC, and Go versions meet Trivy's fixed floors.

## Scenario 4 — CLI operation and isolation are preserved

**Given** the rebuilt image starts as the unprivileged `node` user
**When** `gh --version`, `docker --version`, `docker buildx version`, and `docker compose version` run
**Then** each succeeds
**And** the opt-in host-Docker build/start/health/remove smoke workflow passes
**And** the default Compose configuration still exposes no Docker daemon socket or equivalent daemon capability.

## Scope resolution

Only fixed **stable upstream package releases** are acceptable. Pre-release binaries and custom source builds are out of scope. On 2026-07-24, the latest stable packages remain GitHub CLI 2.96.0, Buildx 0.35.0, and Compose 5.3.1; their binaries still embed one or more vulnerable versions listed above. The run therefore pauses until fixed stable upstream releases are available.

## Scope

When fixed stable releases become available, update all affected version pins and any associated integrity/checksum pins together, preserve amd64 and arm64 coverage, add fail-closed regression verification, and refresh the acceptance demo and charter. Unrelated vulnerability remediation and changes to the Docker-daemon capability boundary are non-goals.
