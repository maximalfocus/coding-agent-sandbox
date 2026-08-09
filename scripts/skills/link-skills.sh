#!/bin/sh
# sandbox-link-skills — the ONE source of truth for symlinking skill repos into Claude's skills dir.
#
# Baked into the image as /usr/local/bin/sandbox-link-skills and called from THREE places, so the
# linking behaviour can never drift:
#   - entrypoint.sh, on every container start (auto-load — no manual step, survives volume resets),
#   - scripts/skills/skills-setup.sh   (host helper: clone/pull, then delegate linking here),
#   - scripts/skills/skills-setup.ps1  (Windows counterpart, same delegation).
#
# Design (peer-reviewed to convergence):
#   * Managed set is EXPLICIT — the repos named in SKILL_REPOS (or passed as args), never a blind
#     sweep of /workspace/personal. A repo not in the managed set is never touched.
#   * Non-destructive — we only ever remove a symlink we created ourselves, tracked in a manifest
#     ($SKILLS_DIR/.managed-by-sandbox). A real directory or a copied skill (e.g. from
#     sync-skills.sh) sitting at a target path is LEFT ALONE and reported, never rm -rf'd.
#   * Deterministic — repos and skills are processed in sorted order; on a name collision the first
#     wins and the rest are warned, so the result doesn't depend on filesystem iteration order.
#   * Self-healing — manifest entries that are no longer managed are pruned (only manifest-listed
#     symlinks are ever removed).
#   * Non-fatal — always exits 0. The entrypoint runs under `set -euo pipefail`; this script must
#     never be the reason a container fails to boot.
#
# POSIX sh on purpose (no bashisms): the same file runs under the container's bash, under dash if
# invoked via `sh`, and under macOS's bash 3.2 for host-side testing — no arrays / mapfile needed.
#
# Usage:
#   sandbox-link-skills [REPO ...]
#     REPO may be a git URL (https://…/foo-skills.git) or a bare name (foo-skills); only the
#     basename (sans .git) matters — repos are resolved under $BASE/<name>.
#   With no args, the managed set comes from $SKILL_REPOS, then (if empty) the existing manifest.
#
# Env: SKILL_REPOS (space-separated managed set), BASE (default /workspace/personal),
#      CLAUDE_CONFIG_DIR (default $HOME/.claude; skills go in $CLAUDE_CONFIG_DIR/skills).
# Outputs: $SKILLS_DIR/.managed-by-sandbox (links we own), $SKILLS_DIR/.sandbox-skills-status (metrics).

BASE="${BASE:-/workspace/personal}"
SKILLS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
MANIFEST="$SKILLS_DIR/.managed-by-sandbox"
STATUS="$SKILLS_DIR/.sandbox-skills-status"

mkdir -p "$SKILLS_DIR" 2>/dev/null || true

# Scratch space for intermediate lists (portable membership without associative arrays).
WORK="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sls.$$")"
mkdir -p "$WORK" 2>/dev/null || true
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
CLAIMED="$WORK/claimed"   # lines: "<skill> <repo>"  (first-wins winners)
NEWMAN="$WORK/newman"     # basenames of links created this pass
COLL="$WORK/coll"         # one line per collision (counted after the loop)
SKIPC="$WORK/skipc"       # one line per preserved non-symlink conflict
: > "$CLAIMED"; : > "$NEWMAN"; : > "$COLL"; : > "$SKIPC"

# --- resolve the managed repo set (args > SKILL_REPOS > prior manifest's source list) -------------
raw=""
if [ "$#" -gt 0 ]; then
    raw="$*"
elif [ -n "${SKILL_REPOS:-}" ]; then
    raw="$SKILL_REPOS"
fi
# Normalise to bare repo names (basename, strip a trailing .git), one per line.
: > "$WORK/names"
for r in $raw; do
    [ -n "$r" ] || continue
    n="${r##*/}"; n="${n%.git}"
    [ -n "$n" ] && echo "$n" >> "$WORK/names"
done

# If still empty, fall back to the repos a PRIOR run linked from: re-derive each managed symlink's
# source repo from its target ($BASE/<repo>/...). Keeps boot-time auto-linking working when
# SKILL_REPOS isn't passed into the container, without ever sweeping untrusted content.
if [ ! -s "$WORK/names" ] && [ -f "$MANIFEST" ]; then
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        tgt="$(readlink "$SKILLS_DIR/$link" 2>/dev/null)" || continue
        case "$tgt" in
            "$BASE"/*) rest="${tgt#"$BASE"/}"; echo "${rest%%/*}" >> "$WORK/names" ;;
        esac
    done < "$MANIFEST"
fi

# Dedupe + sort for deterministic processing.
sort -u "$WORK/names" 2>/dev/null > "$WORK/names.sorted" || : > "$WORK/names.sorted"
# `grep -c` already prints 0 for an empty file (with exit 1) — so capture, then default if blank;
# never chain `|| echo 0`, which would emit a second 0 line.
managed_repos="$(grep -c . "$WORK/names.sorted" 2>/dev/null)"; managed_repos="${managed_repos:-0}"

# --- discover skills in a managed repo -------------------------------------------------------------
# Echoes `<skill-name>\t<abs-skill-dir>` for each skill: every <repo>/skills/<skill>/SKILL.md, plus
# a root-level <repo>/SKILL.md (a single-skill repo, e.g. present-skills). Sorted for determinism.
discover_skills() {
    repo_dir="$1"
    if [ -f "$repo_dir/SKILL.md" ]; then
        printf '%s\t%s\n' "$(basename "$repo_dir")" "$repo_dir"
    fi
    for sk in "$repo_dir"/skills/*/; do
        [ -f "${sk}SKILL.md" ] || continue
        sk="${sk%/}"
        printf '%s\t%s\n' "$(basename "$sk")" "$sk"
    done
}

# --- link the managed set --------------------------------------------------------------------------
repos_missing=0

while IFS= read -r name; do
    [ -n "$name" ] || continue
    repo_dir="$BASE/$name"
    if [ ! -d "$repo_dir" ]; then
        repos_missing=$((repos_missing+1))
        echo "  skill repo not on disk: $name (expected $repo_dir)" >&2
        continue
    fi
    discover_skills "$repo_dir" | sort | while IFS="$(printf '\t')" read -r skill dir; do
        [ -n "$skill" ] || continue
        # Cross-repo name collision: first (sorted) repo wins; warn on the rest.
        if winner="$(awk -v s="$skill" '$1==s{print $2; exit}' "$CLAIMED")" && [ -n "$winner" ]; then
            echo "x" >> "$COLL"
            echo "  collision: skill '$skill' from '$name' ignored (already provided by '$winner')" >&2
            continue
        fi
        tgt="$SKILLS_DIR/$skill"
        if [ -e "$tgt" ] && [ ! -L "$tgt" ]; then
            # A real dir / copied skill (e.g. sync-skills.sh) — never destroy it.
            echo "x" >> "$SKIPC"
            echo "  skip '$skill': a non-symlink already exists at $tgt (left untouched)" >&2
            continue
        fi
        # ln -sfn: atomically replace an existing symlink; -n avoids descending into a symlinked dir.
        ln -sfn "$dir" "$tgt" 2>/dev/null || { echo "  failed to link $skill" >&2; continue; }
        echo "$skill $name" >> "$CLAIMED"
        echo "$skill" >> "$NEWMAN"
        linked=$((linked+1))
    done
    # NB: the `while` above runs in a subshell (pipe), so counters set inside it don't propagate.
    # We recompute the real totals from $NEWMAN/$CLAIMED after the loop instead of trusting them.
done < "$WORK/names.sorted"

# Authoritative counts (the piped while-subshells above can't mutate parent vars in POSIX sh, so
# every per-event signal was appended to a file; count the files here).
linked="$(grep -c . "$NEWMAN" 2>/dev/null)"; linked="${linked:-0}"
collisions="$(grep -c . "$COLL" 2>/dev/null)"; collisions="${collisions:-0}"
skipped_conflict="$(grep -c . "$SKIPC" 2>/dev/null)"; skipped_conflict="${skipped_conflict:-0}"

# --- prune stale managed links (only ones WE recorded; never touch unmanaged entries) -------------
stale_removed=0
if [ -f "$MANIFEST" ]; then
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        # Still managed this pass? keep.
        if grep -qxF "$old" "$NEWMAN" 2>/dev/null; then continue; fi
        tgt="$SKILLS_DIR/$old"
        # Only remove if still a symlink (ours). A user who replaced it with real content is respected.
        if [ -L "$tgt" ]; then
            rm -f "$tgt" 2>/dev/null && stale_removed=$((stale_removed+1))
        fi
    done < "$MANIFEST"
fi

# --- persist manifest + status ---------------------------------------------------------------------
sort -u "$NEWMAN" 2>/dev/null > "$MANIFEST" || : > "$MANIFEST"

{
    echo "linked=$linked"
    echo "collisions=$collisions"
    echo "skipped_conflict=$skipped_conflict"
    echo "repos_missing=$repos_missing"
    echo "stale_removed=$stale_removed"
    echo "managed_repos=$managed_repos"
} > "$STATUS" 2>/dev/null || true

echo "linked $linked skill(s) from $managed_repos managed repo(s)."
exit 0
