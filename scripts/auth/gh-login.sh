#!/usr/bin/env bash
# Log in to the bundled GitHub CLI (gh) from inside the sandbox — the PERMANENT fix for pushing
# GitHub Actions workflow files (.github/workflows/*).
#
# Why this exists: a plain `repo`/Contents PAT in GITHUB_TOKEN pushes everything EXCEPT workflow
# files — GitHub rejects those without the `workflow` scope ("refusing to allow ... without
# `workflow` scope"), and a classic PAT's scopes are fixed at creation, so you cannot add the
# scope from inside the sandbox. `gh auth login`'s token DOES carry `workflow`. Authenticate once
# here; the login is saved in the persisted gh-config volume (~/.config/gh), and the entrypoint
# runs `gh auth setup-git` on every start so git uses gh's token for github.com. You won't hit
# the workflow-scope wall again.
#
# Uses the DEVICE flow (a URL + short code you authorize in any browser) — the same headless-
# friendly pattern as ./scripts/auth/codex-login.sh, no localhost callback. When prompted choose
# "Login with a web browser".
#
#   ./scripts/auth/gh-login.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

SVC=claude-sandbox

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

# GitHub egress must be on, or the device-auth polling is refused by the proxy.
docker compose exec -T "$SVC" grep -qi "github" /etc/tinyproxy/filter 2>/dev/null || {
    echo "GitHub egress is not enabled. Set ALLOW_GITHUB=true in .env, run ./run.sh, then retry."
    exit 1
}

cat <<'EOF'

Starting `gh auth login` (device flow). When prompted:
  1. Account: GitHub.com   ·   Protocol: HTTPS   ·   Authenticate Git: Yes
  2. "How would you like to authenticate?" -> Login with a web browser.
  3. gh prints a one-time code + https://github.com/login/device — open it in your browser on
     this laptop, paste the code, and approve (the consent screen includes the **workflow** scope).
  4. gh polls to finish; you'll see "Logged in as ...".

Saved in the persisted gh-config volume, so you only do this once. Ctrl-C to abort.

EOF

# Run as `node` so the login lands in /home/node/.config/gh (the persisted volume) and matches the
# user that runs git/gh in the web terminal. Request `workflow` explicitly so workflow-file pushes
# are covered, then wire git to use the gh token immediately (the entrypoint also does this on start).
docker compose exec -u node "$SVC" gh auth login --hostname github.com --git-protocol https --scopes workflow
docker compose exec -u node "$SVC" gh auth setup-git --hostname github.com
docker compose exec -u node "$SVC" gh auth status
