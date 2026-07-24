# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-24
- **Source of truth:** GitHub issue 30 and `.cdd-auto/contracts/issue-30.md`

## Problem

The packaged GitHub CLI, Docker Buildx, and Docker Compose binaries embed fixed HIGH-vulnerability Go components. Fixed stable packages are unavailable, so the affected binaries must be rebuilt from immutable upstream source without weakening their operation or the sandbox's Docker-daemon isolation boundary.

## Scope

- Build gh, Buildx, and Compose with digest-pinned Go 1.26.5 from full upstream commit pins.
- Remove the vulnerable docker/docker module from linked Buildx and Compose metadata while preserving its frozen random-name behavior.
- Prove all issue-listed findings absent from a successful, image-bound Trivy scan.
- Prove all CLIs work as `node`, default daemon access is denied, and the explicit host-Docker build/start/health/remove lifecycle passes.

## Non-goals

- Remediating unrelated Trivy findings.
- Replacing the fixed-version packaged Docker CLI, which has no issue-listed finding.
- Changing runtime firewall, egress allowlist, proxy model, container privileges, or normal Docker-daemon denial.
- Shipping Go source or a Go compiler in the runtime image.

## Acceptance criteria

- [x] `/usr/bin/gh` contains none of GHSA-hrxh-6v49-42gf or CVE-2026-39822.
- [x] Buildx contains none of CVE-2026-53488, CVE-2026-53489, CVE-2026-53492, CVE-2026-34040, GHSA-hrxh-6v49-42gf, or CVE-2026-39822.
- [x] Compose contains none of CVE-2026-34040, GHSA-hrxh-6v49-42gf, or CVE-2026-39822.
- [x] A digest-pinned Go 1.26.5 builder and full source commits produce Linux amd64/arm64 binaries; docker/docker is not linked into Buildx or Compose.
- [x] gh, docker, buildx, and compose run as `node`; default daemon access fails; explicit host-Docker build/start/health/remove succeeds.
- [x] Missing, malformed, foreign-image, missing-target, or affected Trivy evidence is red.

## Verification

```sh
set -euo pipefail
bash -n scripts/build-pinned-go-clis.sh scripts/verify-cli-security.sh .cdd-auto/demo/verify.sh
docker compose config >/dev/null
for f in docker-compose.host.yml docker-compose.mitm.yml docker-compose.sidecar.yml; do
  docker compose -f docker-compose.yml -f "$f" config >/dev/null
done
docker build -t coding-agent-sandbox:issue30 .
.cdd-auto/demo/verify.sh coding-agent-sandbox:issue30
bun run ~/personal/cdd-skills/tools/impl-stub-scan.ts .

bad="$(mktemp)"; trap 'rm -f "$bad"' EXIT
cp .cdd-auto/demo/expected-output.txt "$bad"
printf 'mutated\n' >>"$bad"
if EXPECTED_OUTPUT="$bad" .cdd-auto/demo/verify.sh coding-agent-sandbox:issue30 >/tmp/issue30-negative.out 2>&1; then
  echo 'acceptance output mutation unexpectedly passed' >&2
  exit 1
fi
```

The source build and live vulnerability scan require network/registry access on a cold cache. The final lifecycle check intentionally and temporarily mounts the host Docker socket, creates a uniquely named scratch-based image/container, and removes both.

## Residuals & assumptions

- Verification was executed on arm64. The builder accepts only Linux amd64/arm64 and uses architecture-neutral Go sources, but an amd64 build remains a maintainer/CI confirmation.
- The Claude peer CLI was absent, so every mandatory artifact review converged through the disclosed Codex host-native degraded fallback; the cross-vendor pass remains owed.
