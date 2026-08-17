#!/usr/bin/env bash
# Coverage for issue #101's precondition: the proxy's refresh skew must actually reach the sidecar.
#
# `mitm/sidecar-entrypoint.sh` has always exported TOKEN_REFRESH_SKEW="${TOKEN_REFRESH_SKEW:-600}",
# so the intent to make it configurable was there. The composition never delivered it — the variable
# was absent from the egress service's `environment:` block — so the inherited value could not arrive
# and the effective skew was always the default. A knob one layer honours and another cannot deliver
# reads as configurable while being fixed.
#
# It matters beyond tidiness: raising the skew past a token's remaining lifetime is what makes the
# proxy-owned refresh path exercisable without waiting out a full access-token TTL. Without this the
# only way to reach that code against a real provider is to wait hours and hope.
#
# Reads rendered Compose configuration; starts nothing.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
COMPOSE_FILE=docker-compose.sidecar.yml
ENTRYPOINT=mitm/sidecar-entrypoint.sh
ADDON=mitm/filter_addon.py

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker is not available"; exit 0; }
docker info >/dev/null 2>&1 || { echo "SKIP: the Docker daemon is not reachable"; exit 0; }

rendered() { # [value]
    if [ $# -eq 1 ]; then
        TOKEN_REFRESH_SKEW="$1" docker compose -f "$COMPOSE_FILE" config 2>/dev/null
    else
        env -u TOKEN_REFRESH_SKEW docker compose -f "$COMPOSE_FILE" config 2>/dev/null
    fi
}
skew_of() { sed -nE 's/^[[:space:]]*TOKEN_REFRESH_SKEW:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' <<<"$1" | head -1; }

# --- the three cases --------------------------------------------------------
out=$(rendered)
[ -n "$out" ] || fail "compose could not render the sidecar file"
got=$(skew_of "$out")
[ -n "$got" ] || fail "TOKEN_REFRESH_SKEW is not delivered to the sidecar at all — the knob is dead"
[ "$got" = "600" ] || fail "the default skew is '$got', expected 600"
ok "unset, the skew defaults to 600 — existing behaviour is unchanged"

got=$(skew_of "$(rendered 99999)")
[ "$got" = "99999" ] || fail "an explicit skew did not reach the sidecar: got '$got'"
ok "an explicit skew reaches the sidecar"

got=$(skew_of "$(rendered 0)")
[ "$got" = "0" ] || fail "a zero skew was swallowed by the default: got '$got'"
ok "a zero skew is delivered rather than replaced by the default"

# --- it must land on the container that owns the vault ----------------------
# The agent container must not receive it: the vault, and the refresh, live only in the sidecar.
# Flag idiom, not an awk range: `  claude-sandbox-egress:` also matches the range's end pattern, so
# a range collapses to that single line and the block comes back empty.
egress_block=$(awk '/^  claude-sandbox-egress:/{f=1;next} /^  [a-z]/{f=0} f' <<<"$(rendered 12345)")
grep -q 'TOKEN_REFRESH_SKEW: "12345"' <<<"$egress_block" \
    || fail "the skew does not reach the egress service, which is the one that refreshes"
ok "the skew reaches the egress service, which owns the vault"

agent_block=$(awk '/^  claude-sandbox-node:/{f=1;next} /^  [a-z]|^[a-z]/{f=0} f' <<<"$(rendered 12345)")
grep -q 'TOKEN_REFRESH_SKEW' <<<"$agent_block" \
    && fail "the skew is delivered to the agent container, which has no vault to refresh"
ok "the skew is not delivered to the agent container"

# --- the two layers must agree on the name ----------------------------------
# The whole defect was one layer honouring a name the other never sent.
grep -q 'TOKEN_REFRESH_SKEW' "$ENTRYPOINT" || fail "the entrypoint no longer reads TOKEN_REFRESH_SKEW"
grep -q 'TOKEN_REFRESH_SKEW' "$ADDON" || fail "the addon no longer reads TOKEN_REFRESH_SKEW"
grep -q 'TOKEN_REFRESH_SKEW' "$COMPOSE_FILE" || fail "the compose file no longer passes TOKEN_REFRESH_SKEW"
ok "compose, the entrypoint, and the addon all use the same variable name"

# The entrypoint's own default must not disagree with the compose default, or the effective value
# would depend on which layer happened to supply it.
entry_default=$(sed -nE 's/.*TOKEN_REFRESH_SKEW="\$\{TOKEN_REFRESH_SKEW:-([0-9]+)\}".*/\1/p' "$ENTRYPOINT" | head -1)
addon_default=$(sed -nE 's/.*TOKEN_REFRESH_SKEW", *"([0-9]+)".*/\1/p' "$ADDON" | head -1)
[ "$entry_default" = "600" ] || fail "the entrypoint default is '$entry_default', not 600"
[ "$addon_default" = "600" ] || fail "the addon default is '$addon_default', not 600"
ok "all three layers default to the same 600, so the effective value cannot depend on the path taken"

printf '\nAll %d checks passed.\n' "$PASSED"
