#!/usr/bin/env bash
# Supply-chain scan: check the built image for known-vulnerable packages with Trivy (Apache-2.0).
#
# ADVISORY by default — it prints what it finds but does NOT block the sandbox from starting.
# Why: this image is a full Debian + Node base plus third-party CLIs (Claude Code, Codex), whose
# OS and bundled-npm packages routinely carry fixed CVEs you can't patch yourself. Hard-blocking
# on those would brick every fresh build. The scan keeps you AWARE of the surface; you reduce it
# by bumping the base-image digest over time.
#
#   ./scan.sh                          # advisory: scan windows + print findings, exit 0
#   TRIVY_STRICT=1 ./scan.sh           # gate: exit non-zero if any fixed HIGH/CRITICAL remain
#   TRIVY_SUMMARY=1 ./scan.sh          # print only the per-target totals (used by run.sh)
#   TRIVY_SEVERITY=CRITICAL ./scan.sh  # tune severities
#
# Prefers a local `trivy` binary (brew install trivy); else falls back to the official Trivy
# container, fed the image as a tarball via `docker save` (no Docker-socket mount).
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${1:-coding-agent-sandbox:latest}"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
GATE=0; [ -n "${TRIVY_STRICT:-}" ] && GATE=1
COMMON=(image --severity "$SEVERITY" --ignore-unfixed --no-progress --exit-code "$GATE")

mode="advisory — report only (set TRIVY_STRICT=1 to block)"
[ "$GATE" = 1 ] && mode="STRICT — blocks on findings"
echo "Scanning ${IMAGE} for ${SEVERITY} (fixed only; ${mode})..."

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image '$IMAGE' not found locally. Build it first (./run.sh or 'docker compose build')." >&2
    exit 1
fi

report="$(mktemp)"; tarball=""
cleanup() { rm -f "$report" ${tarball:+"$tarball"}; }
trap cleanup EXIT

rc=0
if command -v trivy >/dev/null 2>&1; then
    trivy "${COMMON[@]}" "$IMAGE" > "$report" 2>&1 || rc=$?
else
    echo "  (no local 'trivy' — using ${TRIVY_IMAGE} via docker; 'brew install trivy' is faster)"
    tarball="$(mktemp -t sandbox-scan.XXXXXX.tar)"
    docker save "$IMAGE" -o "$tarball"
    docker run --rm -v "$tarball:/image.tar:ro" -v coding-agent-sandbox-trivy-cache:/root/.cache/trivy \
        "$TRIVY_IMAGE" "${COMMON[@]}" --input /image.tar > "$report" 2>&1 || rc=$?
fi

if [ -n "${TRIVY_SUMMARY:-}" ]; then
    grep -E "Total:|^${IMAGE}" "$report" || echo "  (scan produced no summary lines — run ./scan.sh for detail)"
else
    cat "$report"
fi

if [ "$GATE" = 1 ] && [ "$rc" -ne 0 ]; then
    echo "STRICT scan: fixed ${SEVERITY} vulnerabilities present (see above)." >&2
fi
exit "$rc"
