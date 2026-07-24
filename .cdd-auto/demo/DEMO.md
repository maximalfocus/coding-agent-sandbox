# Demo: opt-in AWS IAM Identity Center profiles

## Scenario 1 — Verify the shipped CLI and contract

**Persona:** Sandbox operator

1. Build the sandbox image from the pinned Dockerfile.
2. Run the issue-33 conformance gate.
3. **Expected:** every packaging, state-isolation, egress, and documentation check passes; the image reports AWS CLI v2.36.7.

## Scenario 2 — Verify narrow region-derived egress

**Persona:** Security reviewer

1. Generate endpoints for `us-east-1`.
2. Try a trailing-comma and global-domain input.
3. **Expected:** only exact OIDC, portal.sso, and STS hosts are emitted; malformed/global inputs fail closed.

## Scenario 3 — Verify agent-only state

**Persona:** Sandbox operator

1. Inspect all three AWS Compose overrides.
2. **Expected:** the dedicated `coding-agent-sandbox-aws` volume targets only default, MITM, and sidecar agent services; the sidecar egress service has no AWS mount.

Run:

```bash
.cdd-auto/demo/verify.sh
```

The script byte-diffs the pinned output in `expected-output.txt`. A live `aws sso login` is intentionally operator-owned because it requires a real Identity Center tenant and role; follow `docs/aws-sso.md` after this deterministic gate passes.
