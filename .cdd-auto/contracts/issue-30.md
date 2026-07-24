# Issue 30 acceptance contract — fixed embedded Go dependencies in CLI binaries

Source of truth: https://github.com/maximalfocus/coding-agent-sandbox/issues/30
User scope amendment: 2026-07-24 — pinned upstream source builds are allowed; stable releases are not required.

## Reproduction

Build `coding-agent-sandbox:latest` from the current pins. Trivy reports the issue's fixed HIGH findings in `/usr/bin/gh`, `/usr/libexec/docker/cli-plugins/docker-buildx`, and `/usr/libexec/docker/cli-plugins/docker-compose`.

## Scenario 1 — GitHub CLI findings are absent

**Given** a freshly rebuilt image using a commit-pinned upstream GitHub CLI source build
**When** a successful Trivy HIGH/CRITICAL scan inspects `/usr/bin/gh`
**Then** `GHSA-hrxh-6v49-42gf` and `CVE-2026-39822` are absent
**And** the embedded gRPC and Go versions are at least 1.82.1 and 1.26.5 respectively.

## Scenario 2 — Docker Buildx findings are absent

**Given** the rebuilt image using a commit-pinned upstream Buildx source build
**When** the successful scan inspects the Buildx plugin
**Then** CVE-2026-53488, CVE-2026-53489, CVE-2026-53492, CVE-2026-34040, GHSA-hrxh-6v49-42gf, and CVE-2026-39822 are absent
**And** vulnerable `github.com/docker/docker` code is not linked
**And** embedded containerd/v2, gRPC, and Go versions meet Trivy's fixed floors.

## Scenario 3 — Docker Compose findings are absent

**Given** the rebuilt image using a commit-pinned upstream Compose source build and the same patched Buildx source tree
**When** the successful scan inspects the Compose plugin
**Then** CVE-2026-34040, GHSA-hrxh-6v49-42gf, and CVE-2026-39822 are absent
**And** vulnerable `github.com/docker/docker` code is not linked
**And** embedded containerd/v2, gRPC, and Go versions meet Trivy's fixed floors.

## Scenario 4 — CLI operation and isolation are preserved

**Given** the rebuilt image starts as the unprivileged `node` user
**When** `gh --version`, `docker --version`, `docker buildx version`, and `docker compose version` run
**Then** each succeeds
**And** the opt-in host-Docker build/start/health/remove smoke workflow passes
**And** the default Compose configuration still exposes no Docker daemon socket or equivalent daemon capability.

## Scope

Build affected CLIs from immutable upstream commit pins with Go 1.26.5 or newer, preserve amd64 and arm64 coverage, retain Go module checksum verification, add fail-closed regression verification, and refresh the acceptance demo and charter. The packaged Docker CLI may remain at its current exact pin because the issue lists no finding in that binary; it must remain operational. Pre-release tags and commit-pinned upstream source are allowed. Unrelated vulnerability remediation and changes to the Docker-daemon capability boundary are non-goals.
