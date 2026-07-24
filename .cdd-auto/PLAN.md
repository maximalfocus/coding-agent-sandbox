# PLAN — GitHub issue 30

Source: `.cdd-auto/contracts/issue-30.md` (user-amended and frozen on resume)

## Approach

Build GitHub CLI, Buildx, and Compose from immutable upstream commit pins in a digest-pinned Go 1.26.5 multi-stage builder. Buildx currently links `github.com/docker/docker` only for its frozen random-name generator; copy that frozen package into Buildx's internal tree and change the one import so no vulnerable docker/docker module is linked. Build Compose against that same patched Buildx tree. Install the resulting architecture-native static binaries over the apt-provided gh/plugins while retaining the exact packaged Docker CLI pin.

Alternatives rejected:

- **Wait for stable packages:** rejected by the user's resume amendment.
- **Install prerelease binaries only:** no fixed gh/Compose prerelease exists, and Buildx 0.36.0-rc1 still links vulnerable docker/docker.
- **Suppress Trivy findings:** does not remediate vulnerable code.
- **Force a nonexistent docker/docker v29.3.1 module:** the fixed version Trivy names has no upstream tag and cannot be resolved by Go.

## Work

1. **Conformance first:** add a fail-closed verifier for all eleven issue findings. It validates a real non-empty container-image Trivy report, requires scan targets for each affected binary, rejects malformed/missing/foreign evidence, checks immutable source/builder pins structurally, runs all four CLIs as `node`, and proves default Docker-daemon access remains absent.
2. **Implementation:** add one deterministic source-build script and a digest-pinned Go builder stage; source commits and Go module sums are the integrity pins. Keep the runtime free of source/build toolchain residue.
3. **Acceptance:** rebuild, run the verifier, run the opt-in host-Docker build/start/health/remove lifecycle, and emit byte-stable demo output plus screenshot.
4. **Review and delivery:** run the required review after every wave (disclosed degraded Codex-native fallback because the Claude CLI probe failed), create a linked PR with `Closes #30`, merge only after all gates pass, confirm issue closure, and delete the dedicated branch.

## Non-functional requirements

| Requirement | Target | Verified by |
|---|---|---|
| Reproducibility | Go builder digest and all upstream commits immutable | verifier structural gate |
| Architecture coverage | TARGETARCH-driven Linux amd64/arm64 builds | Docker multi-stage build plus source-build script |
| Scanner integrity | Missing/empty/malformed/foreign/no-target scan evidence is red | verifier negative mutations |
| Runtime compatibility | CLI and host-Docker lifecycle remain green as `node` | acceptance verifier |
| Least privilege | Default Compose grants no Docker socket/device | verifier structural and runtime denial checks |

## Technology choices

| Decision | Choice | Rationale |
|---|---|---|
| Database | N/A | Container toolchain remediation stores no application data |
| Runtime/language | Bash + Docker + Go 1.26.5 | Existing image boundary and affected binaries' upstream language |
| Framework | N/A | No application framework |
| Deployment target | Local multi-architecture Docker image | Existing product artifact |
| Testing framework | Fail-closed shell/Python verifier + Trivy JSON | Native deterministic boundaries |
| Auth provider | N/A | No auth behavior changes |
| Cache/queue | N/A | No cache or queue |

## Decision boundaries

Implementation may select exact post-release upstream commits that satisfy the frozen dependency floors. It may not use moving refs at build time, weaken Trivy evidence validation, change default daemon isolation, or replace the packaged Docker CLI without a listed finding requiring it.

## Out of scope

- Remediating unrelated Trivy findings.
- Changing runtime firewall, egress allowlist, proxy model, container privileges, or default Docker-daemon denial.
- Shipping Go source or the Go compiler in the runtime image.
