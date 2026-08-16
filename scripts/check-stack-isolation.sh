#!/usr/bin/env bash
# Report volumes a "validation" stack shares with the operator (issue #93).
#
# `-p` scopes Compose containers and networks, but this project names its volumes explicitly so that
# renaming the checkout never orphans a login. That naming is deliberate; the consequence is that a
# stack brought up with only `SIDECAR_COMPOSE_PROJECT` set is isolated in every respect except the
# one that matters most — it mounts the operator's real credential volumes.
#
# The failure is silent and reads as success: every structural check still passes, because those
# checks concern the boundary, not which volume is behind it. What follows in a validation run is
# usually a write, so the first symptom can be an overwritten login.
#
# Usage:  printf '%s\n' <mounted volume names> | scripts/check-stack-isolation.sh <compose-file>
#
# Prints one offending name per line — a mounted volume still carrying its operator default — and
# exits 1 if there were any, 0 if the stack is clean. The defaults are read from the compose file's
# own `${VAR:-default}` fallbacks, never from a list kept here, so a volume added to the compose file
# is covered the day it is added rather than the day someone remembers to update this script.
set -uo pipefail

COMPOSE_FILE=${1:?usage: check-stack-isolation.sh <compose-file> (mounted volume names on stdin)}
[ -r "$COMPOSE_FILE" ] || { echo "cannot read compose file: $COMPOSE_FILE" >&2; exit 2; }

# `name: "${SIDECAR_CONFIG_VOLUME_NAME:-coding-agent-sandbox-config}"` -> the default half.
defaults=$(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}"?.*/\1/p' "$COMPOSE_FILE")
if [ -z "$defaults" ]; then
    echo "no overridable volume names found in $COMPOSE_FILE" >&2
    exit 2
fi

found=0
while IFS= read -r mounted; do
    [ -n "$mounted" ] || continue
    while IFS= read -r def; do
        [ -n "$def" ] || continue
        if [ "$mounted" = "$def" ]; then
            printf '%s\n' "$mounted"
            found=1
            break
        fi
    done <<<"$defaults"
done

exit $(( found ? 1 : 0 ))
