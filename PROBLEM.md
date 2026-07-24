# Problem Charter

- **Producer:** cdd-auto
- **Generated:** 2026-07-24
- **Source of truth:** GitHub issue 31 and `.cdd-auto/contracts/issue-31.md`

## Problem

The Debian Maven package writes example passwords and a passphrase to `/etc/maven/settings.xml` during installation. A later project-owned `COPY` makes the final filesystem safe, but layer-aware Trivy scanning still reports three HIGH secret-pattern findings and obscures real scanner results.

## Scope

- Delete Debian's example Maven settings in the same Dockerfile `RUN` instruction that installs Maven.
- Retain the byte-identical project-owned Maven proxy settings in the final image.
- Prove a live Trivy container-image secret scan has no Maven password/passphrase findings and no suppression was introduced.
- Prove Maven still resolves a dependency as `node` through the running sandbox proxy.

## Non-goals

- Upgrading Maven or other packages.
- Changing egress allowlists, proxy/firewall behavior, credentials, or container privileges.
- Suppressing or remediating unrelated Trivy findings.

## Acceptance criteria

- [x] `/etc/maven/settings.xml` is deleted after Maven installation and before that `RUN` layer is committed.
- [x] A successful live Trivy secret scan tied to the inspected image layers contains no `maven-settings-password` or `maven-settings-passphrase` finding for `/etc/maven/settings.xml`; missing, malformed, empty, foreign-layer, or affected evidence is red.
- [x] The final image's Maven settings are byte-identical to `maven-settings.xml`, configure the active `127.0.0.1:8888` proxy, and contain no password/passphrase element.
- [x] Maven resolves Commons Lang 3.17.0 into a fresh temporary repository as the unprivileged `node` user in the running sandbox.
- [x] No Trivy ignore file, secret-scanner config, or broad skip/ignore flag was added.

## Verification

```sh
set -euo pipefail
bash -n scripts/verify-maven-secrets.sh .cdd-auto/demo/verify.sh
docker compose config >/dev/null
docker compose build claude-sandbox
./scripts/verify-maven-secrets.sh coding-agent-sandbox:latest
.cdd-auto/demo/verify.sh

bad="$(mktemp)"; trap 'rm -f "$bad"' EXIT
cp .cdd-auto/demo/expected-output.txt "$bad"
printf 'unexpected-line\n' >>"$bad"
if EXPECTED_OUTPUT="$bad" .cdd-auto/demo/verify.sh >/tmp/issue31-negative.out 2>&1; then
  echo 'acceptance output mutation unexpectedly passed' >&2
  exit 1
fi
```

The build, live Trivy scan, container recreation, and first Maven resolution use Docker state/cache and require registry/network access on a cold cache.

## Residuals & assumptions

- Verification was executed on arm64. The Node base is a multi-architecture manifest and the changed package path and shell operations are architecture-neutral; CI/maintainer builds retain amd64 confirmation.
- The test-report seam exists only behind `VERIFY_MAVEN_SECRETS_ALLOW_TEST_REPORT=1` for negative mutation tests. Normal and acceptance invocations always perform a live scan of the inspected image.
