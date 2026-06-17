#!/usr/bin/env bash
# Supply-chain gate: scan the built sandbox image for known-vulnerable packages with Trivy
# (open source, Apache-2.0). Run standalone or via ./run.sh (which calls this before starting).
#
#   ./scan.sh                         # scan claude-container-sandbox:latest, fail on HIGH/CRITICAL
#   ./scan.sh some-other-image:tag    # scan a specific image
#   TRIVY_SEVERITY=CRITICAL ./scan.sh # tune what blocks (default HIGH,CRITICAL)
#
# Prefers a local `trivy` binary (brew install trivy). If absent, falls back to the official
# Trivy container, fed the image as a tarball via `docker save` — so we never mount the Docker
# socket into the scanner (no daemon access handed to a third-party image).
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${1:-claude-container-sandbox:latest}"
# Only FIXED vulns gate the build (--ignore-unfixed): those are actionable — bump the base-image
# digest or a package and rebuild. Unfixed CVEs in the Debian base would otherwise block forever.
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
# Pin/override the fallback scanner image. `latest` is used by default; pin to a digest for full
# reproducibility (this repo pins its base image, ttyd, and the CLI the same way).
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"

COMMON=(image --severity "$SEVERITY" --ignore-unfixed --exit-code 1 --no-progress)

echo "Scanning ${IMAGE} for ${SEVERITY} vulnerabilities (fixed only)..."

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image '$IMAGE' not found locally. Build it first (./run.sh or 'docker compose build')." >&2
    exit 1
fi

if command -v trivy >/dev/null 2>&1; then
    exec trivy "${COMMON[@]}" "$IMAGE"
fi

echo "  (no local 'trivy' — using ${TRIVY_IMAGE} via docker; 'brew install trivy' for a faster local scan)"

# Hand the image to Trivy as a tarball rather than via the daemon socket. tmp is cleaned on exit.
tar="$(mktemp -t sandbox-scan.XXXXXX.tar)"
trap 'rm -f "$tar"' EXIT
docker save "$IMAGE" -o "$tar"
# Persisted cache volume so the vuln DB isn't re-downloaded on every scan.
docker run --rm -v "$tar:/image.tar:ro" -v claude-sandbox-trivy-cache:/root/.cache/trivy \
    "$TRIVY_IMAGE" "${COMMON[@]}" --input /image.tar
