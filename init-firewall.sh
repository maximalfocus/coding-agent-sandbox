#!/bin/bash
# Egress control for the Claude Code sandbox — HOSTNAME-based, fail-closed.
#
# The ONLY process allowed to reach the public internet is the tinyproxy user; everything else
# must go through the proxy (HTTPS_PROXY), which allows by domain name. DNS, private/internal
# ranges, and IPv6 are all locked down so they can't become side channels.
set -euo pipefail
IFS=$'\n\t'

# 0. Close FIRST: default-DROP before flushing, so a re-run never has a transient ACCEPT window.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 1. Preserve Docker's internal DNS NAT (127.0.0.11) across the flush.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

PROXY_UID="$(id -u tinyproxy)"

# 2. Established replies first — so loopback responses (e.g. the proxy answering a client) and
#    ttyd return traffic to the host subnet flow before the narrow/REJECT rules below.
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A INPUT  -p tcp --dport 7681 -j ACCEPT   # ttyd web terminal (inbound only)

# 3. Loopback OUTPUT, narrowly. Only two NEW loopback flows are permitted: anyone -> the proxy on
#    127.0.0.1:8888, and the proxy user -> Docker's DNS resolver on 127.0.0.11. EVERYTHING else on
#    loopback is rejected — so a process (or the proxy, if an allowlisted name resolves to 127.x)
#    cannot SSRF a local service, and non-proxy DNS is blocked. (DNAT keeps dst=127.0.0.11.)
iptables -A OUTPUT -o lo -p tcp -d 127.0.0.1 --dport 8888 -j ACCEPT
iptables -A OUTPUT -o lo -d 127.0.0.11 -m owner --uid-owner "$PROXY_UID" -j ACCEPT
iptables -A OUTPUT -o lo -j REJECT --reject-with icmp-port-unreachable

# 4. Block NEW egress to private/internal/bogon ranges even for the proxy. Stops SSRF to cloud
#    metadata (169.254.169.254), the Docker gateway, lateral hops to other containers, and
#    loopback/this-host/reserved space — e.g. if an allowlisted hostname (mis)resolves to one.
for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
    iptables -A OUTPUT -d "$net" -j REJECT --reject-with icmp-admin-prohibited
done

# 5b. No DNS to the public internet — not even for the proxy. The proxy resolves only via Docker's
#     127.0.0.11 (allowed on loopback in step 3); rejecting public :53 here makes "DNS only to
#     127.0.0.11" actually enforced, closing DNS-over-public-resolver as a channel.
iptables -A OUTPUT -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -p tcp --dport 53 -j REJECT --reject-with icmp-port-unreachable

# 6. THE KEY RULE: only the proxy user may originate (public) internet traffic.
echo "Allowing public internet egress only for tinyproxy (uid $PROXY_UID)"
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j ACCEPT

# 7. Reject everything else.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 8. IPv6: lock the whole stack to DROP (close-first), so it can't become a silent bypass if
#    IPv6 is ever enabled on the Docker network. Best-effort (skip if v6 absent).
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1; then
    ip6tables -P INPUT DROP   2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP  2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    # NOTE: no `-o lo ACCEPT` for v6 — nothing here needs IPv6 loopback (the proxy and DNS are
    # IPv4 127.x), and leaving it open would allow ::1 SSRF. OUTPUT stays default-DROP.
    echo "IPv6 egress locked (default DROP, incl. loopback)."
else
    echo "IPv6 stack unavailable — nothing to lock."
fi

echo "Firewall ready (hostname-proxy egress only; DNS, private ranges, IPv6 locked)."
