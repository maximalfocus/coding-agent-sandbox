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
    "herdr.dev"              # Herdr update manifest + documentation
    "opencode.ai"            # OpenCode first-party API/auth/update endpoints
    "pi.dev"                  # Pi update checks + model catalogs
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

# Official download/package endpoints used to deliberately upgrade bundled tools and the common
# development toolchains shipped/supported by this sandbox. This is opt-in because every package
# registry is also a payload-ingress channel. GitHub-hosted upgrades (Herdr, gh, Bun/OpenCode
# releases) remain governed by ALLOW_GITHUB; npm-hosted upgrades (Claude, Codex, Pi, OpenCode,
# Playwright) already use the always-required npm registry.
TOOL_UPGRADE_DOMAINS=(
    "awscli.amazonaws.com"   # AWS CLI v2 installers
    "bun.sh"                 # Bun installer metadata (release assets are GitHub-gated)
    "nodejs.org"             # Node.js distributions
    "pypi.org" "files.pythonhosted.org" "bootstrap.pypa.io"
    "astral.sh"              # uv/ruff installers
    "rustup.rs" "static.rust-lang.org"
    "crates.io" "static.crates.io" "index.crates.io"
    "repo.maven.apache.org" "repo1.maven.org"
    "services.gradle.org" "plugins.gradle.org"
    "deb.debian.org" "security.debian.org"
    "download.docker.com"     # Docker CLI/Buildx/Compose apt repository
    "cdn.playwright.dev"
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
    local upgrades
    case "$(printf '%s' "${ALLOW_TOOL_UPGRADES:-false}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) upgrades=1; say "  (tool-upgrade egress ON — ALLOW_TOOL_UPGRADES=${ALLOW_TOOL_UPGRADES})" ;;
        false|0|no|off) upgrades=0 ;;
        *) upgrades=0; echo "  WARN: unrecognized ALLOW_TOOL_UPGRADES='${ALLOW_TOOL_UPGRADES}' — treating as OFF (fail-closed)" >&2 ;;
    esac
    [ "$upgrades" = "1" ] && domains+=("${TOOL_UPGRADE_DOMAINS[@]}")
    if [ -n "${AWS_SSO_REGIONS:-}" ]; then
        local aws_output d
        aws_output=$(/usr/local/bin/aws-sso-domains "$AWS_SSO_REGIONS") || {
            echo "ERROR: invalid AWS_SSO_REGIONS; refusing to start" >&2; return 1;
        }
        while IFS= read -r d; do [ -n "$d" ] && domains+=("$d"); done <<< "$aws_output"
        say "  (AWS IAM Identity Center egress ON — exact regional OIDC/portal/STS hosts)"
    fi
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

    # Host Docker access is an explicit, high-impact opt-in. The override mounts the socket but
    # socket ownership varies by host (Docker Desktop commonly presents gid 0; Linux uses its
    # docker group gid). Add node to that existing numeric group without changing the bind-mounted
    # socket's host ownership. Never infer enablement merely from a socket that happens to exist.
    case "$(printf '%s' "${ENABLE_DOCKER_HOST:-false}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on)
            if [ ! -S /var/run/docker.sock ]; then
                echo "ERROR: ENABLE_DOCKER_HOST is on but /var/run/docker.sock is not a socket." >&2
                echo "       Start with docker-compose.host.yml or disable the option." >&2
                exit 1
            fi
            docker_gid="$(stat -c '%g' /var/run/docker.sock)"
            docker_group="$(getent group "$docker_gid" | cut -d: -f1 || true)"
            if [ -z "$docker_group" ]; then
                docker_group=sandbox-docker-host
                groupadd --gid "$docker_gid" "$docker_group"
            fi
            usermod -aG "$docker_group" node
            say "  WARNING: host Docker daemon access ENABLED (host containment is not preserved)"
            ;;
        false|0|no|off) ;;
        *)
            echo "ERROR: unrecognized ENABLE_DOCKER_HOST='${ENABLE_DOCKER_HOST}' (fail-closed)." >&2
            exit 1
            ;;
    esac

    # Own the config volume only. Do NOT `chown -R /workspace`: it's a bind mount of your real
    # project, and on Linux/WSL that would rewrite your host files' ownership (and be slow).
    mkdir -p /home/node/.claude
    chown -R node:node /home/node/.claude 2>/dev/null || true
    # Codex subscription login persists here (~/.codex/auth.json), like Claude's in .claude.
    mkdir -p /home/node/.codex
    chown -R node:node /home/node/.codex 2>/dev/null || true
    # GitHub CLI login persists here (~/.config/gh/hosts.yml), like Codex's above. A fresh
    # claude-gh volume mounts root-owned, so without this chown `gh auth login` (run as node by
    # ./scripts/auth/gh-login.sh) fails to write hosts.yml with "permission denied".
    mkdir -p /home/node/.config/gh
    chown -R node:node /home/node/.config 2>/dev/null || true
    # The opt-in AWS named volume also mounts root-owned when first created. Initialize it only
    # when regional AWS SSO egress is enabled, before the terminal drops to the node user.
    if [ -n "${AWS_SSO_REGIONS:-}" ]; then
        mkdir -p /home/node/.aws
        chown -R node:node /home/node/.aws
    fi
    # Skill repos (scripts/skills/skills-setup.sh) are cloned into /workspace/personal — a bind mount of your real
    # host folder, owned by the host user and writable via the file-sharing layer; nothing to chown.

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
#   - gh login (./scripts/auth/gh-login.sh, persisted in ~/.config/gh): its token carries the `workflow` scope,
#     so `git push` of .github/workflows/* works. `gh auth setup-git` points git at it.
#   - GITHUB_TOKEN (.env PAT): fallback. Pushes everything EXCEPT workflow files unless the PAT
#     itself has `workflow` — and a classic PAT's scopes are fixed at creation, so that can't be
#     fixed from inside the sandbox (run ./scripts/auth/gh-login.sh instead). We warn at startup if it lacks it.
# Either way, rewrite SSH github remotes to HTTPS so existing repos just work. Needs ALLOW_GITHUB.
_set_git_identity() {
    git config --global --replace-all url."https://github.com/".insteadOf "git@github.com:"
    git config --global --add         url."https://github.com/".insteadOf "ssh://git@github.com/"
    [ -n "${GIT_USER_NAME:-}" ]  && git config --global user.name  "$GIT_USER_NAME"
    [ -n "${GIT_USER_EMAIL:-}" ] && git config --global user.email "$GIT_USER_EMAIL"
    # Never let this function's exit status depend on whether the optional identity vars are set:
    # the trailing `[ -n "" ] && ...` returns 1 when GIT_USER_EMAIL is unset, which under `set -e`
    # (this script) would kill the entrypoint as soon as a gh login/token exists. Always succeed.
    return 0
}
# Rewrite SSH github remotes -> HTTPS UNCONDITIONALLY (it needs no credentials). Previously this
# only ran inside the gh/token branches, so a no-credential boot left SSH-remote clones in
# /workspace/personal unusable (SSH/22 is firewalled — `git` could not even resolve the host).
_set_git_identity
# Set when a usable github credential is wired below; gates boot-time skill cloning + the reminder.
GIT_CREDS_OK=
# Detect a STORED gh login INDEPENDENT of the env token: `gh auth status` would otherwise report
# "logged in" merely because GITHUB_TOKEN is set, so clear the env tokens for the probe.
if command -v gh >/dev/null 2>&1 && env -u GITHUB_TOKEN -u GH_TOKEN gh auth status --hostname github.com >/dev/null 2>&1; then
    # A persisted gh login exists; its token carries `workflow`. But gh AND git prefer the env
    # GITHUB_TOKEN when it is set, so a bare `setup-git` would still hand git the non-workflow env
    # PAT. Fix: UPGRADE the env token to gh's (workflow-scoped) one and use it everywhere — git
    # store creds, gh's credential helper, and any script that reads $GITHUB_TOKEN. Exported before
    # the final `exec ttyd`, so every web-terminal shell inherits the workflow-capable token.
    _ghtok="$(env -u GITHUB_TOKEN -u GH_TOKEN gh auth token --hostname github.com 2>/dev/null)"
    [ -n "${_ghtok}" ] && export GITHUB_TOKEN="${_ghtok}"
    git config --global credential.helper store
    ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials" )
    gh auth setup-git --hostname github.com 2>/dev/null || true
    GIT_CREDS_OK=1
    echo "✅ git uses the gh login's workflow-scoped token for github.com (workflow-file pushes OK)."
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials" )
    GIT_CREDS_OK=1
    # Heads-up if this PAT can't push workflow files. Classic PATs expose scopes via the
    # x-oauth-scopes header; fine-grained PATs don't (empty) -> we stay quiet for those.
    if [ "${ALLOW_GITHUB:-true}" != "false" ]; then
        _scopes="$(curl -fsS -m 8 -o /dev/null -D - -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                   https://api.github.com/user 2>/dev/null | tr -d '\r' \
                   | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')"
        if [ -n "${_scopes}" ] && ! printf '%s' "${_scopes}" | grep -qw workflow; then
            echo "⚠️  GITHUB_TOKEN lacks the 'workflow' scope (have: ${_scopes})." >&2
            echo "    Pushes to .github/workflows/* WILL be rejected by GitHub. CDD impl repos ship" >&2
            echo "    CI workflows — run ./scripts/auth/gh-login.sh once for a permanent workflow-scoped login," >&2
            echo "    or regenerate the PAT with the 'workflow' scope added." >&2
        fi
    fi
fi

# --- Skills: clone (best-effort) + link on every boot ---------------------------------------------
# Skills load from $CLAUDE_CONFIG_DIR/skills. The link step is credential-free (it just symlinks
# repos already present in /workspace/personal), so skills auto-load on every boot and survive
# claude-config volume resets — no manual skills-setup.sh needed. Everything here is wrapped to be
# NON-FATAL: the entrypoint runs under `set -euo pipefail` and has a history of startup restart-loops
# (commit 04805e8), so a skills hiccup must never stop the container from booting.
#
# Skills are an OPTIONAL capability and deliberately contribute NOTHING to the first-run checklist
# below: an operator who never asked for them has no setup left to finish, and an item they cannot
# act on is what teaches them to skim past the one item that matters. Problems here are reported on
# stderr at boot, where a transient failure belongs.
personal_writable=1
[ -w /workspace/personal ] 2>/dev/null || personal_writable=
# Optional boot-time clone of any SKILL_REPOS not yet on disk — only when we have a usable credential
# AND GitHub egress. Non-interactive + time-bounded so a network stall can't hang startup. The host
# scripts/skills/skills-setup.sh remains the canonical clone/pull path; this is just convenience.
if [ -n "${SKILL_REPOS:-}" ] && [ -n "${GIT_CREDS_OK:-}" ] && [ "${ALLOW_GITHUB:-true}" != "false" ] \
   && [ -n "$personal_writable" ]; then
    for _url in $SKILL_REPOS; do
        _name="${_url##*/}"; _name="${_name%.git}"
        _dir="/workspace/personal/$_name"
        [ -d "$_dir/.git" ] && continue
        echo "  cloning skill repo $_name ..."
        if ! GIT_TERMINAL_PROMPT=0 timeout 180 git clone "$_url" "$_dir" >/dev/null 2>&1; then
            echo "  (clone of $_name failed — non-fatal; run ./scripts/skills/skills-setup.sh once GitHub access works)" >&2
        fi
    done
fi
# Link the managed skill set (reads SKILL_REPOS, else the prior-run manifest). Always non-fatal.
if command -v sandbox-link-skills >/dev/null 2>&1; then
    sandbox-link-skills || echo "  (skill linking reported an error — non-fatal)" >&2
fi
# Build ~/.sandbox-todo from ACTUAL unmet state. The shell hint (/etc/profile.d/zz-sandbox-todo.sh)
# prints it in every interactive shell until it's gone; recomputed each boot ($HOME is ephemeral).
#
# It carries ONLY setup the operator must still complete on the host for the sandbox to work as
# documented. That is the GitHub credential and nothing else: everything else the sandbox needs is
# already in the image or the compose stack, and an optional capability is not unfinished setup.
# The markers below delimit the block that scripts/test-first-run-checklist.sh extracts and runs.
# >>> sandbox-todo >>>
_todo="$HOME/.sandbox-todo"; _items=""
if [ -z "${GIT_CREDS_OK:-}" ]; then
    _items="${_items}
  [ ] GitHub credentials not set — git clone/pull/push over HTTPS will fail, and pushes to
      .github/workflows/* need a workflow-scoped token.
      Fix once (persists): on the HOST run  ./scripts/auth/gh-login.sh   (workflow-scoped, recommended)
      or set GITHUB_TOKEN=... in .env and restart the sandbox."
fi
if [ -n "$_items" ]; then
    {
        echo "⚙️  Sandbox setup — finish these once (this note clears itself when done):"
        printf '%s\n' "$_items"
    } > "$_todo" 2>/dev/null || true
else
    rm -f "$_todo" 2>/dev/null || true
fi
# <<< sandbox-todo <<<

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
say "Herdr is the primary terminal. Start an agent from its terminal pane."
# Run Herdr directly. Herdr already persists its own server/session, so an outer tmux layer only
# interferes with mouse handling and OSC 52 clipboard delivery.
exec ttyd -p 7681 -i 0.0.0.0 -W \
    -I /usr/local/share/ttyd/index.html \
    -c "${TTYD_USER}:${TTYD_PASS}" \
    /usr/local/bin/herdr
