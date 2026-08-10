#!/usr/bin/env bash
# Automated smoke test for the experimental sidecar token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). Runs the STRUCTURAL guarantees that don't need a
# live login, and — if you've already done /login + ./scripts/auth/claim-token.sh — the placeholder check too.
#
#   ./sidecar-smoketest.sh                 # assumes the stack is already up
#   ./sidecar-smoketest.sh --up            # bring the stack up (build) first, then test
#
# It does NOT perform /login (that's interactive device-auth) or a billed model call. Exit code is
# non-zero if any structural check fails.
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker-compose.sidecar.yml)
if [ -n "${SIDECAR_COMPOSE_OVERRIDE:-}" ]; then
    COMPOSE+=(-f "$SIDECAR_COMPOSE_OVERRIDE")
fi
AGENT=claude-sandbox-node
EGRESS=claude-sandbox-egress
PLACEHOLDER="${TOKEN_PLACEHOLDER:-sandbox-placeholder-do-not-use}"
pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
no()   { echo "  FAIL  $1"; fail=$((fail+1)); }
note() { echo "  SKIP  $1"; skip=$((skip+1)); }
aexec() { "${COMPOSE[@]}" exec -T -u node "$AGENT" sh -c "$1" 2>/dev/null; }
rexec() { "${COMPOSE[@]}" exec -T -u root "$AGENT" sh -c "$1" 2>/dev/null; }
eexec() { "${COMPOSE[@]}" exec -T -u root "$EGRESS" sh -c "$1" 2>/dev/null; }

# --- preflight ---
command -v docker >/dev/null 2>&1 || { echo "docker not found — run this in a real terminal (iTerm2) with Colima/Docker."; exit 2; }
docker info >/dev/null 2>&1        || { echo "Docker daemon not reachable — start it first (e.g. 'colima start' in iTerm2)."; exit 2; }

if [ "${1:-}" = "--up" ]; then
    echo "Bringing up the sidecar stack (build)..."
    docker compose build >/dev/null || { echo "base/mitm image build failed"; exit 1; }
    "${COMPOSE[@]}" up -d --build >/dev/null || { echo "compose up failed"; exit 1; }
fi

# Readiness: both containers running, and the agent has trusted the CA (proxy is up).
echo "Waiting for the stack to be ready..."
for _ in $(seq 1 60); do
    up_a=$("${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c "$AGENT" || true)
    up_e=$("${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c "$EGRESS" || true)
    # The CA file appears as soon as the SIDECAR publishes it, which can precede the agent's
    # mandatory firewall by a second or two. Only start the structural checks once both containers
    # have installed their relevant proxy rules (issues #45 and #49).
    [ "$up_a" = "1" ] && [ "$up_e" = "1" ] \
        && aexec 'test -s /etc/mitmproxy-ca/mitmproxy-ca-cert.pem' \
        && rexec 'iptables -S OUTPUT | grep -q -- "-P OUTPUT DROP"' \
        && rexec 'iptables -S OUTPUT | grep -q -- "--dport 8888 -j ACCEPT"' \
        && eexec 'iptables -S INPUT | grep -q -- "--dport 8888 -j ACCEPT"' && break
    sleep 1
done
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$AGENT"  || { echo "agent container not running — see: ${COMPOSE[*]} logs $AGENT"; exit 1; }
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$EGRESS" || { echo "egress container not running — see: ${COMPOSE[*]} logs $EGRESS"; exit 1; }

echo "Structural guarantees (no login required):"

# 1. The agent firewall is mandatory and default-deny; an AGENT_FIREWALL setting cannot disable it.
if rexec 'iptables -S OUTPUT | grep -qx -- "-P OUTPUT DROP"'; then
    ok "agent firewall is mandatory (OUTPUT policy DROP)"
else
    no "agent firewall is not enforcing a default-DROP OUTPUT policy"
fi

# 2. Read Docker's internal endpoint after startup and confirm :8888 is accepted only on its local
#    interface, never on the default-route interface or without an interface match. The sidecar
#    intentionally blocks root from querying Docker DNS after startup, so validate the configured
#    network-only alias through Docker metadata and the entrypoint decision log instead.
sidecar_id=$(docker inspect --format '{{.Id}}' "$EGRESS" 2>/dev/null)
sidecar_internal_network=""
for network_id in $(docker inspect --format '{{range .NetworkSettings.Networks}}{{println .NetworkID}}{{end}}' "$EGRESS" 2>/dev/null); do
    if [ "$(docker network inspect --format '{{.Internal}}' "$network_id" 2>/dev/null)" = true ]; then
        [ -z "$sidecar_internal_network" ] || { sidecar_internal_network="AMBIGUOUS"; break; }
        sidecar_internal_network=$(docker network inspect --format '{{.Name}}' "$network_id" 2>/dev/null)
    fi
done
configured_alias=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$EGRESS" 2>/dev/null \
    | sed -n 's/^SIDECAR_INTERNAL_ALIAS=//p')
sidecar_internal_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$sidecar_internal_network\").IPAddress}}" "$EGRESS" 2>/dev/null)
sidecar_internal_if=$(eexec "ip -o -4 addr show | awk -v target='$sidecar_internal_ip' '{ split(\$4, addr, \"/\"); iface = \$2; sub(/@.*/, \"\", iface); if (addr[1] == target) print iface }' | sort -u")
sidecar_egress_if=$(eexec 'ip -o -4 route show default | awk "{ for (i=1; i<=NF; i++) if (\$i == \"dev\") print \$(i+1) }" | sort -u')
if [ -n "$sidecar_id" ] && [ -n "$sidecar_internal_network" ] && [ "$sidecar_internal_network" != AMBIGUOUS ] \
   && [ -n "$configured_alias" ] && [ -n "$sidecar_internal_ip" ] \
   && docker inspect --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{range $cfg.Aliases}}{{printf "%s %s\n" $name .}}{{end}}{{end}}' "$EGRESS" \
        | grep -Fxq "$sidecar_internal_network $configured_alias" \
   && docker logs "$EGRESS" 2>&1 | grep -Fq "internal_ip=$sidecar_internal_ip alias=$configured_alias" \
   && [ -n "$sidecar_internal_if" ] && [ -n "$sidecar_egress_if" ] \
   && [ "$sidecar_internal_if" != "$sidecar_egress_if" ] \
   && eexec "iptables -C INPUT -i '$sidecar_internal_if' -p tcp --dport 8888 -j ACCEPT" \
   && ! eexec "iptables -C INPUT -i '$sidecar_egress_if' -p tcp --dport 8888 -j ACCEPT" \
   && ! eexec 'iptables -C INPUT -p tcp --dport 8888 -j ACCEPT'; then
    ok "sidecar accepts :8888 only on verified internal interface $sidecar_internal_if ($sidecar_internal_ip)"
else
    no "sidecar :8888 INPUT rule is not bound exclusively to its verified internal interface"
fi

# 3. Resolve the sidecar from the pinned /etc/hosts entry and confirm the only proxy-port allow rule
#    is bound to that exact IPv4 address and interface (not tcp/8888 to any destination).
pinned_ip=$(aexec "getent ahostsv4 $EGRESS | awk '\$2 == \"STREAM\" { print \$1; exit }'")
pinned_if=$(rexec "ip -4 route get '${pinned_ip:-invalid}' | awk '{ for (i=1; i<=NF; i++) if (\$i == \"dev\") { print \$(i+1); exit } }'")
if [ -n "$pinned_ip" ] && [ -n "$pinned_if" ] \
   && rexec "grep -Eq '^${pinned_ip//./\\.}[[:space:]]+$EGRESS([[:space:]]|$)' /etc/hosts" \
   && rexec "iptables -C OUTPUT -o '$pinned_if' -p tcp -d '$pinned_ip/32' --dport 8888 -j ACCEPT" \
   && ! rexec 'iptables -C OUTPUT -p tcp --dport 8888 -j ACCEPT'; then
    ok "sidecar proxy is pinned to $pinned_ip:8888 on $pinned_if"
else
    no "proxy allow rule is not pinned to the sidecar's /etc/hosts IPv4 and interface"
fi

# 4. DNS canary: Docker's embedded resolver must not accept arbitrary agent queries after startup.
if aexec 'dig +short +time=2 +tries=1 issue-45-dns-canary.invalid @127.0.0.11' >/dev/null 2>&1; then
    no "agent queried Docker DNS directly (DNS exfiltration channel open)"
else
    ok "Docker DNS rejects the agent DNS canary; sidecar resolution is hosts-pinned"
fi

# 5. The Docker network gateway is a private target and must be covered by an explicit REJECT rule.
#    An internal network omits the endpoint's .Gateway, so read the gateway from network IPAM.
network_id=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$AGENT" 2>/dev/null)
gateway=$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$network_id" 2>/dev/null)
case "$gateway" in
    10.*) gateway_net=10.0.0.0/8 ;;
    172.*) gateway_net=172.16.0.0/12 ;;
    192.168.*) gateway_net=192.168.0.0/16 ;;
    *) gateway_net="" ;;
esac
if [ -n "$gateway" ] && [ -n "$gateway_net" ] \
   && rexec "iptables -C OUTPUT -d '$gateway_net' -j REJECT" \
   && ! aexec "timeout 3 socat - TCP:'$gateway':80" >/dev/null 2>&1; then
    ok "Docker host gateway $gateway is explicitly rejected"
else
    no "Docker host gateway is not covered by the agent's private-range rejection"
fi

# 6. The agent has NO direct internet — only via the proxy. A non-proxied curl must fail.
if aexec 'env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy curl -s --max-time 6 -o /dev/null https://api.anthropic.com/'; then
    no "agent reached the internet WITHOUT the proxy (egress lockdown broken)"
else
    ok "agent has no direct internet (must go through the sidecar proxy)"
fi

# 7. The agent CANNOT see the vault — it's mounted only in the sidecar.
if aexec 'ls /var/lib/sandbox/secret' >/dev/null 2>&1; then
    no "agent can list /var/lib/sandbox/secret (vault leaked into the agent container)"
else
    ok "vault is not present in the agent container at all"
fi

# 8. The proxy path works end to end: TLS interception + CA trust + allowlist let the agent reach
#    api.anthropic.com (any HTTP status = the chain works; only a connect/TLS failure yields 000).
code=$(aexec "curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.anthropic.com/")
if [ -n "$code" ] && [ "$code" != "000" ]; then
    ok "agent reaches api.anthropic.com via the sidecar (HTTP $code; TLS+CA+proxy OK)"
else
    no "agent could not reach api.anthropic.com through the proxy (got '${code:-none}') — CA/proxy issue"
fi

# 9. The allowlist still denies a non-allowlisted host (content-mediation intact). For HTTPS through
#    a proxy the refusal is the CONNECT status, so read %{http_connect} — a denied tunnel leaves
#    %{http_code}=000 even though the proxy returned 403 (matches the repo's mitm self-test).
code=$(aexec "curl -sS -o /dev/null -w '%{http_connect}' --max-time 20 https://example.com/")
if [ "$code" = "403" ]; then
    ok "non-allowlisted host (example.com) denied at CONNECT (403)"
else
    no "example.com not denied as expected (http_connect='${code:-none}')"
fi

# 10. The sidecar actually holds the vault directory (sanity on the other side of the boundary).
if eexec 'test -d /var/lib/sandbox/secret'; then
    ok "sidecar holds the vault directory"
else
    no "sidecar is missing the vault directory"
fi

echo "Login-dependent checks:"
creds=$(aexec 'cat /home/node/.claude/.credentials.json' || true)
if [ -z "$creds" ]; then
    note "no login yet — run 'claude' + /login in the agent, then ./scripts/auth/claim-token.sh, then re-run"
elif printf '%s' "$creds" | grep -q "\"accessToken\"[[:space:]]*:[[:space:]]*\"$PLACEHOLDER\""; then
    ok "agent config holds ONLY the placeholder token (claim succeeded; real token is in the vault)"
else
    note "a real token is still in the agent config — run ./scripts/auth/claim-token.sh to move it into the vault"
fi

echo
echo "smoke test: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
