# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-24
- **Source of truth:** GitHub issue 28 and `.cdd-auto/contracts/issue-28.md`

## Problem

The pinned Node base image bundles npm 10.9.8 with one CRITICAL and four HIGH fixed vulnerabilities in npm's internal dependency tree. The image needs a coherent patched npm distribution without breaking its bundled coding-agent tools.

## Scope

- Pin and install a Node-compatible patched npm distribution before global CLI installation.
- Verify every occurrence of the four named npm-internal packages meets the issue's fixed version floor.
- Verify the npm-installed CLIs still start and the five reported CVEs disappear from Trivy output.

## Non-goals

- Changing the Node base-image digest.
- Fixing unrelated Debian or third-party CLI findings.
- Changing egress, isolation, or runtime capabilities.

## Acceptance criteria

- [x] npm is upgraded as a complete exact-pinned distribution, not by mutating its internal dependencies.
- [x] npm's `tar`, `brace-expansion`, `picomatch`, and `sigstore` installations meet the fixed floors in issue 28.
- [x] `TRIVY_SEVERITY=CRITICAL TRIVY_STRICT=1 ./scan.sh` passes and the five named CVEs are absent from the HIGH/CRITICAL report.
- [x] npm, Claude Code, Codex, OpenCode, Pi, Bun, and Playwright start successfully.

## Verification

```sh
set -euo pipefail
bash -n scripts/verify-npm-bundle.sh
docker compose config >/dev/null
docker compose build claude-sandbox
./scripts/verify-npm-bundle.sh
TRIVY_SEVERITY=CRITICAL TRIVY_STRICT=1 ./scan.sh
TRIVY_SEVERITY=HIGH,CRITICAL ./scan.sh > /tmp/issue28-trivy.txt
if grep -E 'CVE-2026-(59873|59874|13149|33671|48815)' /tmp/issue28-trivy.txt; then
  echo 'issue-28 CVEs remain' >&2; exit 1
else
  rc=$?; [ "$rc" -eq 1 ] || exit "$rc"
fi
```

The build and Trivy steps use Docker state/cache and require registry/network access on a cold cache.

## Residuals & assumptions

- The HIGH/CRITICAL report still contains unrelated fixed HIGH findings outside issue 28; strict acceptance intentionally gates CRITICAL severity as requested.
- Verification was run on arm64; the npm package graph is architecture-independent, while the existing multi-architecture CLI installation remains covered by its pinned package selection.
