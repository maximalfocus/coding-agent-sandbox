# Frozen acceptance contract — issue #33

Source: https://github.com/maximalfocus/coding-agent-sandbox/issues/33

## Scenario 1 — Pinned architecture-matched AWS CLI v2

**Given** an amd64 or arm64 sandbox image build
**When** the AWS CLI layer is installed
**Then** the image downloads AWS CLI v2.36.7 for the matching architecture, verifies the pinned SHA-256 before extraction, installs it root-owned, and `aws --version` reports 2.36.7.

## Scenario 2 — AWS state is explicit, private, and agent-only

**Given** the normal default, MITM, or sidecar stack
**When** it starts without the AWS opt-in Compose override
**Then** no host AWS directory and no sandbox AWS volume is mounted.

**Given** the matching AWS opt-in override
**When** the stack starts
**Then** a dedicated named volume is mounted at `/home/node/.aws` only in the agent-capable service (`claude-sandbox` or `claude-sandbox-node`), never in `claude-sandbox-egress`, and it persists across ordinary restarts.

## Scenario 3 — Sandbox-native Identity Center profile lifecycle

**Given** the AWS opt-in stack and no imported host state
**When** a user runs `aws configure sso --profile <profile>` and `aws sso login --profile <profile>` inside the agent container
**Then** profile configuration and SSO cache are created in the sandbox-private AWS volume and can be reused after a restart.

**And** the documented verification is `aws sts get-caller-identity --profile <profile> --no-cli-pager`.

## Scenario 4 — Regional AWS egress is narrow and fail-closed

**Given** `AWS_SSO_REGIONS` contains one or more valid AWS regions
**When** the proxy allowlist is generated
**Then** only the exact regional IAM Identity Center/OIDC and STS hosts needed by the flow are added (`oidc.<region>.amazonaws.com`, `portal.sso.<region>.amazonaws.com`, and `sts.<region>.amazonaws.com`).

**And** malformed values, hostnames, wildcard entries, and global `amazonaws.com` grants are rejected rather than broadened or ignored.

## Scenario 5 — Security and revocation operations are explicit

**Given** a user follows the AWS SSO documentation
**Then** it prominently states that the coding agent can read all config/tokens in the AWS volume; recommends short-lived sessions and least-privilege roles; warns before administrator-role use; forbids image-baked credentials, host `~/.aws` mounts, environment access keys, and egress-sidecar credential state; and states that logs/audit output must never print cached token or credential material.

**And** it documents `aws sso logout`, profile/cache removal, and destructive dedicated-volume reset procedures without deleting unrelated sandbox volumes.
