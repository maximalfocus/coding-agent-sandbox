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
    # ~/ws holds the cloned skill repos (skills-setup.sh). Own it so node can clone/commit/push.
    mkdir -p /home/node/ws
    chown node:node /home/node/ws 2>/dev/null || true

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

# GitHub auth over HTTPS. SSH (port 22) is blocked by the firewall, so GitHub works via HTTPS.
# Two credential sources, with gh PREFERRED because only gh can push workflow files:
#   - gh login (./gh-login.sh, persisted in ~/.config/gh): its token carries the `workflow` scope,
#     so `git push` of .github/workflows/* works. `gh auth setup-git` points git at it.
#   - GITHUB_TOKEN (.env PAT): fallback. Pushes everything EXCEPT workflow files unless the PAT
#     itself has `workflow` — and a classic PAT's scopes are fixed at creation, so that can't be
#     fixed from inside the sandbox (run ./gh-login.sh instead). We warn at startup if it lacks it.
# Either way, rewrite SSH github remotes to HTTPS so existing repos just work. Needs ALLOW_GITHUB.
_set_git_identity() {
    git config --global --replace-all url."https://github.com/".insteadOf "git@github.com:"
    git config --global --add         url."https://github.com/".insteadOf "ssh://git@github.com/"
    [ -n "${GIT_USER_NAME:-}" ]  && git config --global user.name  "$GIT_USER_NAME"
    [ -n "${GIT_USER_EMAIL:-}" ] && git config --global user.email "$GIT_USER_EMAIL"
}
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    # Persisted gh login present -> use it for github.com (workflow-scope pushes work).
    _set_git_identity
    rm -f "$HOME/.git-credentials" 2>/dev/null || true   # drop any stale non-workflow PAT creds
    gh auth setup-git --hostname github.com 2>/dev/null \
        && echo "✅ git authenticated via gh for github.com (workflow-scope pushes OK)."
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    _set_git_identity
    ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials" )
    # Heads-up if this PAT can't push workflow files. Classic PATs expose scopes via the
    # x-oauth-scopes header; fine-grained PATs don't (empty) -> we stay quiet for those.
    if [ "${ALLOW_GITHUB:-true}" != "false" ]; then
        _scopes="$(curl -fsS -m 8 -o /dev/null -D - -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                   https://api.github.com/user 2>/dev/null | tr -d '\r' \
                   | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')"
        if [ -n "${_scopes}" ] && ! printf '%s' "${_scopes}" | grep -qw workflow; then
            echo "⚠️  GITHUB_TOKEN lacks the 'workflow' scope (have: ${_scopes})." >&2
            echo "    Pushes to .github/workflows/* WILL be rejected by GitHub. CDD impl repos ship" >&2
            echo "    CI workflows — run ./gh-login.sh once for a permanent workflow-scoped login," >&2
            echo "    or regenerate the PAT with the 'workflow' scope added." >&2
        fi
    fi
fi

# tmux config for the web terminal (regenerated each start; ~ isn't a persisted volume):
#  - mouse on        -> click a pane to focus, drag borders to resize, scroll to scroll
#  - set-clipboard on + terminal-features clipboard -> a mouse selection is copied to your real
#    system clipboard via OSC 52 (tmux -> ttyd -> browser), like local tmux. Without this, a
#    selection only lands in tmux's own buffer and nothing reaches the OS clipboard.
# tmux config for the web terminal (regenerated each start; ~ isn't a persisted volume).
# For real copy/paste, prefer a LOCAL terminal via `./shell.sh --attach` (iTerm / Windows Terminal
# understand OSC 52, so set-clipboard on -> selection copies to the OS clipboard). ttyd's xterm.js
# does NOT consume OSC 52, so in the browser use Ctrl-b y: it zooms the pane + turns mouse off so a
# drag selects ONLY that pane (no cross-pane bleed), then Cmd/Ctrl+C; Ctrl-b y again to exit.
cat > "$HOME/.tmux.conf" <<'TMUXCONF'
set -g mouse on
set -g set-clipboard on
set -as terminal-features ',*:clipboard'
bind m set -g mouse \; display-message "tmux mouse #{?mouse,ON (click panes),OFF (drag-select)}"
bind y if -F '#{window_zoomed_flag}' \
  'resize-pane -Z ; set -g mouse on  ; display-message "copy mode OFF (panes clickable)"' \
  'resize-pane -Z ; set -g mouse off ; display-message "copy mode ON: drag-select THIS pane, then Cmd/Ctrl+C, then Ctrl-b y"'
TMUXCONF

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
# Open the browser terminal via the shared launcher: attach to the 'claude' session, building the
# 2x2 grid on first use. The SAME script backs shell.sh/shell.ps1 --attach, so the grid is identical
# however you connect. Override the grid with TTYD_GRID=1 (single pane) in .env.
exec ttyd -p 7681 -i 0.0.0.0 -W -c "${TTYD_USER}:${TTYD_PASS}" \
    /usr/local/bin/sandbox-tmux
