#!/usr/bin/env bash
# Continuous PowerShell syntax gate (issue #76, CAS-R162).
#
# This repository ships 14 PowerShell files and `bash -n` covers only the shell half. This is the
# PowerShell equivalent: it parses every tracked `*.ps1` inside a pinned container and rejects syntax
# that Windows PowerShell 5.1 cannot accept. It needs no Windows machine, which is the whole point —
# a check that needs one does not get run.
#
# **What this does not do.** It parses; it does not execute anything, and it is not a Windows
# PowerShell 5.1 runtime. Behavioural differences, path translation, and line-ending handling are not
# covered. A real Windows run is still required before a release that changes launcher behaviour —
# see docs/verification-hosts.md. Neither substitutes for the other.
#
# Usage:
#   scripts/test-powershell-syntax.sh
#
# Exit status: 0 all files parse and use no 7-only construct,
#              1 at least one file failed,
#              2 the gate could not run (Docker or the pinned image unavailable, or it timed out).
#              A gate that could not run never reports success.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Pinned by digest, not by a floating tag, for the same reason every other download here is pinned:
# `latest` is not a version. PowerShell 7 is the parser; the 5.1 constraint is enforced by the token
# check inside the gate script, not by the image.
#
# The digest is the **linux/amd64** manifest, and --platform below pins it. That is deliberate:
# mcr.microsoft.com/powershell publishes linux/amd64 and linux/arm (v7) but **no linux/arm64**, so on
# an arm64 host Docker silently selects the 32-bit arm/v7 image and runs it under emulation. That
# emulation is not stable — it produced a hang, a spurious "cannot call a method on a null-valued
# expression", and a QEMU assertion failure (`thumb_tr_translate_insn`) with exit 139, on unchanged
# input. An intermittent gate is worse than none, so the platform is chosen explicitly rather than
# left to the host.
PWSH_IMAGE=${PWSH_IMAGE:-mcr.microsoft.com/powershell@sha256:73c08403182e3cd1a62176b6723645b2d2037cda8deefc0e2c2c01cb814abe43}
GATE_TIMEOUT=${GATE_TIMEOUT:-180}

cannot_run() { printf 'COULD NOT RUN: %s\n' "$*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || cannot_run "docker is not available; the PowerShell gate needs it"
docker info >/dev/null 2>&1 || cannot_run "the Docker daemon is not reachable"
docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1 \
    || cannot_run "the pinned PowerShell image is not present locally: $PWSH_IMAGE
       pull it once with: docker pull --platform linux/amd64 $PWSH_IMAGE"

# Refuse to run under emulation rather than produce intermittent results.
#
# Microsoft publishes this image for linux/amd64 and linux/arm (v7) only — there is no linux/arm64
# build on any current tag. On an arm64 host the container can therefore only run emulated, and that
# is not merely slow: on unchanged input it produced a hang, a spurious "cannot call a method on a
# null-valued expression", a QEMU assertion (`thumb_tr_translate_insn`, exit 139) under arm/v7, and a
# Rosetta assertion (`BasicBlock requested for unrecognized address`, exit 133) under amd64 — the
# last of these *after* the gate had already printed a correct result.
#
# A check that fails at random teaches people to ignore it, which is worse than not having it. So
# this reports that it could not run, and says why, instead of guessing. See
# docs/verification-hosts.md: this gate's host requirement is arch:amd64.
host_arch=$(docker info --format '{{.Architecture}}' 2>/dev/null)
case "$host_arch" in
    x86_64|amd64) ;;
    "") cannot_run "could not determine the Docker host architecture" ;;
    *)
        cannot_run "this gate needs an amd64 Docker host; this one is '$host_arch'.
       Microsoft publishes no linux/arm64 PowerShell image, so running here would mean emulation,
       and emulation of this image is not reliable enough for a gate — it fails at random on
       unchanged input. Run this on an amd64 host. See docs/verification-hosts.md."
        ;;
esac

# Bounded by construction. An unbounded container run can wedge a whole verification pass, so the
# container is named, waited on, and killed if it overstays.
container="cas-pwsh-gate-$$"
output=$(mktemp)
status_file=$(mktemp)
trap 'docker rm -f "$container" >/dev/null 2>&1; rm -f "$output" "$status_file"' EXIT

(
    docker run --rm --name "$container" \
        --network none \
        --platform linux/amd64 \
        -v "$ROOT:/repo:ro" \
        "$PWSH_IMAGE" \
        pwsh -NoProfile -NonInteractive -File /repo/scripts/powershell-syntax-gate.ps1 -Root /repo \
        >"$output" 2>&1
    printf '%s' "$?" >"$status_file"
) &
runner=$!

waited=0
while kill -0 "$runner" 2>/dev/null; do
    if [ "$waited" -ge "$GATE_TIMEOUT" ]; then
        docker rm -f "$container" >/dev/null 2>&1
        wait "$runner" 2>/dev/null
        cannot_run "the gate did not finish within ${GATE_TIMEOUT}s and was killed"
    fi
    waited=$((waited + 1))
    sleep 1
done
wait "$runner" 2>/dev/null
rc=$(cat "$status_file" 2>/dev/null)
rc=${rc:-2}

parsed=$(grep -c '^PARSED ' "$output" 2>/dev/null || true)
summary=$(grep '^GATE-SUMMARY' "$output" 2>/dev/null || true)

if grep -q '^GATE-ERROR' "$output" 2>/dev/null; then
    sed -n 's/^GATE-ERROR /  /p' "$output" >&2
    cannot_run "the gate reported it could not evaluate the tree"
fi

if [ "$rc" -ne 0 ] || [ -z "$summary" ]; then
    printf 'FAIL: PowerShell syntax gate\n' >&2
    grep -E '^(PARSE-ERROR|INCOMPATIBLE)' "$output" >&2 || sed -n '1,20p' "$output" >&2
    exit 1
fi

printf 'PASS: %s PowerShell files parse and use no PowerShell 7-only construct\n' "$parsed"
printf '      %s\n' "$summary"
printf '      Not a Windows PowerShell 5.1 runtime — see docs/verification-hosts.md\n'
exit 0
