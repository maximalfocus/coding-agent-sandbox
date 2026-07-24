# Conformance Plan: opt-in AWS CLI v2 and isolated IAM Identity Center profiles

## Goal
Add sandbox-native AWS CLI v2 + IAM Identity Center support while preserving the existing fail-closed filesystem and egress trust boundaries.

## Approach
**Recommended:** install one pinned, checksum-verified AWS CLI in the base image; use explicit Compose override files to attach one dedicated named volume only to agent services; derive an exact three-host allowlist from validated region identifiers; document sandbox-native setup and lifecycle.

Alternatives rejected: mounting host `~/.aws` exposes unrelated profiles and bearer caches; environment credentials expose secrets and rotate poorly; putting AWS state in the egress sidecar violates its proxy-only trust boundary; a broad `amazonaws.com` rule grants every AWS service endpoint.

## Repo family
| Repo | Name | Purpose |
|---|---|---|
| PRD/plan | this repo `.cdd-auto/` during delivery | Frozen issue contract and plan |
| Conformance | this repo `scripts/test-aws-sso-support.sh` | Static and executable security/packaging contract |
| Implementation | `coding-agent-sandbox` | Docker image, Compose overrides, allowlist generation, docs |
| Architecture | this repo SECURITY.md + docs/architecture/ | Existing container/sidecar trust boundaries; no new standalone ADR repo |
| CI/CD | N/A | Existing project has no dedicated workflow for this shell/Docker surface |
| Infrastructure | Docker Compose | Optional named volume and service-local mounts |

## Categories (core — language-neutral)
| # | Category | Boundary | Key behaviors | Est. tests | Deps | Risk |
|---|---|---|---|---:|---|---|
| 1 | packaging | packaging-contract | pinned version, two arch checksums, arch selection, installed binary | 5 | none | high |
| 2 | state-isolation | structural-contract | opt-in only; dedicated volume; agent-only; sidecar exclusion | 8 | none | high |
| 3 | regional-egress | function | `AWS_SSO_REGIONS` input; exact endpoint derivation; multi-region; malformed/global rejection | 8 | none | high |
| 4 | operations-docs | documentation-contract | setup/login/verify/logout/reset and security warnings | 8 | 1–3 | medium |

## Implementation order
1. Author a failing contract gate for all four categories so security boundaries are executable first.
2. Add the pinned CLI installation and region-to-host helper.
3. Add per-stack opt-in volume overrides attaching the dedicated volume only to each stack's agent service — default `claude-sandbox`, MITM `claude-sandbox-mitm`, sidecar `claude-sandbox-node` (never `claude-sandbox-egress`).
4. Add operational/security documentation, then run the full gate and Docker build smoke.

## Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| Wrong architecture or mutable installer | Supply-chain failure / unusable image | Exact version + per-arch SHA-256 + build-time architecture switch |
| AWS token reaches host or egress sidecar | Trust-boundary breach | Named volume only; structural tests enumerate every service mount |
| Region setting broadens egress | AWS-wide network capability | Parse region tokens and emit only three exact hostnames; reject invalid input |
| Reset command deletes unrelated auth | User loses sandbox logins | Name only `coding-agent-sandbox-aws`; explicit destructive warning |
| Docs leak credentials through diagnostics | Secret disclosure | Permit identity metadata only; forbid cache/env/audit dumps |

## Open questions
None. The issue fixes the trust boundary, profile model, endpoint granularity, and verification command; implementation details remain within those constraints.

## Out of scope / Non-goals
- No host `~/.aws` bind mount, static access keys, environment credentials, image-baked profiles/tokens, administrator-role automation, broad AWS service allowlist, or AWS state in the egress sidecar.
- No automatic SSO browser authentication, account/role provisioning, or service-specific egress beyond Identity Center/OIDC and STS.

## Decision boundaries
The implementation may choose exact helper/file names and documentation placement. It may not broaden endpoint scope, move credential state across the agent boundary, change the frozen CLI version/checksums, or weaken opt-in behavior without an acceptance-ambiguous pause.

## Non-functional requirements
| Requirement | Target | Category | Boundary | Verified by |
|---|---|---|---|---|
| Supply-chain integrity | exact SHA-256 per supported arch | packaging | packaging-contract | `scripts/test-aws-sso-support.sh` |
| Least privilege | no default mount; agent-only opt-in | state-isolation | structural-contract | Compose parser assertions |
| Egress minimization | exactly 3 endpoint classes per valid region | regional-egress | function | helper positive/negative tests |
| Secret-safe operations | no token/key/cache output guidance | operations-docs | documentation-contract | required/forbidden docs assertions |

## Technology choices
| Decision | Choice | Rationale |
|---|---|---|
| Database | N/A | Docker sandbox tooling stores AWS CLI state in a dedicated volume |
| Runtime/language version | Bash on Debian Bookworm, Docker Compose v2 | Existing project runtime and configuration surface |
| Framework | Dockerfile + Compose overlays | Native image and opt-in mount mechanism |
| Deployment target | Local Docker Engine / compatible Compose runtime | Existing sandbox target |
| Testing framework | Bash + Python/YAML-aware Compose rendering | Existing project verification style |
| Auth provider | AWS IAM Identity Center (SSO) | Issue requirement; short-lived role credentials |
| Cache/queue | Docker named volume `coding-agent-sandbox-aws` | Isolated persistence across restarts |
