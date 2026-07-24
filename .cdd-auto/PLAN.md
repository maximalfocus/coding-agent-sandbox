# PLAN — GitHub issue 32

Source: `.cdd-auto/contracts/issue-32.md` (frozen)

## Approach

Keep Docker's built-in seccomp profile, `no-new-privileges`, and minimal capability set unchanged. The measured preflight matrix in `.cdd-auto/evidence/issue-32-preflight.md` shows that, on Docker Desktop 29.4.0/macOS-arm64, Docker's built-in seccomp profile blocks the user-namespace syscall path used by both Codex's bundled bubblewrap and Debian bubblewrap; removing `no-new-privileges` alone does not help, while a disposable `seccomp=unconfined` diagnostic does. The portable verifier must still classify other host/runtime restrictions independently. Because replacing or broadly disabling the outer seccomp boundary to add a second inner layer expands host-kernel attack surface and is not portable across Docker/runtime versions, select the documented outer-container fallback rather than weakening the primary boundary.

Add a fail-closed verifier around `codex sandbox`: use `:workspace` when nested namespaces work; otherwise accept only the known namespace-init failure and run `:danger-full-access` as the explicit externally-sandboxed fallback while testing the outer filesystem and network controls. Preserve Codex's bundled binary for compatible runtimes; do not install Debian bubblewrap merely to remove a warning.

Alternatives rejected:

- **Install Debian bubblewrap:** removes only the PATH warning; the same namespace syscall fails.
- **Add `SYS_ADMIN` or privileged mode:** materially defeats the least-privilege boundary.
- **Use `seccomp=unconfined`:** makes nested bubblewrap work but broadly removes the outer syscall filter.
- **Vendor a complete custom Docker seccomp profile:** a fork of the runtime's evolving built-in profile is high-maintenance and can silently become weaker or incompatible; no portable additive profile mechanism exists.

## Work

1. **Conformance first:** add a deterministic host-side verifier that runs real `codex sandbox` commands, classifies nested support, and proves the selected nested or fallback filesystem/network restrictions. Explicit negatives cover missing Codex, an unrecognized nested error, malformed/false-green result output, and version-only evidence. A separate disposable PATH fixture runs Debian bubblewrap operationally and proves that warning disappearance without namespace success remains red.
2. **Implementation:** wire no security relaxations and no Debian bubblewrap package; make the verifier support default, MITM, and sidecar service selection without embedding credentials.
3. **Documentation:** explain the two observed warnings/errors, the seccomp attribution matrix, supported/unsupported runtime combinations, the explicit fallback, and the security rationale in `README.md` and `SECURITY.md`.
4. **Acceptance:** run the verifier against the live default stack; run the operational namespace command `bwrap --ro-bind / / --proc /proc --dev /dev /bin/true` through default, MITM, and sidecar service definitions (never a version-only check); diff byte-stable output against a committed expected file and render a screenshot.
5. **Repository hygiene:** commit the final run trace, then remove `.cdd-auto/` from the delivered tree and add `.cdd-auto/` to `.gitignore`; the merged PR history remains the audit record.
6. **Review and delivery:** cross-vendor review every wave, using a probed non-OpenAI OpenCode model when Claude CLI is unavailable; create a linked PR with `Closes #32`, merge only after all gates pass, confirm issue closure, and delete the dedicated branch.

## Conformance categories

| # | Category | Boundary | Key behaviors | Est. tests | Deps | Risk |
|---|---|---|---|---:|---|---|
| 1 | `nested-classification` | CLI | real `codex sandbox :workspace`; bundled-vs-Debian-PATH operational probes; success vs exact namespace-blocked fallback; missing Codex/unrecognized error/version-only evidence red | 8 | none | high |
| 2 | `filesystem` | CLI | workspace write succeeds; protected outside write denied | 3 | 1 | high |
| 3 | `network` | CLI | nested network denied; fallback proxy refusal and direct-IP denial | 4 | 1 | high |
| 4 | `variant-controls` | workflow assertion | default/MITM/sidecar retain seccomp + NNP + minimal caps; forbidden relaxations absent | 5 | none | high |
| 5 | `documentation` | lint assertion | behavior matrix, fallback command, trade-off, warning-not-success language | 5 | 1,4 | medium |
| 6 | `repository-hygiene` | lint assertion | `.cdd-auto/` absent from tip and ignored; final audit retained in PR history | 3 | 1–5 | medium |

## Implementation order

1. Pin the static security-control and documentation contract first so implementation cannot normalize a relaxation.
2. Implement the real-command verifier and prove it fails against malformed/unexpected evidence.
3. Add the safe fallback implementation path and variant selection.
4. Update documentation from measured evidence, then run live acceptance.
5. Freeze the final audit checkpoint before deleting and ignoring `.cdd-auto/` at the delivered tip.

## Non-functional requirements

| Requirement | Target | Verified by |
|---|---|---|
| Least privilege | no privileged mode, host namespace sharing, `SYS_ADMIN`, or unconfined seccomp | `variant-controls` |
| Fail closed | only the exact namespace-init failure selects fallback; all other failures red | `nested-classification` |
| Portability | clear outcome on default, MITM, and sidecar profiles without requiring auth for local sandbox command | live verifier + variant probes |
| Security | workspace/protected-filesystem/network restrictions tested by actual commands | `filesystem`, `network` |
| Determinism | byte-stable result lines and explicit exit status | demo `verify.sh` |
| Repository hygiene | no workflow-only `.cdd-auto/` files at delivered tip | `repository-hygiene` |

## Technology choices

| Decision | Choice | Rationale |
|---|---|---|
| Database | N/A | No application data is stored |
| Runtime/language | Bash + Docker Compose + pinned Codex CLI | Existing product and deterministic local sandbox command |
| Framework | N/A | Shell verifier is the native boundary |
| Deployment target | Existing local Docker default/MITM/sidecar variants | Scope named by issue |
| Testing framework | fail-closed Bash verifier + Docker inspection | Tests real runtime controls without model nondeterminism |
| Auth provider | N/A for `codex sandbox`; existing OpenAI login unchanged | Local sandbox command requires no inference |
| Cache/queue | N/A | No asynchronous state |

## Decision boundaries

Implementation may choose stable output labels, temporary fixture paths, Compose/service selector flags, and a probed non-OpenAI OpenCode peer when Claude CLI is unavailable. It may not relax shipped container controls, install bubblewrap solely to hide the warning, broaden egress, treat version output as success, silently fall back on an unrecognized error, or delete the active audit before its final checkpoint is committed.

## Out of scope

- A custom Docker seccomp-profile fork.
- Host kernel/sysctl reconfiguration.
- Privileged, host-namespace, or `SYS_ADMIN` execution.
- Changes to authentication, proxy policy, or sidecar experimental status.
