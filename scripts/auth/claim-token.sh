#!/usr/bin/env bash
# Move an existing Claude subscription login OUT of the agent-readable config volume and into the
# tinyproxy-only vault, leaving a harmless placeholder behind — the "token isolation" hardening
# (mitm variant only). Run this once after `/login`; the agent can then no longer read a usable
# token, while the mitm proxy injects the real one into each Anthropic API call.
#
# Safe to re-run: it's a no-op once the placeholder is in place, and the mitm entrypoint already
# does this automatically on every container start (so a restart works too).
#
#   ./scripts/auth/claim-token.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# Auto-detect which isolation stack is up: the two-container sidecar variant (egress container) or
# the single-container mitm variant. Claim runs in whichever holds the vault.
#
# Which stack this resolves to is a credential-affecting choice — the claim MOVES a real subscription
# token — so the selection has to be addressable and visible rather than inferred from whatever
# happens to be running. `-p` is what makes it addressable: a Compose call without it cannot see a
# project started with one, so honouring SIDECAR_EGRESS_CONTAINER_NAME alone was not enough to reach
# an isolated stack, and an unset name could match the operator's own stack instead (issue #95).
#
# The mitm variant hardcodes its container_name, so its branch needs no name override.
SIDECAR_PROJECT="${SIDECAR_COMPOSE_PROJECT:-}"
EGRESS_CONTAINER="${SIDECAR_EGRESS_CONTAINER_NAME:-claude-sandbox-egress}"
COMPOSE=(docker compose)
if [ -n "$SIDECAR_PROJECT" ]; then COMPOSE+=(-p "$SIDECAR_PROJECT"); fi

if "${COMPOSE[@]}" -f docker-compose.sidecar.yml ps --status running --format '{{.Name}}' 2>/dev/null | grep -qx "$EGRESS_CONTAINER"; then
    SVC=claude-sandbox-egress
    CONTAINER="$EGRESS_CONTAINER"
    COMPOSE+=(-f docker-compose.sidecar.yml)
elif "${COMPOSE[@]}" -f docker-compose.mitm.yml ps --status running --format '{{.Name}}' 2>/dev/null | grep -q claude-sandbox-mitm; then
    SVC=claude-sandbox-mitm
    CONTAINER=claude-sandbox-mitm
    COMPOSE+=(-f docker-compose.mitm.yml)
else
    echo "No isolation sandbox is running${SIDECAR_PROJECT:+ in project '$SIDECAR_PROJECT'}. Start one first:"
    echo "  ANTHROPIC_TOKEN_ISOLATION=true docker compose -f docker-compose.mitm.yml up -d --build"
    echo "  # or the experimental sidecar: docker compose -f docker-compose.sidecar.yml up -d --build"
    exit 1
fi

# Say which stack is about to be acted on. A command that moves a credential should not leave the
# operator to infer its target from the absence of an error.
echo "Claiming into: $CONTAINER${SIDECAR_PROJECT:+  (project '$SIDECAR_PROJECT')}"

# A validation run that declares a project but mounts the operator's own volumes would claim the
# operator's real login. `-p` does not scope this project's volumes, which are named explicitly so a
# renamed checkout never orphans a login, so the two can disagree (issue #93).
#
# The guard is shared with the other credential-mutating helpers rather than copied, so the three
# cannot drift into three slightly different refusals (issue #97). Inspecting the running container
# observes what IS mounted, which is stronger than predicting it.
#
# NOT a pipeline: the guard exits, and `exit` inside a pipeline leaves only the subshell.
# shellcheck source=../stack-guard.sh
. "$(dirname "$0")/../stack-guard.sh"
stack_volumes=$(stack_guard_volumes_of_container "$CONTAINER")
stack_guard_refuse_if_shared \
    "A claim here would move the real login, not this stack's." <<<"$stack_volumes"

# Runs as root inside the container: it must write both the tinyproxy-owned vault and the node-owned
# placeholder. The real token never leaves the container.
exec "${COMPOSE[@]}" exec -u root "$SVC" /usr/local/bin/claim-token
