#!/usr/bin/env bash
# Verify issue #30's embedded-Go CLI remediation and isolation regressions.
set -euo pipefail

IMAGE="${1:-coding-agent-sandbox:latest}"
REPORT="${VERIFY_CLI_SECURITY_REPORT:-}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"

fail() { echo "verify-cli-security: $*" >&2; exit 1; }
command -v docker >/dev/null || fail "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image not found: $IMAGE"

# Source builds must be reproducible: immutable builder digest and full commit IDs, never moving refs.
grep -Eq '^FROM golang:1\.26\.5-bookworm@sha256:[0-9a-f]{64} AS go-cli-builder$' Dockerfile \
  || fail "Go 1.26.5 builder must be digest-pinned"
for name in GH_SOURCE_COMMIT BUILDX_SOURCE_COMMIT COMPOSE_SOURCE_COMMIT; do
  grep -Eq "^ARG ${name}=[0-9a-f]{40}$" Dockerfile || fail "missing immutable $name"
done
grep -Fq 'COPY --from=go-cli-builder /out/' Dockerfile \
  || fail "source-built CLIs are not copied from the isolated builder"

# Default mode must not grant the daemon socket; the opt-in host override is the only capability seam.
default_config="$(docker compose config)"
if grep -Eq '(/var/run/docker\.sock|docker_engine)' <<<"$default_config"; then
  fail "default Compose configuration exposes a Docker daemon capability"
fi
grep -Fq '/var/run/docker.sock' docker-compose.host.yml \
  || fail "opt-in host-Docker override no longer declares its capability"

docker run --rm --user node --entrypoint sh "$IMAGE" -lc '
  set -eu
  gh --version >/dev/null
  docker --version >/dev/null
  docker buildx version >/dev/null
  docker compose version >/dev/null
'

owned_report=0
tarball=""
cleanup() {
  if [ "$owned_report" = 1 ]; then rm -f "$REPORT"; fi
  if [ -n "$tarball" ]; then rm -f "$tarball"; fi
}
trap cleanup EXIT

if [ -n "$REPORT" ] && [ "${VERIFY_CLI_SECURITY_TEST_MODE:-}" != 1 ]; then
  fail "supplied reports require VERIFY_CLI_SECURITY_TEST_MODE=1"
fi
if [ -z "$REPORT" ]; then
  REPORT="$(mktemp)"; owned_report=1
  if command -v trivy >/dev/null 2>&1; then
    trivy image --format json --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
      --no-progress --exit-code 0 "$IMAGE" >"$REPORT"
  else
    tarball="$(mktemp -t sandbox-cli-security.XXXXXX.tar)"
    docker save "$IMAGE" -o "$tarball"
    docker run --rm -v "$tarball:/image.tar:ro" \
      -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy \
      "$TRIVY_IMAGE" image --format json --scanners vuln --severity HIGH,CRITICAL \
      --ignore-unfixed --no-progress --exit-code 0 --input /image.tar >"$REPORT"
  fi
fi
[ -s "$REPORT" ] || fail "Trivy report is missing or empty"

python3 - "$REPORT" "$IMAGE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        report = json.load(stream)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"verify-cli-security: malformed Trivy JSON: {exc}")
if not isinstance(report, dict) or report.get("ArtifactType") != "container_image":
    raise SystemExit("verify-cli-security: report is not a container-image scan")
metadata = report.get("Metadata")
if not isinstance(metadata, dict) or sys.argv[2] not in (metadata.get("RepoTags") or []):
    raise SystemExit("verify-cli-security: report RepoTags do not match the inspected image")
results = report.get("Results")
if not isinstance(results, list) or not results:
    raise SystemExit("verify-cli-security: empty/missing Results cannot prove absence")

blocked = {
    "usr/bin/gh": {"GHSA-hrxh-6v49-42gf", "CVE-2026-39822"},
    "usr/libexec/docker/cli-plugins/docker-buildx": {
        "CVE-2026-53488", "CVE-2026-53489", "CVE-2026-53492",
        "CVE-2026-34040", "GHSA-hrxh-6v49-42gf", "CVE-2026-39822",
    },
    "usr/libexec/docker/cli-plugins/docker-compose": {
        "CVE-2026-34040", "GHSA-hrxh-6v49-42gf", "CVE-2026-39822",
    },
}
seen = set()
remaining = []
for result in results:
    if not isinstance(result, dict) or not isinstance(result.get("Target"), str):
        raise SystemExit("verify-cli-security: malformed result entry")
    target = result["Target"].lstrip("/")
    if target not in blocked:
        continue
    seen.add(target)
    vulns = result.get("Vulnerabilities")
    if vulns is None:
        continue
    if not isinstance(vulns, list):
        raise SystemExit(f"verify-cli-security: malformed Vulnerabilities for {target}")
    for vuln in vulns:
        if not isinstance(vuln, dict) or not isinstance(vuln.get("VulnerabilityID"), str):
            raise SystemExit(f"verify-cli-security: malformed vulnerability for {target}")
        if vuln["VulnerabilityID"] in blocked[target]:
            remaining.append(f"{target}:{vuln['VulnerabilityID']}")
missing = sorted(set(blocked) - seen)
if missing:
    raise SystemExit("verify-cli-security: affected binary targets were not scanned: " + ", ".join(missing))
if remaining:
    raise SystemExit("verify-cli-security: issue-30 findings remain: " + ", ".join(sorted(remaining)))
print("issue-30 CLI findings: absent")
PY
