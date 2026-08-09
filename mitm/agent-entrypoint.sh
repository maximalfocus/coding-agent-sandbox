#!/bin/bash
# EXPERIMENTAL — agent-container entrypoint for the two-container token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). This container runs claude/tools but NO proxy and
# has NO internet route except via the egress sidecar. As root it: trusts the sidecar's intercept CA
# (shared, read-only), optionally installs a belt-and-braces firewall, then hands off to the STOCK
# node-side entrypoint as `node` (reusing git/gh/tmux/ttyd setup). Because we exec it as node, the
# root half of entrypoint.sh — which would start tinyproxy — is skipped.
set -euo pipefail

say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }
CA_SRC="${NODE_EXTRA_CA_CERTS:-/etc/mitmproxy-ca/mitmproxy-ca-cert.pem}"

[ "$(id -u)" = "0" ] || exec /usr/local/bin/entrypoint.sh "$@"

# 1. Wait for the sidecar to publish its CA (also our readiness signal that mitmdump is up), then
#    trust it system-wide so curl/git/python/node validate the intercepted TLS.
for _ in $(seq 1 100); do [ -s "$CA_SRC" ] && break; sleep 0.2; done
if [ -s "$CA_SRC" ]; then
    cp "$CA_SRC" /usr/local/share/ca-certificates/mitmproxy.crt
    update-ca-certificates >/dev/null 2>&1 || true
    say "Trusted the egress sidecar's intercept CA."
else
    echo "WARN: sidecar CA not present at $CA_SRC after wait — TLS to allowed hosts may fail" >&2
fi

# 2. Optional defense-in-depth firewall (default off; the internal:true network already blocks
#    off-host egress). When on, the agent may only reach loopback, Docker DNS, and the proxy port.
case "$(printf '%s' "${AGENT_FIREWALL:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
        iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
        DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)
        iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
        if [ -n "$DOCKER_DNS_RULES" ]; then
            iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
            iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
            echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
        fi
        iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT  -i lo -j ACCEPT
        iptables -A INPUT  -p tcp --dport 7681 -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT
        iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT            # Docker DNS (resolve the sidecar name)
        iptables -A OUTPUT -p tcp --dport 8888 -j ACCEPT      # the sidecar proxy (internal net only)
        iptables -A OUTPUT -j REJECT
        say "Agent firewall ON (loopback + Docker DNS + proxy :8888 only)."
        ;;
esac

# 3. Hand off to the stock node-side entrypoint (git/gh, tmux, ttyd or the passed command).
exec gosu node /usr/local/bin/entrypoint.sh "$@"
