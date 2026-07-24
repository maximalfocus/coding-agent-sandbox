# PLAN — GitHub issue 31

Source: `.cdd-auto/contracts/issue-31.md` (frozen)

## Goal

Remove Maven package example-credential noise from image-layer secret scans while retaining the intended final Maven proxy configuration and proving real proxy-backed dependency resolution.

## Approach

Delete `/etc/maven/settings.xml` at the end of the existing apt-install `RUN` instruction, before that layer is committed, then retain the existing later `COPY maven-settings.xml`. Add one fail-closed verifier covering Dockerfile ordering, final-file identity, scanner evidence, and suppression absence.

Alternatives rejected:

- **Delete in a later layer:** final filesystem is clean but deleted bytes remain attributable to the package layer and continue to trigger layer-aware scanning.
- **Trivy ignore rule:** suppresses evidence rather than removing the sample values and risks hiding future Maven credential findings.
- **Remove Maven:** breaks the Java/Maven toolchain requirement.

## Repo family

| Repo | Name | Purpose |
|---|---|---|
| PRD | This repository's `.cdd-auto/contracts/issue-31.md` | Frozen issue acceptance contract |
| Conformance | This repository's `scripts/verify-maven-secrets.sh` | Layer structure, image file, and Trivy secret-scan regression gate |
| Frontend Conformance | N/A | No frontend behavior |
| Implementation | `coding-agent-sandbox` | Dockerfile and assembled image |
| Architecture | Existing `docs/architecture/` unchanged | No architecture decision changes |
| CI/CD | Existing GitHub workflow unchanged | Existing image verification lifecycle |
| Infrastructure | Existing Docker Compose files unchanged | Runtime proxy/firewall configuration |

## Categories (core — language-neutral)

| # | Category | Boundary | Key behaviors | Est. tests | Deps | Risk |
|---|---|---|---|---:|---|---|
| 1 | Maven layer hygiene | lint-assertion | Same-layer deletion occurs after Maven install and before later project settings copy | 3 | none | high |
| 2 | Image secret scan | packaging-contract | Real container-image secret scan has no Maven password/passphrase findings and malformed evidence fails closed | 5 | 1 | high |
| 3 | Final Maven configuration | packaging-contract | Final file is byte-identical, proxy-owned, and credential-element-free | 3 | 1 | medium |
| 4 | Maven proxy resolution | e2e | Unprivileged Maven resolves through the running sandbox proxy | 1 | 3 | medium |

Total estimated checks: 12.

## Stack categories

N/A — Docker/Bash packaging boundaries are core and framework-neutral.

## Implementation order

1. Author and mutation-test the fail-closed verifier so the current Dockerfile is red.
2. Add the minimal same-layer deletion and re-run structural checks.
3. Rebuild and run the real Trivy secret scan plus final-file checks.
4. Run Maven dependency resolution in the assembled sandbox and acceptance demo.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Structural check passes a later-layer deletion | Secret bytes remain in scan history | Parse Dockerfile instruction boundaries and require deletion in the Maven-installing `RUN` |
| Empty/foreign scan report reads as clean | False-green scanner result | Validate non-empty JSON, container artifact type, result structure, and secret entries |
| Final settings drift | Maven bypasses sandbox proxy | Byte-compare image file to repository file and run dependency resolution |
| Suppression hides future secrets | Reduced scanner signal | Reject newly introduced Trivy ignore/config suppression surfaces |

## Open questions

None. The issue fixes the exact layer, final file, runtime behavior, and suppression boundary.

## Out of scope / Non-goals

- Maven/package upgrades.
- Changes to egress allowlists, proxy/firewall behavior, or container privileges.
- Suppressing unrelated Trivy findings.
- Remediating unrelated image secrets or CVEs.

## Decision boundaries

Implementation may choose the shell deletion form inside the existing apt `RUN`. It may not move deletion to another layer, alter the final project settings, add scanner ignores, or weaken scan evidence validation.

## Non-functional requirements

| Requirement | Target | Category | Boundary | Verified by |
|---|---|---|---|---|
| Scanner integrity | Missing/malformed/non-container evidence is red | Image secret scan | packaging-contract | verifier negative mutations |
| Reproducibility | No unpinned dependency or scanner suppression | Maven layer hygiene | lint-assertion | Dockerfile/config structural checks |
| Runtime compatibility | Maven resolves via sandbox proxy as `node` | Maven proxy resolution | e2e | acceptance verifier |

## Technology choices

| Decision | Choice | Rationale |
|---|---|---|
| Database | N/A | Image remediation stores no application data |
| Runtime/language version | Bash + Docker/Debian 12 | Existing build and verification surface |
| Framework | N/A | No application framework |
| Deployment target | Local multi-architecture Docker image | Existing product artifact |
| Testing framework | Fail-closed shell/Python verifier + Trivy JSON | Native deterministic packaging boundaries |
| Auth provider | N/A | No auth behavior changes |
| Cache/queue | N/A | No cache or queue |
