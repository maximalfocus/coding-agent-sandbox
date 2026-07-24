#!/usr/bin/env bash
# Verify issue #29's Debian package floors and named-advisory absence.
set -euo pipefail

IMAGE="${1:-coding-agent-sandbox:latest}"
REPORT="${VERIFY_DEBIAN_SECURITY_REPORT:-}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"

fail() { echo "verify-debian-security: $*" >&2; exit 1; }
command -v docker >/dev/null || fail "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image not found: $IMAGE"

# Reproducibility is part of the contract: keep the upstream tag human-readable and
# pin its immutable manifest digest.
grep -Eq '^FROM node:22-bookworm@sha256:[0-9a-f]{64}$' Dockerfile \
  || fail "Dockerfile base must be node:22-bookworm pinned by sha256 digest"

# dpkg --compare-versions is required here: lexical or generic semver comparison does
# not implement Debian epochs/revisions correctly.
docker run --rm --entrypoint bash "$IMAGE" -lc '
  set -euo pipefail
  image_floor="8:6.9.11.60+dfsg-1.6+deb12u13"
  linux_floor="6.1.177-1"
  found_imagemagick=0 found_core=0 found_wand=0 found_linux=0
  while IFS=$'"'"'\t'"'"' read -r raw_name status version; do
    [ "$status" = installed ] || continue
    name="${raw_name%%:*}"
    case "$name" in
      imagemagick|imagemagick-*)
        found_imagemagick=1
        dpkg --compare-versions "$version" ge "$image_floor" || {
          echo "$name=$version is below $image_floor" >&2; exit 1; }
        ;;
      libmagickcore-*)
        found_core=1
        dpkg --compare-versions "$version" ge "$image_floor" || {
          echo "$name=$version is below $image_floor" >&2; exit 1; }
        ;;
      libmagickwand-*)
        found_wand=1
        dpkg --compare-versions "$version" ge "$image_floor" || {
          echo "$name=$version is below $image_floor" >&2; exit 1; }
        ;;
      linux-libc-dev)
        found_linux=1
        dpkg --compare-versions "$version" ge "$linux_floor" || {
          echo "$name=$version is below $linux_floor" >&2; exit 1; }
        ;;
    esac
  done < <(dpkg-query -W -f='"'"'${binary:Package}\t${db:Status-Status}\t${Version}\n'"'"')
  [ "$found_imagemagick" = 1 ] || { echo "no installed imagemagick package" >&2; exit 1; }
  [ "$found_core" = 1 ] || { echo "no installed libmagickcore package" >&2; exit 1; }
  [ "$found_wand" = 1 ] || { echo "no installed libmagickwand package" >&2; exit 1; }
  [ "$found_linux" = 1 ] || { echo "linux-libc-dev is not installed" >&2; exit 1; }
  dpkg-query -W -f='"'"'${binary:Package}=${Version}\n'"'"' imagemagick linux-libc-dev
'

owned_report=0
tarball=""
cleanup() {
  [ "$owned_report" = 1 ] && rm -f "$REPORT"
  [ -n "$tarball" ] && rm -f "$tarball"
}
trap cleanup EXIT

if [ -z "$REPORT" ]; then
  REPORT="$(mktemp)"; owned_report=1
  if command -v trivy >/dev/null 2>&1; then
    trivy image --format json --severity HIGH,CRITICAL --ignore-unfixed --no-progress \
      --exit-code 0 "$IMAGE" >"$REPORT"
  else
    tarball="$(mktemp -t sandbox-security.XXXXXX.tar)"
    docker save "$IMAGE" -o "$tarball"
    docker run --rm -v "$tarball:/image.tar:ro" \
      -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy \
      "$TRIVY_IMAGE" image --format json --severity HIGH,CRITICAL --ignore-unfixed \
      --no-progress --exit-code 0 --input /image.tar >"$REPORT"
  fi
fi
[ -s "$REPORT" ] || fail "Trivy report is missing or empty"

python3 - "$REPORT" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"verify-debian-security: malformed Trivy JSON: {exc}")

if not isinstance(report, dict) or not isinstance(report.get("Results"), list):
    raise SystemExit("verify-debian-security: Trivy JSON lacks a Results array")

found = set()
for result in report["Results"]:
    if not isinstance(result, dict):
        raise SystemExit("verify-debian-security: malformed Trivy result entry")
    vulnerabilities = result.get("Vulnerabilities")
    if vulnerabilities is None:
        continue
    if not isinstance(vulnerabilities, list):
        raise SystemExit("verify-debian-security: malformed Vulnerabilities field")
    for vulnerability in vulnerabilities:
        if not isinstance(vulnerability, dict) or not isinstance(vulnerability.get("VulnerabilityID"), str):
            raise SystemExit("verify-debian-security: malformed vulnerability entry")
        found.add(vulnerability["VulnerabilityID"])

blocked = {
    "CVE-2026-61857", "CVE-2026-61863", "CVE-2026-61866", "CVE-2026-61870",
    "CVE-2026-53138", "CVE-2026-53157", "CVE-2026-53359", "CVE-2026-53362",
    "CVE-2026-53398", "CVE-2026-63794", "CVE-2026-63795", "CVE-2026-63824",
    "CVE-2026-63830", "CVE-2026-63831", "CVE-2026-64191",
}
remaining = sorted(blocked & found)
if remaining:
    raise SystemExit("verify-debian-security: issue-29 CVEs remain: " + ", ".join(remaining))
print("issue-29 named CVEs: absent")
PY
