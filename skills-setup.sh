#!/usr/bin/env bash
# Clone (or update) your skill repos INTO the sandbox and load Claude's skills from those live git
# working copies — so /cdd, /peer-review, etc. work, AND their *-evolve commands can commit and
# push to GitHub (over HTTPS with your GITHUB_TOKEN). Unlike sync-skills.sh (which copies detached
# content), this keeps each skill as a real git clone with a remote, so evolve can push.
#
# Repos are cloned into ~/ws inside the sandbox (a persisted volume) — the SAME path the *-evolve
# skills hardcode (~/ws/cdd-skills, ~/ws/peerreview-skills) — so self-evolve/commit/push works in
# the sandbox exactly as on the host. Independent of WORKSPACE_DIR; available in every project.
# Re-run anytime to `git pull` the latest. Same behaviour on macOS, Linux, and Windows.
#
#   ./skills-setup.sh                          # uses SKILL_REPOS from .env
#   ./skills-setup.sh https://github.com/you/x-skills.git ...   # or pass HTTPS git URLs
set -euo pipefail
cd "$(dirname "$0")"
SVC=claude-sandbox

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

if [ "$#" -gt 0 ]; then
    repos="$*"
else
    repos="$(grep -E '^SKILL_REPOS=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
fi
[ -n "$repos" ] || { echo "No repos given. Set SKILL_REPOS in .env (space-separated HTTPS URLs) or pass them as args."; exit 1; }

# One-time migration: older versions cloned into ~/.claude/skill-repos; ~/ws is the home now.
docker compose exec -T -u node "$SVC" sh -c 'rm -rf "$HOME/.claude/skill-repos" 2>/dev/null || true'

# Per-repo: clone if missing else pull, then (re)link each of its skills into ~/.claude/skills.
# Runs as `node` so git uses the token-backed config the entrypoint set up, and ownership is right.
for url in $repos; do
    echo "=== $url ==="
    docker compose exec -T -u node "$SVC" sh -c '
        set -e
        url="$1"; name="$(basename "$url" .git)"
        base="$HOME/ws"; mkdir -p "$base" "$HOME/.claude/skills"
        if [ -d "$base/$name/.git" ]; then
            echo "  updating $name"; git -C "$base/$name" pull --ff-only || echo "  (pull skipped — local commits?)"
        else
            echo "  cloning $name"; git clone "$url" "$base/$name"
        fi
        n=0
        for sk in "$base/$name"/skills/*/; do
            [ -f "${sk}SKILL.md" ] || continue
            tgt="$HOME/.claude/skills/$(basename "${sk%/}")"
            rm -rf "$tgt"; ln -s "${sk%/}" "$tgt"; n=$((n+1))
        done
        echo "  linked $n skills from $name (live git clone)"
    ' _ "$url"
done

echo
echo "Done. Skills are symlinked to live clones under ~/ws in the sandbox (matches the *-evolve paths)."
echo "Restart 'claude' in the sandbox to load them. /cdd-evolve & /peerreview-evolve can commit + push."
