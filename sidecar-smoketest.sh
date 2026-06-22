#!/usr/bin/env bash
# Automated smoke test for the experimental sidecar token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). Runs the STRUCTURAL guarantees that don't need a
# live login, and — if you've already done /login + ./claim-token.sh — the placeholder check too.
#
#   ./sidecar-smoketest.sh                 # assumes the stack is already up
#   ./sidecar-smoketest.sh --up            # bring the stack up (build) first, then test
#
# It does NOT perform /login (that's interactive device-auth) or a billed model call. Exit code is
# non-zero if any structural check fails.
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker-compose.sidecar.yml)
AGENT=claude-sandbox-node
EGRESS=claude-sandbox-egress
PLACEHOLDER="${TOKEN_PLACEHOLDER:-sandbox-placeholder-do-not-use}"
pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
no()   { echo "  FAIL  $1"; fail=$((fail+1)); }
note() { echo "  SKIP  $1"; skip=$((skip+1)); }
aexec() { "${COMPOSE[@]}" exec -T -u node "$AGENT" sh -c "$1" 2>/dev/null; }
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
    [ "$up_a" = "1" ] && [ "$up_e" = "1" ] && aexec 'test -s /etc/mitmproxy-ca/mitmproxy-ca-cert.pem' && break
    sleep 1
done
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$AGENT"  || { echo "agent container not running — see: ${COMPOSE[*]} logs $AGENT"; exit 1; }
"${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q "$EGRESS" || { echo "egress container not running — see: ${COMPOSE[*]} logs $EGRESS"; exit 1; }

echo "Structural guarantees (no login required):"

# 1. The agent has NO direct internet — only via the proxy. A non-proxied curl must fail.
if aexec 'env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy curl -s --max-time 6 -o /dev/null https://api.anthropic.com/'; then
    no "agent reached the internet WITHOUT the proxy (egress lockdown broken)"
else
    ok "agent has no direct internet (must go through the sidecar proxy)"
fi

# 2. The agent CANNOT see the vault — it's mounted only in the sidecar.
if aexec 'ls /var/lib/sandbox/secret' >/dev/null 2>&1; then
    no "agent can list /var/lib/sandbox/secret (vault leaked into the agent container)"
else
    ok "vault is not present in the agent container at all"
fi

# 3. The proxy path works end to end: TLS interception + CA trust + allowlist let the agent reach
#    api.anthropic.com (any HTTP status = the chain works; only a connect/TLS failure yields 000).
code=$(aexec "curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.anthropic.com/")
if [ -n "$code" ] && [ "$code" != "000" ]; then
    ok "agent reaches api.anthropic.com via the sidecar (HTTP $code; TLS+CA+proxy OK)"
else
    no "agent could not reach api.anthropic.com through the proxy (got '${code:-none}') — CA/proxy issue"
fi

# 4. The allowlist still denies a non-allowlisted host (content-mediation intact). For HTTPS through
#    a proxy the refusal is the CONNECT status, so read %{http_connect} — a denied tunnel leaves
#    %{http_code}=000 even though the proxy returned 403 (matches the repo's mitm self-test).
code=$(aexec "curl -sS -o /dev/null -w '%{http_connect}' --max-time 20 https://example.com/")
if [ "$code" = "403" ]; then
    ok "non-allowlisted host (example.com) denied at CONNECT (403)"
else
    no "example.com not denied as expected (http_connect='${code:-none}')"
fi

# 5. The sidecar actually holds the vault directory (sanity on the other side of the boundary).
if eexec 'test -d /var/lib/sandbox/secret'; then
    ok "sidecar holds the vault directory"
else
    no "sidecar is missing the vault directory"
fi

echo "Login-dependent checks:"
creds=$(aexec 'cat /home/node/.claude/.credentials.json' || true)
if [ -z "$creds" ]; then
    note "no login yet — run 'claude' + /login in the agent, then ./claim-token.sh, then re-run"
elif printf '%s' "$creds" | grep -q "\"accessToken\"[[:space:]]*:[[:space:]]*\"$PLACEHOLDER\""; then
    ok "agent config holds ONLY the placeholder token (claim succeeded; real token is in the vault)"
else
    note "a real token is still in the agent config — run ./claim-token.sh to move it into the vault"
fi

echo
echo "smoke test: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
