#!/usr/bin/env bash
# Continuous PowerShell syntax gate (issue #76, CAS-R162).
#
# This repository ships PowerShell files and `bash -n` covers only the shell half. This is the
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
#              2 the gate could not run (Docker unavailable, image unbuildable, or it timed out).
#              A gate that could not run never reports success.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Built from Dockerfile.pwsh in this repository rather than pulled from mcr.microsoft.com/powershell.
# That image is published for linux/amd64 and linux/arm (v7) only — there is no linux/arm64 build on
# any current tag — so on an arm64 host Docker selects an image it must emulate, and that emulation
# is not stable: on unchanged input it produced a hang, a spurious "cannot call a method on a
# null-valued expression", a QEMU assertion under arm/v7 (exit 139), and a Rosetta assertion under
# emulated amd64 (exit 133), the last after the gate had already printed a correct result. A gate
# that fails at random teaches people to ignore it, so the dependency was replaced. Building here
# also puts the download under this repository's own pinning discipline and runs natively on both
# architectures.
PWSH_IMAGE=${PWSH_IMAGE:-coding-agent-sandbox-pwsh:7.6.5}
PWSH_DOCKERFILE=${PWSH_DOCKERFILE:-$ROOT/Dockerfile.pwsh}
GATE_TIMEOUT=${GATE_TIMEOUT:-300}

cannot_run() { printf 'COULD NOT RUN: %s\n' "$*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || cannot_run "docker is not available; the PowerShell gate needs it"
docker info >/dev/null 2>&1 || cannot_run "the Docker daemon is not reachable"

# Build the verification image on first use so the gate needs no separate setup step — that is what
# makes it usable as ordinary verification rather than something people forget to run. The build is
# pinned and checksum-verified; it needs network only the first time.
if ! docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1; then
    [ -f "$PWSH_DOCKERFILE" ] || cannot_run "the verification image is absent and $PWSH_DOCKERFILE is missing"
    printf 'building the pinned PowerShell verification image (first run only)...\n' >&2
    docker build -f "$PWSH_DOCKERFILE" -t "$PWSH_IMAGE" "$ROOT" >/dev/null 2>&1 \
        || cannot_run "could not build the verification image; build it manually to see why:
       docker build -f $PWSH_DOCKERFILE -t $PWSH_IMAGE $ROOT"
fi

# Bounded by construction. An unbounded container run can wedge a whole verification pass, so the
# container is named, waited on, and killed if it overstays.
container="cas-pwsh-gate-$$"
output=$(mktemp)
status_file=$(mktemp)
trap 'docker rm -f "$container" >/dev/null 2>&1; rm -f "$output" "$status_file"' EXIT

(
    docker run --rm --name "$container" \
        --network none \
        -v "$ROOT:/repo:ro" \
        --entrypoint /usr/bin/pwsh \
        "$PWSH_IMAGE" \
        -NoProfile -NonInteractive -File /repo/scripts/powershell-syntax-gate.ps1 -Root /repo \
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
printf '      %s (%s, %s)\n' "$summary" "$PWSH_IMAGE" "$(uname -m)"
printf '      Not a Windows PowerShell 5.1 runtime — see docs/verification-hosts.md\n'
exit 0
