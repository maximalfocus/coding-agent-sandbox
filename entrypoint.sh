#!/bin/bash
# As root: build the domain allowlist, start the hostname-filtering proxy, install the
# fail-closed firewall, self-test, then drop to `node` and run the requested command
# (e.g. `claude`) — or, with no command, the ttyd web terminal.
# Set SANDBOX_QUIET=1 to silence the informational setup output (errors still print).
set -euo pipefail

PROXY="http://127.0.0.1:8888"
FILTER_FILE="/etc/tinyproxy/filter"
say() { [ -n "${SANDBOX_QUIET:-}" ] || echo "$@"; }

# Domains every sandbox needs to FUNCTION. Hostname filtering lets us use clean parent domains:
# a single entry covers all subdomains (e.g. claude.com -> platform/downloads.*). These are not
# optional — without them Claude Code can't authenticate, infer, or install itself.
BASE_DOMAINS=(
    "anthropic.com"          # api.anthropic.com, console.anthropic.com (inference + auth)
    "claude.ai"              # subscription OAuth login
    "claude.com"             # platform.claude.com, downloads.claude.ai
    "npmjs.org"              # npm registry + tarballs
    "npmjs.com"
)

# GitHub is a CAPABILITY GRANT, not just a destination. It's the most powerful host that would
# otherwise be on by default: a general bidirectional channel — clone a payload IN, push/gist
# data OUT — so a prompt-injected agent could exfiltrate through it entirely within policy. The
# containment write-up's point is that "every function reachable through an allowlisted domain is
# now attack surface," so GitHub is a separate, deliberate toggle. Default ON (most coding wants
# git); set ALLOW_GITHUB=false for analysis-only or untrusted-workspace runs to drop it.
GITHUB_DOMAINS=(
    "github.com"             # git/gh over HTTPS
    "githubusercontent.com"  # raw/objects/codeload
)

# OpenAI/Codex egress is also a CAPABILITY GRANT (another vendor your code can flow to), so it's a
# separate, deliberate toggle — and unlike GitHub it defaults OFF (fail-closed for fresh clones).
# Enable with ALLOW_OPENAI=true to use the bundled Codex CLI for cross-vendor peer review.
OPENAI_DOMAINS=(
    "openai.com"   # api/auth/platform.openai.com — Codex API + ChatGPT OAuth
    "chatgpt.com"  # ChatGPT subscription backend + "Sign in with ChatGPT"
)

build_filter() {
    : > "$FILTER_FILE"
    local domains=("${BASE_DOMAINS[@]}") gh
    # Fail-closed: only recognized true-values (or unset) enable GitHub; an unrecognized value
    # (e.g. a "flase" typo) is treated as OFF — the safer side — not silently left on.
    case "$(printf '%s' "${ALLOW_GITHUB:-true}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) gh=1 ;;
        false|0|no|off) gh=0; say "  (GitHub egress OFF — ALLOW_GITHUB=${ALLOW_GITHUB})" ;;
        *) gh=0; echo "  WARN: unrecognized ALLOW_GITHUB='${ALLOW_GITHUB}' — treating as OFF (fail-closed)" >&2 ;;
    esac
    [ "$gh" = "1" ] && domains+=("${GITHUB_DOMAINS[@]}")
    local oai
    case "$(printf '%s' "${ALLOW_OPENAI:-false}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) oai=1; say "  (OpenAI/Codex egress ON — ALLOW_OPENAI=${ALLOW_OPENAI})" ;;
        false|0|no|off) oai=0 ;;
        *) oai=0; echo "  WARN: unrecognized ALLOW_OPENAI='${ALLOW_OPENAI}' — treating as OFF (fail-closed)" >&2 ;;
    esac
    [ "$oai" = "1" ] && domains+=("${OPENAI_DOMAINS[@]}")
    if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
        local OLDIFS=$IFS; IFS=','; set -f   # noglob: a stray '*' must not expand to /workspace files
        for d in $EXTRA_ALLOWED_DOMAINS; do
            d=$(echo "$d" | tr -d '[:space:]'); [ -z "$d" ] && continue
            # Don't let extras re-add GitHub once it's been disabled.
            if [ "$gh" = "0" ] && printf '%s' "$d" | grep -qiE '(^|\.)(github\.com|githubusercontent\.com)$'; then
                echo "  WARN: ignoring '$d' — GitHub egress is disabled (ALLOW_GITHUB)" >&2; continue
            fi
            domains+=("$d")
        done
        IFS=$OLDIFS; set +f
    fi
    for d in "${domains[@]}"; do
        # Strict hostname check: >=2 dot-separated labels, each starting/ending alphanumeric.
        # Rejects regex metachars ("*.x", "foo|.*"), leading/trailing dots/hyphens, empty labels,
        # AND single-label/public-suffix entries ("com" -> would allow ALL .com) and IPv4 literals
        # ("8.8.8.8") — so a bad entry can't widen the allowlist.
        if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
           || printf '%s' "$d" | grep -qE '^[0-9.]+$'; then
            echo "  WARN: ignoring invalid domain '$d' (need a multi-label hostname, not a TLD or IP)" >&2
            continue
        fi
        # Anchor so "anthropic.com" matches the domain and its subdomains, but NOT
        # "evil-anthropic.com". `(^|\.)<escaped-domain>$`
        esc=$(printf '%s' "$d" | sed 's/\./\\./g')
        printf '(^|\\.)%s$\n' "$esc" >> "$FILTER_FILE"
        say "  allow: $d"
    done
}

if [ "$(id -u)" = "0" ]; then
    say "Building hostname allowlist..."
    build_filter

    say "Starting hostname-filtering proxy (tinyproxy)..."
    tinyproxy -c /etc/tinyproxy/tinyproxy.conf
    for _ in $(seq 1 20); do
        { exec 3<>/dev/tcp/127.0.0.1/8888; } 2>/dev/null && { exec 3>&-; break; }
        sleep 0.2
    done

    if [ -n "${SANDBOX_QUIET:-}" ]; then
        /usr/local/bin/init-firewall.sh >/dev/null
    else
        /usr/local/bin/init-firewall.sh
    fi

    # --- self-tests ---
    # The security guarantees (#2 deny works, #3 bypass blocked) are FATAL. Reachability of
    # Anthropic (#1) is only a WARNING: the sandbox should still start offline / during an API
    # outage — Claude itself will report if it can't reach the API.
    say "Verifying egress policy..."
    if curl -s -o /dev/null --connect-timeout 8 -x "$PROXY" https://api.anthropic.com/; then
        say "  ok: api.anthropic.com allowed via proxy"
    else
        echo "  WARN: api.anthropic.com not reachable right now (offline?) — starting anyway" >&2
    fi
    deny=$(curl -sS -o /dev/null --connect-timeout 8 -x "$PROXY" https://example.com/ 2>&1 || true)
    if ! echo "$deny" | grep -q "403"; then
        echo "ERROR: example.com was NOT denied by the proxy (got: ${deny:-<connected>})" >&2; exit 1
    fi
    say "  ok: example.com denied by proxy (403 Filtered)"
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -s -o /dev/null --connect-timeout 5 https://1.1.1.1/ 2>/dev/null; then
        echo "ERROR: direct egress (no proxy) succeeded — firewall not effective" >&2; exit 1
    fi
    say "  ok: direct egress without the proxy is blocked"
    # DNS exfil channel closed: a non-proxy user cannot query Docker's resolver directly.
    if dig +time=2 +tries=1 example.com @127.0.0.11 >/dev/null 2>&1; then
        echo "ERROR: direct DNS to 127.0.0.11 worked as non-proxy — exfil channel open" >&2; exit 1
    fi
    say "  ok: direct DNS (non-proxy) is blocked"
    # Cloud-metadata / private-range SSRF is blocked (even though it's also proxy-only).
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -s -o /dev/null --connect-timeout 4 http://169.254.169.254/ 2>/dev/null; then
        echo "ERROR: link-local/metadata 169.254.169.254 reachable" >&2; exit 1
    fi
    say "  ok: link-local/metadata range unreachable"
    # IPv6 must not be a bypass (no v6 route today, but verify it stays closed).
    if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
         curl -6 -s -o /dev/null --connect-timeout 5 "https://[2606:4700:4700::1111]/" 2>/dev/null; then
        echo "ERROR: direct IPv6 egress succeeded — v6 not locked" >&2; exit 1
    fi
    say "  ok: direct IPv6 egress is blocked"

    # Own the config volume only. Do NOT `chown -R /workspace`: it's a bind mount of your real
    # project, and on Linux/WSL that would rewrite your host files' ownership (and be slow).
    mkdir -p /home/node/.claude
    chown -R node:node /home/node/.claude 2>/dev/null || true
    # Codex subscription login persists here (~/.codex/auth.json), like Claude's in .claude.
    mkdir -p /home/node/.codex
    chown -R node:node /home/node/.codex 2>/dev/null || true

    # Audit log handling (stays local — this is the persisted egress trail in the claude-audit
    # volume). Two protections:
    #  1) Tamper-resistance: the dir is owned by `tinyproxy` and locked to 0750, so the sandboxed
    #     `node` user (the agent) can neither read, alter, nor delete the trail. Only tinyproxy
    #     writes it, and `./audit.sh` reads it via a root `docker exec`.
    #  2) Bounded rotation: a root-side loop keeps the log from growing without limit using
    #     copytruncate (tinyproxy's open fd stays valid — no signal needed). `node` can't touch
    #     this loop (can't signal a root process), so the agent can't disable rotation either.
    # NB: we run chmod AS tinyproxy (via gosu), not root — the container drops CAP_FOWNER, so root
    # can't chmod a file it doesn't own, but the owner always can.
    chown tinyproxy:tinyproxy /var/log/tinyproxy 2>/dev/null || true
    gosu tinyproxy chmod 0750 /var/log/tinyproxy 2>/dev/null || true

    AUDIT_LOG=/var/log/tinyproxy/tinyproxy.log
    AUDIT_MAX_BYTES="${AUDIT_LOG_MAX_BYTES:-20971520}"   # 20 MiB per file
    AUDIT_KEEP="${AUDIT_LOG_KEEP:-5}"                     # rotated files to retain (~100 MiB total)
    AUDIT_INTERVAL="${AUDIT_ROTATE_INTERVAL:-3600}"       # check hourly
    rotate_audit() {
        [ -f "$AUDIT_LOG" ] || return 0
        local sz; sz="$(stat -c%s "$AUDIT_LOG" 2>/dev/null || echo 0)"
        [ "$sz" -ge "$AUDIT_MAX_BYTES" ] || return 0
        local i
        for ((i=AUDIT_KEEP-1; i>=1; i--)); do
            [ -f "$AUDIT_LOG.$i" ] && mv -f "$AUDIT_LOG.$i" "$AUDIT_LOG.$((i+1))"
        done
        cp "$AUDIT_LOG" "$AUDIT_LOG.1" && : > "$AUDIT_LOG"   # copytruncate
        rm -f "$AUDIT_LOG.$((AUDIT_KEEP+1))" 2>/dev/null || true
    }
    ( while :; do sleep "$AUDIT_INTERVAL"; rotate_audit || true; done ) &

    exec gosu node "$0" "$@"
fi

# --- now running as `node` (proxy + CLAUDE_CONFIG_DIR come from the image ENV) ---
cd /workspace 2>/dev/null || cd "$HOME"

# GitHub auth over HTTPS. SSH (port 22) is blocked by the firewall, so GitHub works via HTTPS +
# a token. If GITHUB_TOKEN is set, wire git to use it and rewrite SSH GitHub remotes to HTTPS so
# existing repos (git@github.com:...) just work for clone/pull/PUSH. Regenerated each start from
# the env (so it persists via .env). Requires ALLOW_GITHUB=true (the default).
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    git config --global --replace-all url."https://github.com/".insteadOf "git@github.com:"
    git config --global --add         url."https://github.com/".insteadOf "ssh://git@github.com/"
    [ -n "${GIT_USER_NAME:-}" ]  && git config --global user.name  "$GIT_USER_NAME"
    [ -n "${GIT_USER_EMAIL:-}" ] && git config --global user.email "$GIT_USER_EMAIL"
    ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials" )
fi

# A command was passed (e.g. `claude`, `bash -l`) -> run it. This is how the local-terminal
# `docker exec` / claude-safe `docker run` paths work.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# No command -> the browser web terminal.
TTYD_USER="${TTYD_USER:-coder}"; TTYD_PASS="${TTYD_PASS:-changeme}"
# Refuse to expose the terminal with a blank or well-known default password — even on
# localhost, local malware or an accidental port-forward could reach it.
case "$TTYD_PASS" in
    ""|changeme|please-change-me|password|coder|admin)
        echo "ERROR: set a strong TTYD_PASS in .env before using the web terminal" \
             "(refusing to start ttyd with a default/blank password)." >&2
        echo "       The local-terminal paths (./shell.sh, claude-safe) don't need it." >&2
        exit 1 ;;
esac
say "Open http://127.0.0.1:7681 — log in as '${TTYD_USER}'."
say "First run: type 'claude', then '/login' and paste the code from your browser."
exec ttyd -p 7681 -i 0.0.0.0 -W -c "${TTYD_USER}:${TTYD_PASS}" \
    tmux new-session -A -s claude
