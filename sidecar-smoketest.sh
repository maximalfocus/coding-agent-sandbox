#!/usr/bin/env bash
# Automated smoke test for the experimental sidecar token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). Runs the STRUCTURAL guarantees that don't need a
# live login, and — if you've already done /login + ./scripts/auth/claim-token.sh — the placeholder check too.
#
#   ./sidecar-smoketest.sh                 # assumes the stack is already up
#   ./sidecar-smoketest.sh --up            # bring the stack up (build) first, then test
#
# Targeting an isolated stack. Validation work needs issue-specific containers, networks, and volumes
# that must not touch an operator's credential volumes, so every name this script addresses is
# selectable, consistently through the environment:
#
#   SIDECAR_COMPOSE_PROJECT        Compose project to address (-p). Without it, the default project
#                                  is used and `ps`/`exec` would address the operator's stack.
#   SIDECAR_AGENT_CONTAINER_NAME   agent container name for `docker inspect`
#   SIDECAR_EGRESS_CONTAINER_NAME  egress container name for `docker inspect`
#   SIDECAR_COMPOSE_OVERRIDE       extra `-f` overlay (e.g. docker-compose.dind.yml)
#
#   SIDECAR_COMPOSE_PROJECT=idd69 SIDECAR_AGENT_CONTAINER_NAME=idd69-agent \
#     SIDECAR_EGRESS_CONTAINER_NAME=idd69-egress ./sidecar-smoketest.sh
#
# It does NOT perform /login (that's interactive device-auth) or a billed model call. Exit code is
# non-zero if any structural check fails.
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose)
# Scope every `ps`/`exec` to the selected project. The container-name variables below only affect
# `docker inspect`, so without this the script would inspect an isolated stack while executing
# against the default one (issue #69).
if [ -n "${SIDECAR_COMPOSE_PROJECT:-}" ]; then
    COMPOSE+=(-p "$SIDECAR_COMPOSE_PROJECT")
fi
COMPOSE+=(-f docker-compose.sidecar.yml)
if [ -n "${SIDECAR_COMPOSE_OVERRIDE:-}" ]; then
    COMPOSE+=(-f "$SIDECAR_COMPOSE_OVERRIDE")
fi
AGENT=claude-sandbox-node
EGRESS=claude-sandbox-egress
AGENT_CONTAINER="${SIDECAR_AGENT_CONTAINER_NAME:-claude-sandbox-node}"
EGRESS_CONTAINER="${SIDECAR_EGRESS_CONTAINER_NAME:-claude-sandbox-egress}"
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
    up_a=$("${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c "$AGENT_CONTAINER" || true)
    up_e=$("${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c "$EGRESS_CONTAINER" || true)
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
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$AGENT_CONTAINER"  || { echo "agent container not running — see: ${COMPOSE[*]} logs $AGENT"; exit 1; }
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$EGRESS_CONTAINER" || { echo "egress container not running — see: ${COMPOSE[*]} logs $EGRESS"; exit 1; }

echo "Structural guarantees (no login required):"

# 1. The agent firewall is mandatory and default-deny; an AGENT_FIREWALL setting cannot disable it.
if rexec 'iptables -S OUTPUT | grep -qx -- "-P OUTPUT DROP"'; then
    ok "agent firewall is mandatory (OUTPUT policy DROP)"
else
    no "agent firewall is not enforcing a default-DROP OUTPUT policy"
fi

# 2. Confirm :8888 is accepted only on the sidecar's internal interface, never on the default-route
#    interface and never without an interface match. The sidecar intentionally blocks root from
#    querying Docker DNS after startup, so the configured network-only alias is validated through
#    Docker's current network metadata rather than by resolving it.
#
#    Every condition below is read at the moment of the check: current Docker metadata, the
#    container's current addresses and routes, and the current iptables rules. This check used to
#    also require a line in `docker logs` to still match — a historical fact whose read races with
#    the log driver. Measured over 20 runs on one healthy stack, that single condition failed 7
#    times while every other condition passed 20/20 and the live interface mapping never moved, so
#    the flake was in the observation, not the boundary (issue #69). Nothing here reads the log.
#
#    Each condition names its own cause, so a failure says which one was not met.
verify_sidecar_input_binding() {
    local network_id internal_network alias ip iface_count binding_internal_if binding_egress_if

    docker inspect --format '{{.Id}}' "$EGRESS_CONTAINER" >/dev/null 2>&1 \
        || { echo "egress container is not inspectable"; return 1; }

    internal_network=""
    for network_id in $(docker inspect --format '{{range .NetworkSettings.Networks}}{{println .NetworkID}}{{end}}' "$EGRESS_CONTAINER" 2>/dev/null); do
        if [ "$(docker network inspect --format '{{.Internal}}' "$network_id" 2>/dev/null)" = true ]; then
            [ -z "$internal_network" ] || { echo "sidecar is attached to more than one internal network"; return 1; }
            internal_network=$(docker network inspect --format '{{.Name}}' "$network_id" 2>/dev/null)
        fi
    done
    [ -n "$internal_network" ] || { echo "sidecar is attached to no internal network"; return 1; }

    alias=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$EGRESS_CONTAINER" 2>/dev/null \
        | sed -n 's/^SIDECAR_INTERNAL_ALIAS=//p')
    [ -n "$alias" ] || { echo "SIDECAR_INTERNAL_ALIAS is not set on the egress container"; return 1; }

    docker inspect --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{range $cfg.Aliases}}{{printf "%s %s\n" $name .}}{{end}}{{end}}' "$EGRESS_CONTAINER" 2>/dev/null \
        | grep -Fxq "$internal_network $alias" \
        || { echo "alias '$alias' is not bound to the internal network '$internal_network'"; return 1; }

    ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$internal_network\").IPAddress}}" "$EGRESS_CONTAINER" 2>/dev/null)
    [ -n "$ip" ] || { echo "sidecar has no IPv4 address on '$internal_network'"; return 1; }

    # Exactly one local interface must own that address. `sort -u` alone would let two interfaces
    # through as a multi-line value and produce a confusing iptables error further down.
    binding_internal_if=$(eexec "ip -o -4 addr show | awk -v target='$ip' '{ split(\$4, addr, \"/\"); iface = \$2; sub(/@.*/, \"\", iface); if (addr[1] == target) print iface }' | sort -u")
    [ -n "$binding_internal_if" ] || { echo "no local interface owns the internal address $ip"; return 1; }
    iface_count=$(printf '%s\n' "$binding_internal_if" | grep -c .)
    [ "$iface_count" -eq 1 ] || { echo "$iface_count interfaces own the internal address $ip"; return 1; }

    binding_egress_if=$(eexec 'ip -o -4 route show default | awk "{ for (i=1; i<=NF; i++) if (\$i == \"dev\") print \$(i+1) }" | sort -u')
    [ -n "$binding_egress_if" ] || { echo "sidecar has no default-route interface"; return 1; }
    [ "$binding_internal_if" != "$binding_egress_if" ] \
        || { echo "internal and default-route interface are the same ($binding_internal_if)"; return 1; }

    eexec "iptables -C INPUT -i '$binding_internal_if' -p tcp --dport 8888 -j ACCEPT" \
        || { echo ":8888 is not accepted on the internal interface $binding_internal_if"; return 1; }
    ! eexec "iptables -C INPUT -i '$binding_egress_if' -p tcp --dport 8888 -j ACCEPT" \
        || { echo ":8888 is ALSO accepted on the egress interface $binding_egress_if"; return 1; }
    ! eexec 'iptables -C INPUT -p tcp --dport 8888 -j ACCEPT' \
        || { echo "a bare :8888 INPUT rule accepts on every interface"; return 1; }

    echo "$binding_internal_if ($ip)"
    return 0
}

if binding_detail=$(verify_sidecar_input_binding); then
    ok "sidecar accepts :8888 only on verified internal interface $binding_detail"
else
    no "sidecar :8888 INPUT rule is not bound exclusively to its verified internal interface — $binding_detail"
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
network_id=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$AGENT_CONTAINER" 2>/dev/null)
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

deepseek_gate=$(eexec 'printf %s "${ALLOW_DEEPSEEK:-false}"' | tr '[:upper:]' '[:lower:]')
if [ "$deepseek_gate" = true ] || [ "$deepseek_gate" = 1 ] \
   || [ "$deepseek_gate" = yes ] || [ "$deepseek_gate" = on ]; then
    echo "DeepSeek sidecar-only checks:"

    agent_deepseek_env=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$AGENT_CONTAINER" 2>/dev/null \
        | sed -n 's/^DEEPSEEK_API_KEY=//p')
    if [ "$agent_deepseek_env" = "sandbox-placeholder-do-not-use" ] \
       && ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$EGRESS_CONTAINER" 2>/dev/null \
            | grep -q '^DEEPSEEK_API_KEY='; then
        ok "Docker metadata gives the agent only the inert DeepSeek placeholder"
    else
        no "DeepSeek key boundary is not reflected safely in container metadata"
    fi

    if ! aexec 'test -e /var/lib/sandbox/deepseek' \
       && eexec '/usr/local/bin/deepseek-key validate'; then
        ok "DeepSeek key volume exists only in the sidecar and passes ownership/mode validation"
    else
        no "DeepSeek key storage is missing, unsafe, or visible to the agent"
    fi

    code=$(aexec "curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.deepseek.com/")
    if [ -n "$code" ] && [ "$code" != "000" ] \
       && eexec "grep -F 'INJECT' /var/log/mitm/decisions.log | grep -Fq 'api.deepseek.com/'"; then
        ok "exact api.deepseek.com proxy path injects from sidecar storage (HTTP $code)"
    else
        no "exact DeepSeek proxy/injection path failed (HTTP '${code:-none}')"
    fi

    code=$(aexec "curl -sS -o /dev/null -w '%{http_connect}' --max-time 20 https://evil.api.deepseek.com/")
    if [ "$code" = "403" ]; then
        ok "DeepSeek subdomain near-miss denied at CONNECT (403)"
    else
        no "DeepSeek subdomain near-miss was not denied (http_connect='${code:-none}')"
    fi
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
