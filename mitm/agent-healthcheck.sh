#!/usr/bin/env bash
# EXPERIMENTAL — health probe for the AGENT container of the two-container sidecar variant
# (docs/architecture/token-isolation-sidecar.md), issue #70.
#
# The base image's healthcheck asserts an in-container tinyproxy is alive. That is correct for the
# default single-container stack and wrong here: in this variant the proxy lives in the separate
# egress container by design, so the agent runs no proxy and the base check can never pass. A
# supported variant that always reports `unhealthy` trains its operator to ignore the health column,
# which is why this replaces it rather than disabling it.
#
# Healthy means the two things that are actually true of THIS container when it is working:
#
#   1. the mandatory agent firewall from mitm/agent-entrypoint.sh is installed — default-deny on
#      OUTPUT, the pinned proxy ACCEPT rule, and the catch-all REJECT; and
#   2. the pinned sidecar proxy is reachable.
#
# It only reads. It runs no iptables mutation, opens no egress, and sends no request through the
# proxy: reachability is a TCP connect to a peer the firewall already permits. Resolution of the
# sidecar name is itself part of what is proven — DNS is REJECTed by that firewall, so the name can
# only resolve from the /etc/hosts pin the entrypoint installed.
#
# Every failure names the condition that was not met, so `docker inspect` shows a cause rather than
# a bare exit code.
#
# Exit status: 0 healthy, 1 unhealthy (any unmet condition).
set -uo pipefail

IPTABLES=${AGENT_HEALTHCHECK_IPTABLES:-iptables}
# Matches SIDECAR_HOST in mitm/agent-entrypoint.sh. The override exists for deterministic tests;
# the entrypoint does not read it, so do not use it to relocate the sidecar.
SIDECAR_HOST=${AGENT_HEALTHCHECK_SIDECAR_HOST:-claude-sandbox-egress}
SIDECAR_PORT=${AGENT_HEALTHCHECK_SIDECAR_PORT:-8888}
CONNECT_TIMEOUT=${AGENT_HEALTHCHECK_CONNECT_TIMEOUT:-5}

unhealthy() { printf 'unhealthy: %s\n' "$*" >&2; exit 1; }

# Bounded TCP connect without coreutils `timeout`, which is absent on macOS where this repository's
# own tests run. Nothing is written to the socket, so this cannot carry data anywhere.
probe_tcp() { # host port limit-seconds
    local host=$1 port=$2 limit=$3 pid ticks=0 max=$(( $3 * 10 ))
    bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge "$max" ]; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
        ticks=$(( ticks + 1 ))
        sleep 0.1
    done
    wait "$pid"
}

# --- 1. the mandatory agent firewall is installed --------------------------
rules=$("$IPTABLES" -S OUTPUT 2>/dev/null) || unhealthy "cannot read the OUTPUT chain (is NET_ADMIN present?)"
[ -n "$rules" ] || unhealthy "the OUTPUT chain is empty — the mandatory agent firewall is not installed"

grep -qx -- '-P OUTPUT DROP' <<<"$rules" \
    || unhealthy "OUTPUT policy is not DROP — the agent firewall is absent or has been flushed"

grep -qE -- "^-A OUTPUT .*-p tcp .*--dport ${SIDECAR_PORT} -j ACCEPT\$" <<<"$rules" \
    || unhealthy "no pinned ACCEPT rule for the sidecar proxy on port ${SIDECAR_PORT}"

# iptables renders this as `-A OUTPUT -j REJECT --reject-with icmp-port-unreachable`; match the
# rule rather than one rendering of it.
grep -qE -- '^-A OUTPUT -j REJECT( |$)' <<<"$rules" \
    || unhealthy "the catch-all OUTPUT REJECT is missing — egress would not fail closed"

# --- 2. the pinned sidecar proxy is reachable ------------------------------
# A bare TCP connect. Nothing is sent, so this cannot reach the internet even though the proxy can.
if ! probe_tcp "$SIDECAR_HOST" "$SIDECAR_PORT" "$CONNECT_TIMEOUT"; then
    unhealthy "cannot reach the pinned sidecar proxy at ${SIDECAR_HOST}:${SIDECAR_PORT}" \
              "(sidecar down, or the /etc/hosts pin is missing and DNS is correctly blocked)"
fi

echo "healthy: agent firewall installed and sidecar proxy ${SIDECAR_HOST}:${SIDECAR_PORT} reachable"
exit 0
