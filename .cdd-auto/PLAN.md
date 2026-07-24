# PLAN — GitHub issue 29

Source: `.cdd-auto/contracts/issue-29.md` (frozen)

## Approach

Prefer updating the exact `node:22-bookworm` base-image digest so the Debian package snapshot naturally contains the fixed packages. If the current upstream digest is insufficient, add one explicit Debian package-upgrade step in the existing apt layer; do not add a second package cache layer. This preserves reproducibility while minimizing Dockerfile change surface.

Alternatives rejected:

- **Unpinned base tag:** receives fixes but sacrifices reproducibility.
- **Suppress the advisories:** does not remediate vulnerable packages.
- **Upgrade every package indiscriminately in a later layer:** increases drift and image size while duplicating apt cleanup.

## Work

1. **Conformance first:** add `scripts/verify-debian-security.sh`. It must inspect every installed ImageMagick-family occurrence with Debian-aware version comparison, require the Linux header floor, consume a successful HIGH/CRITICAL Trivy JSON report (the scan must complete and parse; a clean strict gate is not required, since unrelated fixed findings are out of scope), and fail closed on missing/empty/malformed/failed scanner evidence.
2. **Implementation:** update the pinned base digest; only if necessary, explicitly upgrade the named Debian package families within the existing apt install/cleanup layer.
3. **Acceptance:** rebuild `coding-agent-sandbox:latest`; run the package/advisory verifier; run Java, Maven, Playwright, bundled-agent, proxy, and firewall smoke gates; emit a runnable demo.
4. **Review and delivery:** cross-vendor review each artifact wave, create a linked PR with `Closes #29`, merge only after all gates pass, confirm issue closure, and delete the dedicated branch.

## Non-functional requirements

| Requirement | Target | Verified by |
|---|---|---|
| Reproducibility | Base image remains digest-pinned | Dockerfile structural assertion |
| Scanner integrity | Missing/empty/malformed/failed Trivy evidence is red | verifier negative mutations |
| Runtime compatibility | Existing toolchain and network-isolation smoke checks remain green | acceptance verifier |

## Technology choices

| Decision | Choice | Rationale |
|---|---|---|
| Database | N/A | Container image remediation stores no application data |
| Runtime/language | Bash + Docker/Debian 12 | Existing build and verification surface |
| Framework | N/A | No application framework |
| Deployment target | Local multi-architecture Docker image | Existing product artifact |
| Testing framework | Fail-closed shell verifier + Trivy JSON | Native deterministic boundaries |
| Auth provider | N/A | No auth behavior changes |
| Cache/queue | N/A | No cache or queue |

## Decision boundaries

Implementation may choose base-digest-only versus explicit package upgrades based on observed package versions. It may not loosen CVE absence, package floors, base digest pinning, or existing smoke expectations.

## Out of scope

- Remediating unrelated Trivy findings.
- Changing the runtime firewall, egress allowlist, proxy model, or container privileges.
- Upgrading unrelated bundled toolchains except where the new base requires compatibility repair.
