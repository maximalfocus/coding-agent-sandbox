#!/bin/bash
# EXPERIMENTAL — agent-container entrypoint for the two-container token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). This container runs claude/tools but NO proxy and
# has NO internet route except via the egress sidecar. As root it: trusts the sidecar's intercept CA
# (shared, read-only), pins the sidecar address, installs a mandatory fail-closed firewall, then
# hands off to the STOCK
# node-side entrypoint as `node` (reusing git/gh/tmux/ttyd setup). Because we exec it as node, the
# root half of entrypoint.sh — which would start tinyproxy — is skipped.
set -euo pipefail

say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }
CA_SRC="${NODE_EXTRA_CA_CERTS:-/etc/mitmproxy-ca/mitmproxy-ca-cert.pem}"
SIDECAR_HOST="claude-sandbox-egress"

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

# 2. Resolve the sidecar exactly once while Docker DNS is still available. Pin the result in
#    /etc/hosts so clients do not need DNS after the firewall closes that exfiltration channel.
SIDECAR_IP=""
for _ in $(seq 1 100); do
    SIDECAR_IP=$(getent ahostsv4 "$SIDECAR_HOST" 2>/dev/null \
        | awk '$2 == "STREAM" { print $1; exit }')
    [ -n "$SIDECAR_IP" ] && break
    sleep 0.2
done
case "$SIDECAR_IP" in
    ''|*[!0-9.]*) echo "ERROR: could not resolve a valid IPv4 address for $SIDECAR_HOST" >&2; exit 1 ;;
esac
SIDECAR_ROUTE=$(ip -4 route get "$SIDECAR_IP" 2>/dev/null) || {
    echo "ERROR: no route to resolved sidecar address $SIDECAR_IP" >&2; exit 1;
}
SIDECAR_IF=$(printf '%s\n' "$SIDECAR_ROUTE" | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')
if [ -z "$SIDECAR_IF" ] || [ "$SIDECAR_IF" = "lo" ] || printf '%s\n' "$SIDECAR_ROUTE" | grep -q ' via '; then
    echo "ERROR: sidecar address $SIDECAR_IP is not directly attached to the internal network" >&2
    exit 1
fi
HOSTS_TMP=$(mktemp /tmp/agent-hosts.XXXXXX)
trap 'rm -f "$HOSTS_TMP"' EXIT
grep -vE "[[:space:]]${SIDECAR_HOST}([[:space:]]|$)" /etc/hosts > "$HOSTS_TMP"
cat "$HOSTS_TMP" > /etc/hosts
printf '%s %s\n' "$SIDECAR_IP" "$SIDECAR_HOST" >> /etc/hosts
rm -f "$HOSTS_TMP"
trap - EXIT

# 3. Mandatory agent firewall. The only non-loopback NEW connection is TCP/8888 to the pinned
#    sidecar address on its directly attached interface. Docker DNS is deliberately not preserved;
#    private/gateway ranges and every other destination fail closed.
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A INPUT  -p tcp --dport 7681 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -d 127.0.0.1/32 -j ACCEPT
iptables -A OUTPUT -o "$SIDECAR_IF" -p tcp -d "$SIDECAR_IP/32" --dport 8888 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j REJECT
iptables -A OUTPUT -p tcp --dport 53 -j REJECT
for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
    iptables -A OUTPUT -d "$net" -j REJECT
done
iptables -A OUTPUT -j REJECT

if [ -s /proc/net/if_inet6 ]; then
    command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1 || {
        echo "ERROR: IPv6 is enabled but ip6tables is unavailable" >&2; exit 1;
    }
    ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT DROP
    ip6tables -F; ip6tables -X
    ip6tables -A INPUT -i lo -s ::1/128 -j ACCEPT
    ip6tables -A OUTPUT -o lo -d ::1/128 -j ACCEPT
fi
say "Agent firewall ready (DNS blocked; proxy pinned to $SIDECAR_IP:8888 on $SIDECAR_IF)."

# 4. Hand off to the stock node-side entrypoint (git/gh, tmux, ttyd or the passed command).
exec gosu node /usr/local/bin/entrypoint.sh "$@"
