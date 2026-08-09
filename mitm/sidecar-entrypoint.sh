#!/bin/bash
# EXPERIMENTAL — egress sidecar entrypoint for the two-container token-isolation variant
# (docs/architecture/token-isolation-sidecar.md). This is mitm/entrypoint.sh WITHOUT the node
# hand-off: this container runs no agent. It holds the credential vault, injects the token, owns the
# OAuth refresh, and is the only container with internet. mitmdump runs in the foreground so the
# container's lifetime == the proxy's.
set -euo pipefail

CONFDIR="/etc/mitmproxy"                 # shared via the claude-mitm-ca volume; CA lands here
ADDON="/usr/local/share/mitm/filter_addon.py"
CA_PEM="$CONFDIR/mitmproxy-ca-cert.pem"
say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }

[ "$(id -u)" = "0" ] || { echo "sidecar-entrypoint must start as root" >&2; exit 1; }

# --- allowlist (compact parity with mitm/entrypoint.sh) ---
BASE_DOMAINS=(anthropic.com claude.ai claude.com npmjs.org npmjs.com herdr.dev opencode.ai pi.dev)
TOOL_UPGRADE_DOMAINS=(
    awscli.amazonaws.com bun.sh nodejs.org
    pypi.org files.pythonhosted.org bootstrap.pypa.io astral.sh
    rustup.rs static.rust-lang.org crates.io static.crates.io index.crates.io
    repo.maven.apache.org repo1.maven.org services.gradle.org plugins.gradle.org
    deb.debian.org security.debian.org cdn.playwright.dev
)
domains=("${BASE_DOMAINS[@]}")
case "$(printf '%s' "${ALLOW_GITHUB:-true}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) gh=1; domains+=(github.com githubusercontent.com) ;;
    false|0|no|off) gh=0 ;;
    *) gh=0; echo "  WARN: unrecognized ALLOW_GITHUB='${ALLOW_GITHUB}' — treating as OFF (fail-closed)" >&2 ;;
esac
case "$(printf '%s' "${ALLOW_TOOL_UPGRADES:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) domains+=("${TOOL_UPGRADE_DOMAINS[@]}") ;;
    false|0|no|off) ;;
    *) echo "  WARN: unrecognized ALLOW_TOOL_UPGRADES='${ALLOW_TOOL_UPGRADES}' — treating as OFF (fail-closed)" >&2 ;;
esac
aws_auth_hosts=""
if [ -n "${AWS_SSO_REGIONS:-}" ]; then
    aws_output=$(/usr/local/bin/aws-sso-domains "$AWS_SSO_REGIONS") || {
        echo "ERROR: invalid AWS_SSO_REGIONS; refusing to start" >&2; exit 1;
    }
    while IFS= read -r d; do [ -n "$d" ] && domains+=("$d"); done <<< "$aws_output"
    aws_auth_hosts=$(printf '%s\n' "$aws_output" | paste -sd, -)
fi
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    OLDIFS=$IFS; IFS=','; set -f
    for d in $EXTRA_ALLOWED_DOMAINS; do
        d=$(printf '%s' "$d" | tr -d '[:space:]')
        if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
           || printf '%s' "$d" | grep -qE '^[0-9.]+$'; then
            echo "  WARN: ignoring invalid domain '$d'" >&2; continue
        fi
        if [ "$gh" = "0" ] && printf '%s' "$d" | grep -qiE '(^|\.)(github\.com|githubusercontent\.com)$'; then
            echo "  WARN: ignoring '$d' — GitHub egress is disabled (ALLOW_GITHUB)" >&2; continue
        fi
        domains+=("$d")
    done
    IFS=$OLDIFS; set +f
fi
IFS=','; export ALLOWLIST="${domains[*]}"; unset IFS
# AWS CLI signs STS calls in Authorization; preserve it only for these exact allowlisted hosts.
export AUTH_HOSTS="anthropic.com,claude.ai,claude.com,github.com,githubusercontent.com${aws_auth_hosts:+,$aws_auth_hosts}"
export GITHUB_READONLY="${GITHUB_READONLY:-true}"
export ANTHROPIC_BLOCK_PATHS="${ANTHROPIC_BLOCK_PATHS:-/v1/files}"
export ANTHROPIC_SINGLE_CRED="${ANTHROPIC_SINGLE_CRED:-true}"
export AUDIT_LOG="${AUDIT_LOG:-/var/log/mitm/decisions.log}"
mkdir -p "$(dirname "$AUDIT_LOG")"; chown -R tinyproxy:tinyproxy "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

# --- token isolation: forced ON here (the sidecar's whole purpose) ---
export ANTHROPIC_TOKEN_ISOLATION=true
export TOKEN_SECRET_PATH="${TOKEN_SECRET_PATH:-/var/lib/sandbox/secret/credentials.json}"
export TOKEN_PLACEHOLDER="${TOKEN_PLACEHOLDER:-sandbox-placeholder-do-not-use}"
export OAUTH_TOKEN_URL="${OAUTH_TOKEN_URL:-https://platform.claude.com/v1/oauth/token}"
export OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-22422756-60c9-4084-8eb7-27705fd5cf9a}"
export TOKEN_REFRESH_SKEW="${TOKEN_REFRESH_SKEW:-600}"
secret_dir="$(dirname "$TOKEN_SECRET_PATH")"
# chmod AS the owner (gosu): the container drops CAP_FOWNER, so root can't chmod a tinyproxy-owned
# path — but the owner always can. (Same idiom as the audit-log handling in entrypoint.sh.)
mkdir -p "$secret_dir"; chown tinyproxy:tinyproxy "$secret_dir"; gosu tinyproxy chmod 0700 "$secret_dir"
[ -f "$TOKEN_SECRET_PATH" ] && { chown tinyproxy:tinyproxy "$TOKEN_SECRET_PATH"; gosu tinyproxy chmod 0600 "$TOKEN_SECRET_PATH"; }
# node's .claude is created here so claim-token can read a /login. The claim itself runs AFTER
# the proxy port is confirmed listening below: claim-token validates the login against the OAuth
# server through the proxy (root cannot egress directly) before vaulting (issue #44).
mkdir -p /home/node/.claude && chown node:node /home/node/.claude 2>/dev/null || true

mkdir -p "$CONFDIR"; chown tinyproxy:tinyproxy "$CONFDIR"
say "Allowlist: $ALLOWLIST"
say "Starting mitmdump (egress sidecar)..."
# Bind 0.0.0.0 so the agent container can reach us over the internal network AND localhost self-tests
# work; the firewall below restricts :8888 to the internal interface only (never the egress side).
gosu tinyproxy mitmdump --quiet \
    --mode regular --listen-host 0.0.0.0 --listen-port 8888 \
    --set confdir="$CONFDIR" --set rawtcp=false --set connection_strategy=lazy \
    -s "$ADDON" >/var/log/mitm.log 2>&1 &
MITM_PID=$!

for _ in $(seq 1 50); do [ -f "$CA_PEM" ] && break; sleep 0.2; done
[ -f "$CA_PEM" ] || { echo "ERROR: mitmproxy CA not generated; see /var/log/mitm.log" >&2; cat /var/log/mitm.log >&2; exit 1; }
gosu tinyproxy chmod 0644 "$CA_PEM" 2>/dev/null || true   # agent reads it (ro mount) to trust the CA
proxy_ready=0
for _ in $(seq 1 50); do
    if { exec 3<>/dev/tcp/127.0.0.1/8888; } 2>/dev/null; then
        exec 3>&-
        proxy_ready=1
        break
    fi
    sleep 0.2
done
[ "$proxy_ready" = "1" ] || { echo "ERROR: mitmproxy port 8888 did not become ready" >&2; exit 1; }

# Reconcile a login into the vault now that the proxy is up (issue #44): claim-token validates the
# login against the OAuth server through the proxy before vaulting. No-op once claimed; fail-closed
# on an unreachable/invalid login — the boot continues and any prior vault remains unchanged. With
# no prior vault, the addon passes requests through.
/usr/local/bin/claim-token || echo "  WARN: claim-token reconciliation failed (continuing)" >&2

# --- firewall: fail-closed egress, plus accept :8888 only on the internal interface ---
EGRESS_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
INTERNAL_IF="$(ip -o -4 addr show 2>/dev/null | awk -v e="${EGRESS_IF:-}" '$2!="lo" && $2!=e {print $2; exit}')"
say "Interfaces: egress=${EGRESS_IF:-?} internal=${INTERNAL_IF:-?}"
PROXY_UID="$(id -u tinyproxy)"
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
# The agent reaches the proxy here — accept :8888 ONLY on the internal interface (never egress side).
[ -n "${INTERNAL_IF:-}" ] && iptables -A INPUT -i "$INTERNAL_IF" -p tcp --dport 8888 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -d 127.0.0.11 -m owner --uid-owner "$PROXY_UID" -j ACCEPT
# claim-token (root) reconciles a /login through the proxy on demand; allow NEW loopback connects
# to :8888 only (the proxy enforces the allowlist; no other local services exist here).
iptables -A OUTPUT -o lo -p tcp -d 127.0.0.1 --dport 8888 \
    -m owner --uid-owner 0 -j ACCEPT
iptables -A OUTPUT -o lo -j REJECT
for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
    iptables -A OUTPUT -d "$net" -j REJECT
done
iptables -A OUTPUT -p udp --dport 53 -j REJECT
iptables -A OUTPUT -p tcp --dport 53 -j REJECT
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j ACCEPT     # only the proxy egresses
iptables -A OUTPUT -j REJECT
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L >/dev/null 2>&1; then
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
fi
say "Sidecar firewall ready (proxy-only egress; :8888 inbound on internal iface only)."

say "Egress sidecar up — proxying for the agent container."
wait "$MITM_PID"     # container lives as long as the proxy does; restart policy handles a crash
