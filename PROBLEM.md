# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-24
- **Source of truth:** GitHub issue 29 and `.cdd-auto/contracts/issue-29.md`

## Problem

The pinned Debian 12 base contains ImageMagick `deb12u12` and `linux-libc-dev 6.1.176-1`, producing 63 HIGH Trivy package occurrences across 15 fixed advisories. The image needs patched Debian packages without regressing its bundled development tools or network-isolation boundary.

## Scope

- Refresh the existing apt layer to install every present ImageMagick-family package at `deb12u13` or newer and `linux-libc-dev` at `6.1.177-1` or newer.
- Verify package floors with Debian version semantics and prove all 15 named CVEs absent from a successful Trivy container-image scan.
- Verify Java, Maven, Playwright, bundled npm agent CLIs, proxy health, and firewall bypass prevention.

## Non-goals

- Remediating unrelated Trivy findings.
- Changing the Node base tag/digest, runtime firewall, egress allowlist, proxy model, or container privileges.
- Upgrading unrelated bundled toolchains.

## Acceptance criteria

- [x] Every installed `imagemagick*`, `libmagickcore-*`, and `libmagickwand-*` occurrence is at least `8:6.9.11.60+dfsg-1.6+deb12u13`.
- [x] Installed `linux-libc-dev` is at least `6.1.177-1`.
- [x] A successful HIGH/CRITICAL Trivy JSON container-image scan contains none of the 15 CVEs named by issue 29; missing, empty, malformed, no-result, failed, or affected evidence is red.
- [x] Java, Maven, Playwright, npm-installed agent CLIs, proxy health/refusal, and direct-bypass firewall checks remain green.

## Verification

```sh
set -euo pipefail
bash -n scripts/verify-debian-security.sh .cdd-auto/demo/verify.sh
docker compose config >/dev/null
docker compose build claude-sandbox
.cdd-auto/demo/verify.sh

bad="$(mktemp)"; trap 'rm -f "$bad"' EXIT
cp .cdd-auto/demo/expected-output.txt "$bad"
printf 'unexpected-line\n' >> "$bad"
if EXPECTED_OUTPUT="$bad" .cdd-auto/demo/verify.sh >/tmp/issue29-negative.out 2>&1; then
  echo 'acceptance output mutation unexpectedly passed' >&2
  exit 1
fi
```

The build, container recreation, and live Trivy scan use Docker state/cache and require registry/network access on a cold cache.

## Residuals & assumptions

- Verification was executed on arm64. The Node base is a multi-architecture manifest and the explicitly named Debian packages are available under the same names on amd64; CI/maintainer builds retain the second-architecture confirmation.
- Unrelated fixed HIGH findings may remain and are outside issue 29. The gate rejects the named advisories rather than claiming the entire image has zero HIGH findings.
