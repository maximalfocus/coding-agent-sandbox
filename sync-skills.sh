#!/usr/bin/env bash
# Copy your host Claude skills (and matching slash-commands) into the running sandbox's persisted
# config volume, so /cdd, /peer-review, etc. work INSIDE the sandbox. Symlinks are dereferenced and
# the whole source repo of each matched skill is pulled in (so sibling/approach skills come too).
# Re-run after you change a skill on the host. Skills persist in the claude-config volume.
#
#   ./sync-skills.sh                      # default: cdd* and peerreview/peer-review*
#   ./sync-skills.sh cdd peerreview note  # name prefixes to include
#
# Reads from ~/.claude/skills and ~/.claude/commands (override with CLAUDE_SKILLS_DIR /
# CLAUDE_COMMANDS_DIR). bash 3.2-compatible (default macOS bash).
set -euo pipefail
cd "$(dirname "$0")"

SVC=claude-sandbox
HOST_SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
HOST_CMDS="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
PATTERNS=("$@"); [ "${#PATTERNS[@]}" -eq 0 ] && PATTERNS=(cdd peerreview peer-review)

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi
[ -d "$HOST_SKILLS" ] || { echo "No skills dir at $HOST_SKILLS"; exit 1; }

matches() { local n="$1" p; for p in "${PATTERNS[@]}"; do case "$n" in $p*) return 0;; esac; done; return 1; }

# Collect the unique SOURCE repos (parent dirs) of every matched skill, resolving symlinks.
parents="$(
  for entry in "$HOST_SKILLS"/*/; do
    name="$(basename "${entry%/}")"
    matches "$name" || continue
    real="$(cd "$entry" 2>/dev/null && pwd -P)" || continue
    [ -n "$real" ] && dirname "$real"
  done | sort -u
)"
[ -n "$parents" ] || { echo "No skills under $HOST_SKILLS match: ${PATTERNS[*]}"; exit 1; }

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/skills" "$stage/commands"

# Every skill (dir with a SKILL.md) under each matched source repo.
while IFS= read -r parent; do
    [ -n "$parent" ] || continue
    for sk in "$parent"/*/; do
        [ -f "${sk}SKILL.md" ] || continue
        cp -RL "$sk" "$stage/skills/$(basename "${sk%/}")"
    done
done <<EOF
$parents
EOF

# Matching slash-commands (cdd*.md, peer-review.md, ...).
if [ -d "$HOST_CMDS" ]; then
    for f in "$HOST_CMDS"/*.md; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        matches "$name" && cp -L "$f" "$stage/commands/$name"
    done
fi

nskills=$(find "$stage/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
ncmds=$(find "$stage/commands" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
echo "Staged $nskills skills and $ncmds commands. Copying into the sandbox volume..."

docker compose exec -T "$SVC" sh -c 'mkdir -p /home/node/.claude/skills /home/node/.claude/commands'
[ "$nskills" -gt 0 ] && docker compose cp "$stage/skills/." "$SVC:/home/node/.claude/skills/"
[ "$ncmds" -gt 0 ]   && docker compose cp "$stage/commands/." "$SVC:/home/node/.claude/commands/"
docker compose exec -T "$SVC" chown -R node:node /home/node/.claude/skills /home/node/.claude/commands

echo "Done. They persist in the claude-config volume."
echo "Inside the sandbox, restart 'claude' (or reopen the web terminal) to load them — try /cdd or /peer-review."
