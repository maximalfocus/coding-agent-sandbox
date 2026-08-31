#!/usr/bin/env bash
# The first-run checklist (~/.sandbox-todo) must carry ONLY setup the operator has to finish on the
# host — today the GitHub credential. An optional capability the operator never asked for is not
# unfinished setup, and an item they cannot act on is what teaches them to skim the one that matters.
#
# This extracts the real block from entrypoint.sh between its `sandbox-todo` markers and runs it, so
# the shipped code is what is under test rather than a copy of it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENTRYPOINT="$ROOT/entrypoint.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

[ -f "$ENTRYPOINT" ] || fail 'entrypoint.sh is missing'

BLOCK="$TMP_DIR/todo-block.sh"
awk '/^# >>> sandbox-todo >>>$/{f=1;next} /^# <<< sandbox-todo <<<$/{f=0} f' "$ENTRYPOINT" > "$BLOCK"
[ -s "$BLOCK" ] || fail 'the sandbox-todo markers are missing from entrypoint.sh — nothing to test'

# render CREDS SKILL_REPOS LINKED -> the checklist file's contents ('' when no file was written)
render() {
    local home="$TMP_DIR/home"; rm -rf "$home"; mkdir -p "$home"
    # A checklist left over from a previous boot must be removed when nothing is outstanding.
    printf 'stale\n' > "$home/.sandbox-todo"
    env -i HOME="$home" PATH="$PATH" \
        GIT_CREDS_OK="$1" SKILL_REPOS="$2" \
        bash -c "set -euo pipefail; . '$BLOCK'" >/dev/null 2>&1
    [ -f "$home/.sandbox-todo" ] && cat "$home/.sandbox-todo" || true
}

# 1. No credential, no skills configured: the credential item, and only it.
out=$(render "" "")
printf '%s' "$out" | grep -q 'GitHub credentials not set' \
    || fail 'the credential item is missing when no credential is set'
ok

# 2. A skills state must never add an item — in any of the states that used to produce one.
for repos in "" "https://github.com/example/some-skills.git" \
             "https://github.com/example/a.git https://github.com/example/b.git"; do
    out=$(render "" "$repos")
    if printf '%s' "$out" | grep -qi 'skill'; then
        fail "a skills item appeared in the checklist (SKILL_REPOS='$repos')"
    fi
    # Exactly one outstanding item, whatever the skills state.
    count=$(printf '%s' "$out" | grep -c '^  \[ \]' || true)
    [ "$count" = "1" ] || fail "expected exactly 1 checklist item, got $count (SKILL_REPOS='$repos')"
    ok
done

# 3. The credential item must not justify itself in terms of skills.
out=$(render "" "")
if printf '%s' "$out" | grep -qi 'evolve\|skill'; then
    fail 'the credential item still explains itself in terms of skills'
fi
ok

# 4. With a usable credential there is no checklist at all, whatever the skills state.
for repos in "" "https://github.com/example/some-skills.git"; do
    out=$(render "1" "$repos")
    [ -z "$out" ] || fail "a checklist survived a usable credential (SKILL_REPOS='$repos'): $out"
    ok
done

# 5. The skills machinery itself must remain, and remain non-fatal.
grep -q 'sandbox-link-skills' "$ENTRYPOINT" \
    || fail 'boot-time skill linking was removed — it must keep working, it just stops reporting'
grep -q 'non-fatal' "$ENTRYPOINT" \
    || fail 'skill linking must still be explicitly non-fatal to startup'
grep -q 'git clone "$_url"' "$ENTRYPOINT" \
    || fail 'boot-time skill cloning was removed'
ok

# 6. The hint script that prints the file is unchanged in contract: it prints only when non-empty.
grep -q '\.sandbox-todo' "$ROOT/scripts/skills/sandbox-todo-hint.sh" \
    || fail 'the shell hint no longer reads ~/.sandbox-todo'
ok

printf 'PASS: the first-run checklist carries only host-side credential setup (%d checks)\n' "$pass"
