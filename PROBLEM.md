# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-25
- **Source of truth:** https://github.com/maximalfocus/coding-agent-sandbox/issues/33 and the frozen issue-33 contract retained in this PR's commit history

## Problem
The sandbox needs AWS CLI v2 and a safe, persistent way to create IAM Identity Center profiles without importing host AWS state or moving credentials into the egress sidecar.

## Scope
- Pinned, architecture-matched AWS CLI v2 with per-architecture integrity verification.
- Explicit agent-only AWS state for default, MITM, and sidecar stacks.
- Exact region-derived Identity Center/OIDC and STS egress.
- Sandbox-native SSO setup, verification, logout/revocation, and isolated reset guidance.

## Non-goals
- Host `~/.aws` mounts, static/environment credentials, image-baked AWS state, broad `amazonaws.com` egress, administrator-role automation, or AWS credential execution/storage in the egress sidecar.

## Acceptance criteria
- [x] AWS CLI v2.36.7 is selected by target architecture and its official installer SHA-256 is verified before extraction.
- [x] AWS state is absent by default; opt-in overrides mount only `coding-agent-sandbox-aws` at `/home/node/.aws` in each agent service, never the egress sidecar.
- [x] `AWS_SSO_REGIONS` emits only exact regional OIDC, portal.sso, and STS hosts and rejects malformed/global input.
- [x] MITM variants preserve SigV4 Authorization only to those exact derived AWS hosts.
- [x] Documentation covers configure/list/login/identity verification, persistence, agent-readable token risk, least privilege, logout/revocation, and isolated reset without printing credentials.

## Verification
A corporate TLS-intercepting host must first place its local CA in ignored `certs/*.crt` as documented.

```sh
set -euo pipefail
bash -n scripts/network/aws-sso-domains.sh scripts/test-aws-sso-support.sh entrypoint.sh mitm/entrypoint.sh mitm/sidecar-entrypoint.sh
scripts/test-aws-sso-support.sh
for spec in 'docker-compose.yml docker-compose.aws.yml' 'docker-compose.mitm.yml docker-compose.mitm.aws.yml' 'docker-compose.sidecar.yml docker-compose.sidecar.aws.yml'; do
  args=(); for f in $spec; do args+=( -f "$f" ); done
  AWS_SSO_REGIONS=us-east-1 docker compose "${args[@]}" config --quiet
done
docker build -t coding-agent-sandbox:issue33 .
docker run --rm --entrypoint aws coding-agent-sandbox:issue33 --version
```

## Residuals & assumptions
- A live `aws sso login` requires a user-owned Identity Center tenant/profile and interactive browser authorization; it is documented rather than automated in CI.
- The preferred Claude cross-vendor peer was unavailable. Planning, conformance, and implementation converged through the disclosed OpenCode/Kimi fallback; its provider failed during Wave-D review, so that narrow demo review completed through the disclosed host-native fallback. A preferred-pair re-review remains owed.
