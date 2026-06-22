#!/usr/bin/env bash
# Move an existing Claude subscription login OUT of the agent-readable config volume and into the
# tinyproxy-only vault, leaving a harmless placeholder behind — the "token isolation" hardening
# (mitm variant only). Run this once after `/login`; the agent can then no longer read a usable
# token, while the mitm proxy injects the real one into each Anthropic API call.
#
# Safe to re-run: it's a no-op once the placeholder is in place, and the mitm entrypoint already
# does this automatically on every container start (so a restart works too).
#
#   ./claim-token.sh
set -euo pipefail
cd "$(dirname "$0")"

# Auto-detect which isolation stack is up: the two-container sidecar variant (egress container) or
# the single-container mitm variant. Claim runs in whichever holds the vault.
if docker compose -f docker-compose.sidecar.yml ps --status running --format '{{.Name}}' 2>/dev/null | grep -q claude-sandbox-egress; then
    SVC=claude-sandbox-egress
    COMPOSE=(docker compose -f docker-compose.sidecar.yml)
elif docker compose -f docker-compose.mitm.yml ps --status running --format '{{.Name}}' 2>/dev/null | grep -q claude-sandbox-mitm; then
    SVC=claude-sandbox-mitm
    COMPOSE=(docker compose -f docker-compose.mitm.yml)
else
    echo "No isolation sandbox is running. Start one first:"
    echo "  ANTHROPIC_TOKEN_ISOLATION=true docker compose -f docker-compose.mitm.yml up -d --build"
    echo "  # or the experimental sidecar: docker compose -f docker-compose.sidecar.yml up -d --build"
    exit 1
fi

# Runs as root inside the container: it must write both the tinyproxy-owned vault and the node-owned
# placeholder. The real token never leaves the container.
exec "${COMPOSE[@]}" exec -u root "$SVC" /usr/local/bin/claim-token
