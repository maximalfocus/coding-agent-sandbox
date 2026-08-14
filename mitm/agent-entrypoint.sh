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
DIND_HOST="${NESTED_DOCKER_HOST:-claude-sandbox-dind}"
DIND_PORT="${NESTED_DOCKER_PORT:-2375}"

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

# 2b. Optional nested Docker daemon (issue #65). Default off, and an unrecognized value fails closed
#     exactly like every other capability gate. When on, the daemon address gets the same discipline
#     as the sidecar: resolved while Docker DNS still works, required to be a literal IPv4 that is
#     directly attached to the internal network (never loopback, never reached via a gateway), and
#     pinned into /etc/hosts. Anything less would mean widening the firewall to a guessed address.
NESTED_DOCKER=false
case "$(printf '%s' "${ENABLE_NESTED_DOCKER:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) NESTED_DOCKER=true ;;
    false|0|no|off) ;;
    *)
        echo "ERROR: unrecognized ENABLE_NESTED_DOCKER='${ENABLE_NESTED_DOCKER}' (fail-closed)." >&2
        exit 1
        ;;
esac

DIND_IP=""
DIND_IF=""
if [ "$NESTED_DOCKER" = true ]; then
    # Reject anything that is not a bare port number before it can reach an iptables argument.
    case "$DIND_PORT" in
        ''|*[!0-9]*) echo "ERROR: NESTED_DOCKER_PORT='$DIND_PORT' is not a port number" >&2; exit 1 ;;
    esac
    [ "$DIND_PORT" -ge 1 ] && [ "$DIND_PORT" -le 65535 ] || {
        echo "ERROR: NESTED_DOCKER_PORT='$DIND_PORT' is out of range" >&2; exit 1;
    }
    for _ in $(seq 1 100); do
        DIND_IP=$(getent ahostsv4 "$DIND_HOST" 2>/dev/null \
            | awk '$2 == "STREAM" { print $1; exit }')
        [ -n "$DIND_IP" ] && break
        sleep 0.2
    done
    case "$DIND_IP" in
        ''|*[!0-9.]*)
            echo "ERROR: ENABLE_NESTED_DOCKER is on but $DIND_HOST did not resolve to an IPv4 address" >&2
            echo "       Start with docker-compose.dind.yml or disable the option." >&2
            exit 1
            ;;
    esac
    DIND_ROUTE=$(ip -4 route get "$DIND_IP" 2>/dev/null) || {
        echo "ERROR: no route to resolved nested-daemon address $DIND_IP" >&2; exit 1;
    }
    DIND_IF=$(printf '%s\n' "$DIND_ROUTE" | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')
    if [ -z "$DIND_IF" ] || [ "$DIND_IF" = "lo" ] || printf '%s\n' "$DIND_ROUTE" | grep -q ' via '; then
        echo "ERROR: nested-daemon address $DIND_IP is not directly attached to the internal network" >&2
        exit 1
    fi
    if [ "$DIND_IP" = "$SIDECAR_IP" ]; then
        echo "ERROR: nested daemon resolved to the sidecar address $DIND_IP; refusing to widen the proxy rule" >&2
        exit 1
    fi
    HOSTS_TMP=$(mktemp /tmp/agent-hosts.XXXXXX)
    trap 'rm -f "$HOSTS_TMP"' EXIT
    grep -vE "[[:space:]]${DIND_HOST}([[:space:]]|$)" /etc/hosts > "$HOSTS_TMP"
    cat "$HOSTS_TMP" > /etc/hosts
    printf '%s %s\n' "$DIND_IP" "$DIND_HOST" >> /etc/hosts
    rm -f "$HOSTS_TMP"
    trap - EXIT
    say "Nested Docker daemon pinned at $DIND_IP:$DIND_PORT (no host daemon is reachable)."
fi

# 3. Mandatory agent firewall. The only non-loopback NEW connections are TCP/8888 to the pinned
#    sidecar address and, when nested Docker is explicitly enabled, the pinned daemon address on its
#    own port — each on its directly attached interface. Docker DNS is deliberately not preserved;
#    private/gateway ranges and every other destination fail closed. The agent never reaches the
#    internet directly and never reaches a host Docker socket, enabled or not.
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A INPUT  -p tcp --dport 7681 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -d 127.0.0.1/32 -j ACCEPT
iptables -A OUTPUT -o "$SIDECAR_IF" -p tcp -d "$SIDECAR_IP/32" --dport 8888 -j ACCEPT
# The nested-daemon rule must precede the private-range REJECTs below, because the daemon lives on
# the same RFC1918 internal network. It is a single pinned address and port, not a range.
if [ "$NESTED_DOCKER" = true ]; then
    iptables -A OUTPUT -o "$DIND_IF" -p tcp -d "$DIND_IP/32" --dport "$DIND_PORT" -j ACCEPT
fi
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
