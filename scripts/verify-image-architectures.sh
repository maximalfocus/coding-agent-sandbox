#!/usr/bin/env bash
# Build the image on hardware of each supported architecture (issue #82, CAS-R160).
#
# The image resolves architecture-specific downloads through `case` statements on TARGETARCH, and
# each branch carries its own SHA-256 constant. A wrong checksum or a rotted URL in one branch cannot
# be caught by building the other — the branch that did not build was never executed. Both have been
# built before, each time by hand; this makes it one command instead of a remembered procedure.
#
# Remote hosts are reached only through scripts/verify-on-host.sh, which resolves a machine by its
# SSH host key rather than by a current address. There is deliberately no second way of connecting
# to a machine here.
#
# Both builds run with --no-cache, and that is the whole point rather than an oversight. A cached
# layer never executes, so a warm-cache build does not run `sha256sum` at all: corrupting an
# architecture's checksum and rebuilding reported CACHED and succeeded, which would have made this
# gate theatre. With --no-cache the same corruption fails the build, which is what CAS-R160 asks
# for — that a wrong checksum is *able* to fail its architecture's build.
#
# That makes this a per-release check, not a per-change one: a clean build is tens of minutes and
# re-fetches every pinned artifact, so it is also network-dependent. What it removes is the part
# that actually fails in practice — remembering the procedure, and trusting that whoever ran it
# used the host they thought they did.
#
# Usage:
#   scripts/verify-image-architectures.sh
#   REMOTE_ARCH_HOST=idd scripts/verify-image-architectures.sh
#
# Configuration:
#   REMOTE_ARCH_HOST  fleet alias providing the architecture this machine is not (default: idd)
#   IMAGE_TAG         tag to build (default: coding-agent-sandbox:arch-check)
#   DOCKERFILE        Dockerfile to build (default: Dockerfile)
#
# Exit status: 0 only when BOTH architectures built successfully.
#              1 when an architecture failed to build.
#              2 when an architecture could not be attempted — reported as NOT COVERED, never as a
#                pass, because a partial run that reads like a complete one is worse than no check.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY_ON_HOST="$ROOT/scripts/verify-on-host.sh"
REMOTE_ARCH_HOST=${REMOTE_ARCH_HOST:-idd}
IMAGE_TAG=${IMAGE_TAG:-coding-agent-sandbox:arch-check}
DOCKERFILE=${DOCKERFILE:-Dockerfile}

declare -a RESULTS=()   # arch<TAB>status<TAB>detail
FAILED=0
UNCOVERED=0

record() { # arch status detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    case "$2" in
        FAILED) FAILED=1 ;;
        "NOT COVERED") UNCOVERED=1 ;;
    esac
}

normalise_arch() { # uname -m -> docker arch
    case "$1" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- local architecture -----------------------------------------------------
local_arch=$(normalise_arch "$(uname -m)")

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    record "$local_arch" "NOT COVERED" "Docker is unavailable on this machine"
else
    printf 'building %s locally (%s)...\n' "$IMAGE_TAG" "$local_arch" >&2
    if docker build --no-cache -f "$ROOT/$DOCKERFILE" -t "$IMAGE_TAG" "$ROOT" >/tmp/arch-local.$$.log 2>&1; then
        record "$local_arch" BUILT "local host, kernel:$( [ "$(uname -s)" = Linux ] && echo bare || echo vm )"
    else
        record "$local_arch" FAILED "$(grep -iE 'error|sha256sum|checksum|failed' /tmp/arch-local.$$.log | tail -3 | tr '\n' ' ')"
    fi
    rm -f "/tmp/arch-local.$$.log"
fi

# --- the other architecture, on a fleet host --------------------------------
if [ ! -x "$VERIFY_ON_HOST" ]; then
    record other "NOT COVERED" "scripts/verify-on-host.sh is missing; no other way to reach a host is used"
else
    # Ask the host what it is before building, so the result can name the architecture rather than
    # assume the alias provides the one this machine lacks.
    remote_facts=$("$VERIFY_ON_HOST" "$REMOTE_ARCH_HOST" -- 'uname -m; uname -s' 2>/dev/null)
    remote_status=$?
    if [ "$remote_status" -ne 0 ] || [ -z "$remote_facts" ]; then
        record other "NOT COVERED" "could not reach fleet host '$REMOTE_ARCH_HOST' (run scripts/verify-on-host.sh $REMOTE_ARCH_HOST -- true to see why)"
    else
        remote_arch=$(normalise_arch "$(printf '%s\n' "$remote_facts" | sed -n '1p' | tr -d '\r')")
        remote_kind=$(printf '%s\n' "$remote_facts" | sed -n '2p' | tr -d '\r')
        remote_kernel=$( [ "$remote_kind" = Linux ] && echo bare || echo vm )
        if [ "$remote_arch" = "$local_arch" ]; then
            record other "NOT COVERED" "'$REMOTE_ARCH_HOST' is $remote_arch, the same as this machine; set REMOTE_ARCH_HOST to a host of the other architecture"
        else
            printf 'building %s on %s (%s)...\n' "$IMAGE_TAG" "$REMOTE_ARCH_HOST" "$remote_arch" >&2
            # The remote build uses the repository as it exists on that host. Ship the tracked tree
            # so the build matches this checkout rather than whatever happens to be there.
            remote_dir="idd-arch-check-$$"
            if git -C "$ROOT" archive HEAD 2>/dev/null \
                | "$VERIFY_ON_HOST" "$REMOTE_ARCH_HOST" -- \
                    "rm -rf ~/$remote_dir && mkdir -p ~/$remote_dir && tar xf - -C ~/$remote_dir" >/dev/null 2>&1
            then
                if "$VERIFY_ON_HOST" "$REMOTE_ARCH_HOST" -- \
                        "cd ~/$remote_dir && docker build --no-cache -f $DOCKERFILE -t $IMAGE_TAG . >/tmp/arch-remote.log 2>&1; rc=\$?; tail -3 /tmp/arch-remote.log; exit \$rc" \
                        >/tmp/arch-remote.$$.log 2>&1
                then
                    record "$remote_arch" BUILT "$REMOTE_ARCH_HOST, kernel:$remote_kernel"
                else
                    record "$remote_arch" FAILED "$(tail -3 /tmp/arch-remote.$$.log | tr '\n' ' ')"
                fi
                "$VERIFY_ON_HOST" "$REMOTE_ARCH_HOST" -- "rm -rf ~/$remote_dir" >/dev/null 2>&1
            else
                record "$remote_arch" "NOT COVERED" "could not ship the tree to '$REMOTE_ARCH_HOST'"
            fi
            rm -f "/tmp/arch-remote.$$.log"
        fi
    fi
fi

# --- report ------------------------------------------------------------------
printf '\n'
for line in ${RESULTS+"${RESULTS[@]}"}; do
    IFS=$'\t' read -r arch status detail <<<"$line"
    printf '%-13s %-12s %s\n' "$arch" "$status" "$detail"
done
printf '\n'

if [ "$FAILED" -eq 1 ]; then
    printf 'RESULT: an architecture FAILED to build — its branch is broken.\n'
    exit 1
fi
if [ "$UNCOVERED" -eq 1 ]; then
    printf 'RESULT: NOT COVERED — at least one architecture was not built, so this is not a pass.\n'
    printf '        See docs/verification-hosts.md.\n'
    exit 2
fi
printf 'RESULT: both architecture branches built on hardware of their own architecture.\n'
exit 0
