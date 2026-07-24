# Issue 29 acceptance contract — Debian ImageMagick and Linux headers

Source of truth: https://github.com/maximalfocus/coding-agent-sandbox/issues/29

## Reproduction

Build the image from the currently pinned base and inspect the installed Debian packages: ImageMagick resolves to `8:6.9.11.60+dfsg-1.6+deb12u12`, `linux-libc-dev` resolves to `6.1.176-1`, and Trivy reports the issue's fixed HIGH advisories.

## Scenario 1 — ImageMagick package family is patched

**Given** a freshly rebuilt `coding-agent-sandbox:latest` image
**When** every installed `imagemagick`, `libmagickcore-*`, and `libmagickwand-*` package is inspected
**Then** every installed occurrence is at least Debian version `8:6.9.11.60+dfsg-1.6+deb12u13`.

## Scenario 2 — Linux development headers are patched

**Given** the freshly rebuilt image
**When** the installed `linux-libc-dev` package is inspected
**Then** its Debian version is at least `6.1.177-1`.

## Scenario 3 — reported advisories are absent

**Given** a successful Trivy HIGH/CRITICAL JSON report for the rebuilt image
**When** vulnerability IDs are inspected
**Then** CVE-2026-61857, CVE-2026-61863, CVE-2026-61866, CVE-2026-61870, CVE-2026-53138, CVE-2026-53157, CVE-2026-53359, CVE-2026-53362, CVE-2026-53398, CVE-2026-63794, CVE-2026-63795, CVE-2026-63824, CVE-2026-63830, CVE-2026-63831, and CVE-2026-64191 are absent
**And** a missing, empty, malformed, or failed scan cannot pass as absence.

## Scenario 4 — existing image capabilities remain healthy

**Given** the patched image
**When** the existing Java, Maven, Playwright, npm-agent CLI, proxy, and firewall smoke gates run
**Then** each remains green.

## Scope

Update the pinned Node/Debian base digest and/or install fixed Debian security updates, add deterministic regression verification, and refresh the acceptance demo/charter. Unrelated vulnerability remediation and runtime capability changes are non-goals.
