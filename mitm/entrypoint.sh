#!/bin/bash
# Root entrypoint for the OPT-IN mitmproxy (TLS-intercepting) egress variant.
# Starts mitmdump as the `tinyproxy` egress user (so the existing UID-based firewall applies
# unchanged), trusts its CA inside the container, installs the fail-closed firewall, self-tests
# TLS interception, then hands off to the shared node-side entrypoint (workspace + command/ttyd).
set -euo pipefail

PROXY="http://127.0.0.1:8888"
CONFDIR="/etc/mitmproxy"
ADDON="/usr/local/share/mitm/filter_addon.py"
CA_PEM="$CONFDIR/mitmproxy-ca-cert.pem"
say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }

# Always-on hosts (parity with the default entrypoint's BASE_DOMAINS); GitHub + extras layered on.
BASE_DOMAINS=(anthropic.com claude.ai claude.com npmjs.org npmjs.com)
GITHUB_DOMAINS=(github.com githubusercontent.com)

build_allowlist() {
    local domains=("${BASE_DOMAINS[@]}") gh
    # Fail-closed: only recognized true-values (or unset) enable GitHub; anything unrecognized
    # (e.g. a "flase" typo) is treated as OFF, the safer side, not silently left on.
    case "$(printf '%s' "${ALLOW_GITHUB:-true}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) gh=1 ;;
        false|0|no|off) gh=0; say "  (GitHub egress OFF — ALLOW_GITHUB=${ALLOW_GITHUB})" ;;
        *) gh=0; echo "  WARN: unrecognized ALLOW_GITHUB='${ALLOW_GITHUB}' — treating as OFF (fail-closed)" >&2 ;;
    esac
    [ "$gh" = "1" ] && domains+=("${GITHUB_DOMAINS[@]}")
    if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
        local OLDIFS=$IFS; IFS=','; set -f   # noglob: a stray '*' must not expand to /workspace files
        for d in $EXTRA_ALLOWED_DOMAINS; do
            d=$(printf '%s' "$d" | tr -d '[:space:]')
            # Strict multi-label/no-IP check (parity with the default path).
            if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
               || printf '%s' "$d" | grep -qE '^[0-9.]+$'; then
                echo "  WARN: ignoring invalid domain '$d'" >&2; continue
            fi
            # Don't let extras re-add GitHub once it's been disabled.
            if [ "$gh" = "0" ] && printf '%s' "$d" | grep -qiE '(^|\.)(github\.com|githubusercontent\.com)$'; then
                echo "  WARN: ignoring '$d' — GitHub egress is disabled (ALLOW_GITHUB)" >&2; continue
            fi
            domains+=("$d")
        done
        IFS=$OLDIFS; set +f
    fi
    local IFS=','; printf '%s' "${domains[*]}"
}

if [ "$(id -u)" = "0" ]; then
    # Auth is only ever forwarded to first-party + GitHub; everything else gets it stripped.
    ALLOWLIST="$(build_allowlist)"; export ALLOWLIST
    AUTH_HOSTS="anthropic.com,claude.ai,claude.com,github.com,githubusercontent.com"; export AUTH_HOSTS
    export GITHUB_READONLY="${GITHUB_READONLY:-true}"
    # Anthropic API hardening knobs (see mitm/filter_addon.py).
    export ANTHROPIC_BLOCK_PATHS="${ANTHROPIC_BLOCK_PATHS:-/v1/files}"
    export ANTHROPIC_SINGLE_CRED="${ANTHROPIC_SINGLE_CRED:-true}"
    export ANTHROPIC_PIN_TOKEN="${ANTHROPIC_PIN_TOKEN:-}"
    # Persisted decision log (the audit trail; surfaced by audit.sh --mitm). The addon runs as the
    # tinyproxy user, so the dir must be writable by it.
    export AUDIT_LOG="${AUDIT_LOG:-/var/log/mitm/decisions.log}"
    mkdir -p "$(dirname "$AUDIT_LOG")"; chown -R tinyproxy:tinyproxy "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
    say "Allowlist: $ALLOWLIST"
    say "GitHub read-only: $GITHUB_READONLY | Anthropic block: $ANTHROPIC_BLOCK_PATHS | token-pin: $([ -n "$ANTHROPIC_PIN_TOKEN" ] && echo on || echo off)"

    mkdir -p "$CONFDIR"; chown tinyproxy:tinyproxy "$CONFDIR"

    say "Starting mitmproxy (TLS-intercepting egress) as the tinyproxy user..."
    # Regular HTTP-proxy mode on 8888 (clients already point HTTPS_PROXY here). Hardening:
    #   rawtcp=false            — no raw-TCP passthrough, so a CONNECT can't tunnel arbitrary,
    #                             non-HTTP/TLS traffic past the addon's allowlist.
    #   connection_strategy=lazy— don't open the upstream connection until the request is seen and
    #                             allowed (no connect-then-reject window).
    # We do NOT pass --ssl-insecure: mitm validates the *upstream* cert against the system CA bundle,
    # so an on-path attacker can't impersonate an allowlisted host. (Downstream we present our own CA,
    # trusted below.) The addon (-s) enforces the allowlist + content rules on every request/CONNECT.
    gosu tinyproxy mitmdump --quiet \
        --mode regular --listen-host 127.0.0.1 --listen-port 8888 \
        --set confdir="$CONFDIR" --set rawtcp=false --set connection_strategy=lazy \
        -s "$ADDON" >/var/log/mitm.log 2>&1 &

    # Wait for the CA to be generated, then trust it container-wide (system store + node/git/python
    # pick it up via the CA env vars baked into the image).
    for _ in $(seq 1 50); do [ -f "$CA_PEM" ] && break; sleep 0.2; done
    if [ ! -f "$CA_PEM" ]; then echo "ERROR: mitmproxy CA not generated; see /var/log/mitm.log" >&2; cat /var/log/mitm.log >&2; exit 1; fi
    cp "$CA_PEM" /usr/local/share/ca-certificates/mitmproxy.crt
    update-ca-certificates >/dev/null 2>&1 || true
    # Wait for the proxy port to accept connections.
    for _ in $(seq 1 50); do { exec 3<>/dev/tcp/127.0.0.1/8888; } 2>/dev/null && { exec 3>&-; break; }; sleep 0.2; done

    if [ -n "${SANDBOX_QUIET:-}" ]; then /usr/local/bin/init-firewall.sh >/dev/null; else /usr/local/bin/init-firewall.sh; fi

    # --- self-tests (TLS interception + the security guarantees) ---
    say "Verifying mediated egress..."
    if curl -s -o /dev/null --connect-timeout 8 -x "$PROXY" https://registry.npmjs.org/; then
        say "  ok: allowlisted host reachable with the trusted intercept CA"
    else
        echo "  WARN: registry.npmjs.org not reachable right now (offline?) — starting anyway" >&2
    fi
    if ! curl -s -o /dev/null --connect-timeout 8 -w '%{http_code}' -x "$PROXY" http://example.com/ 2>/dev/null | grep -q 403; then
        echo "ERROR: example.com was NOT denied by the mitm allowlist (http)" >&2; exit 1
    fi
    say "  ok: non-allowlisted host denied (http 403)"
    # HTTPS too: a non-allowlisted CONNECT must be refused *with 403* at the gate. Assert the proxy's
    # CONNECT status specifically (%{http_connect}) so a DNS/offline/TLS failure can't masquerade as
    # a denial and mask a CONNECT-gate regression.
    hc=$(curl -s -o /dev/null -w '%{http_connect}' --connect-timeout 8 -x "$PROXY" https://example.com/ 2>/dev/null || true)
    if [ "$hc" != "403" ]; then
        echo "ERROR: https CONNECT to example.com not refused with 403 (got '${hc:-none}')" >&2; exit 1
    fi
    say "  ok: non-allowlisted CONNECT (https) denied (403)"
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -s -o /dev/null --connect-timeout 5 https://1.1.1.1/ 2>/dev/null; then
        echo "ERROR: direct egress (no proxy) succeeded — firewall not effective" >&2; exit 1
    fi
    say "  ok: direct egress without the proxy is blocked"
    # Same fatal channel checks as the default entrypoint — the firewall installs identical rules,
    # but verify them here too (the IPv6 lock is best-effort, so a silent failure must be caught).
    if dig +time=2 +tries=1 example.com @127.0.0.11 >/dev/null 2>&1; then
        echo "ERROR: direct DNS to 127.0.0.11 worked as non-proxy — exfil channel open" >&2; exit 1
    fi
    say "  ok: direct DNS (non-proxy) is blocked"
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -s -o /dev/null --connect-timeout 4 http://169.254.169.254/ 2>/dev/null; then
        echo "ERROR: link-local/metadata 169.254.169.254 reachable" >&2; exit 1
    fi
    say "  ok: link-local/metadata range unreachable"
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -6 -s -o /dev/null --connect-timeout 5 "https://[2606:4700:4700::1111]/" 2>/dev/null; then
        echo "ERROR: direct IPv6 egress succeeded — v6 not locked" >&2; exit 1
    fi
    say "  ok: direct IPv6 egress is blocked"

    mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude 2>/dev/null || true

    # Hand off to the shared node-side entrypoint (cd /workspace, run command or ttyd).
    exec gosu node /usr/local/bin/entrypoint.sh "$@"
fi

# Never reached as non-root (handoff goes to entrypoint.sh), but keep a sane fallback.
exec /usr/local/bin/entrypoint.sh "$@"
