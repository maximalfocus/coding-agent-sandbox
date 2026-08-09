# Opt-in AWS IAM Identity Center profiles

AWS CLI v2 is installed in the image, but AWS state and AWS service egress are **off by default**. This flow creates a sandbox-private profile; it does not import host AWS configuration or tokens.

> **Credential boundary:** the coding agent can read every profile, cached SSO token, and role credential in the dedicated AWS volume. Those credentials inherit the selected role's permissions. Prefer short-lived sessions and least-privilege roles. Review the role before login, and warn prominently before any administrator-role use.

## 1. Select only the required region(s)

Set exact IAM Identity Center regions in `.env` (comma-separated):

```dotenv
AWS_SSO_REGIONS=us-east-1
```

Each region adds only `oidc.<region>.amazonaws.com`, `portal.sso.<region>.amazonaws.com`, and `sts.<region>.amazonaws.com`. Invalid values fail startup. Never add `amazonaws.com` or `*.amazonaws.com` to `EXTRA_ALLOWED_DOMAINS`.

## 2. Start with the agent-only AWS volume

For the default stack, the standard launchers automatically select the agent-only AWS volume whenever `AWS_SSO_REGIONS` is non-empty:

```bash
./run.sh                 # macOS/Linux
.\run.ps1                # Windows PowerShell
```

For a direct Compose launch or a non-default stack, choose the matching override:

```bash
# Default (equivalent to the launcher selection)
docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d --build

# Content-mediation (build the base image first)
docker compose build
docker compose -f docker-compose.mitm.yml -f docker-compose.mitm.aws.yml up -d --build

# Experimental token-isolation sidecar
docker compose -f docker-compose.sidecar.yml -f docker-compose.sidecar.aws.yml up -d --build
```

The named volume `coding-agent-sandbox-aws` is mounted at `/home/node/.aws` only in the agent service. In the sidecar stack it is never mounted in the egress sidecar.

## 3. Configure and log in inside the sandbox

Open the sandbox terminal, then run:

```bash
aws --version
aws configure sso --profile <profile>
aws configure list-profiles
aws sso login --profile <profile>
aws sts get-caller-identity --profile <profile> --no-cli-pager
```

Complete the device/browser authorization as prompted. Ordinary container restarts preserve the profile and `~/.aws/sso/cache` in the dedicated volume.

## Logout, revoke, or reset

Logout removes locally cached SSO sessions:

```bash
aws sso logout
```

For one profile, edit `~/.aws/config` and remove only its matching `sso-session` section; remove the associated files under `~/.aws/sso/cache` without printing them. To revoke an active session centrally, use your organization's IAM Identity Center portal/administrator controls.

For a destructive sandbox-only reset, stop the AWS-enabled stack and remove **only** its dedicated volume:

```bash
docker compose -f docker-compose.yml -f docker-compose.aws.yml down
docker volume rm coding-agent-sandbox-aws
```

Use the matching stack files for MITM or sidecar. This command does not remove Claude, Codex, GitHub, workspace, or audit volumes.

## Security rules

- Do not mount host `~/.aws`; it can expose every host profile and cached bearer token.
- Do not bake credentials, AWS config, SSO cache, access keys, or session credentials into an image.
- Do not use environment access keys; process environments are agent-readable and awkward to rotate.
- Do not store AWS state in or execute AWS CLI from the egress sidecar; that container remains a proxy/vault boundary, not an AWS credential provider.
- Logs and audit output must never print access keys, SSO tokens, role credentials, or cached credential material. `get-caller-identity` is safe identity metadata; do not dump `env`, `~/.aws`, or cache files.
