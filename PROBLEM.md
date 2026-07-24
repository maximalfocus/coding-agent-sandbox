# Problem Charter

- **Producer:** cdd-auto
- **Source of truth:** https://github.com/maximalfocus/coding-agent-sandbox/issues/33 and `.cdd-auto/contracts/issue-33.md`

## Problem
The sandbox lacks AWS CLI v2 and a safe, persistent way to create IAM Identity Center profiles without importing host AWS state or moving credentials into the egress sidecar.

## Scope
Pinned architecture-matched AWS CLI v2, opt-in agent-only AWS state, exact regional Identity Center/OIDC + STS egress, sandbox-native SSO setup, verification, logout, and dedicated-volume reset.

## Non-goals
Host `~/.aws` mounts, static/environment credentials, image-baked AWS state, broad `amazonaws.com` egress, administrator-role automation, or AWS credential execution/storage in the egress sidecar.

## Acceptance criteria
See the five frozen Given/When/Then scenarios in `.cdd-auto/contracts/issue-33.md`.

## Verification
```sh
scripts/test-aws-sso-support.sh
```

## Residuals
A live `aws sso login` requires a user-owned Identity Center tenant/profile and interactive browser authorization; delivery verifies the deterministic image/configuration boundary and documents that live operator check without importing credentials into CI.
