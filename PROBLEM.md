# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-25
- **Source of truth:** https://github.com/maximalfocus/coding-agent-sandbox/issues/32 and the issue-32 contract/audit retained in this PR's commit history

## Problem

Codex warns that bubblewrap is absent, then its bundled binary cannot create a nested user namespace under the sandbox container's Docker controls. The repository must either provide functional nested sandboxing without weakening the primary boundary or document and verify a safe outer-container fallback.

## Scope

- In: reproduce bundled and Debian-PATH bubblewrap behavior; identify the blocking controls for default, MITM, and sidecar agent variants; retain least privilege; provide a real-command smoke; document supported behavior and trade-offs; exclude `.cdd-auto/` from the delivered tree.

## Non-goals

- Out: privileged mode, `SYS_ADMIN`, host namespace sharing, `seccomp=unconfined`, a forked full Docker seccomp profile, host sysctl changes, or installing Debian bubblewrap merely to suppress a warning.
- Out: claiming Docker is a VM or changing auth, token, proxy policy, or the sidecar's experimental status.

## Acceptance criteria

- [x] AC1 — The measured matrix separately records the no-PATH bundled warning/failure and Debian bubblewrap's warning-free but functionally identical namespace failure.
- [x] AC2 — Default, MITM, sidecar-agent, and sidecar-egress static controls retain `cap_drop: ALL`, `no-new-privileges`, no `SYS_ADMIN`, no privileged/host namespace mode, and no unconfined seccomp.
- [x] AC3 — `scripts/verify-codex-sandbox.sh` runs `codex sandbox -P :workspace`; only a known namespace-init failure selects the explicit `:danger-full-access` outer fallback.
- [x] AC4 — The live smoke proves workspace write succeeds while protected filesystem write, non-allowlisted proxy egress, and direct-IP egress are denied; missing Codex, unknown errors, malformed output, and unsafe controls fail closed.
- [x] AC5 — README, SECURITY, and `docs/codex-sandbox.md` state the supported variants, exact fallback, warning-vs-function distinction, and security trade-off without recommending boundary relaxation.
- [x] AC6 — `.cdd-auto/` is ignored and absent from the delivered repository tip; its final audit/demo state remains available in PR history.

## Verification

Requires Docker, Python 3, a running healthy default `claude-sandbox`, and its local proxy/firewall. The live command performs one blocked proxy request and one blocked direct-IP request from inside that container; it makes no successful external request and changes no host configuration.

```sh
set -euo pipefail
bash -n scripts/verify-codex-sandbox.sh scripts/test-codex-sandbox-verifier.sh
scripts/test-codex-sandbox-verifier.sh
scripts/verify-codex-sandbox.sh --variant default --container claude-sandbox
scripts/test-codex-sandbox-verifier.sh --delivery
```

## Residuals & assumptions

- Nested bubblewrap may work under a separately reviewed runtime/seccomp policy that permits user namespaces; shipped Docker built-in-seccomp profiles intentionally use the outer fallback.
- The operational matrix was measured on Docker Desktop/Engine 29.4.0 on macOS arm64. Other kernels/runtimes can block user namespaces for additional reasons; unknown failures remain fail-closed.
- MITM and sidecar agent live probes passed on the measured runtime; the deterministic gate statically covers all services and live-default behavior but does not launch every optional stack on every review run.
