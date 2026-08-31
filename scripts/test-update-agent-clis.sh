#!/usr/bin/env bash
# scripts/update-agent-clis.sh moves the four agent-CLI build pins from the host. What matters is
# that it changes exactly those pins and nothing else, and that it fails closed rather than treating
# an unresolved lookup as "already current". Runs offline: the registry is stubbed on PATH.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/update-agent-clis.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); }

[ -x "$SCRIPT" ] || fail 'scripts/update-agent-clis.sh is missing or not executable'
[ -f "$ROOT/scripts/update-agent-clis.ps1" ] \
    || fail 'the Windows twin is missing - the repository keeps host helpers at parity'

# macOS ships bash 3.2. An associative array parses on 4+ and dies on the shell most users have.
if grep -Eq 'declare -A|local -A' "$SCRIPT"; then
    fail 'the script uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

# --- stub registry --------------------------------------------------------------------------------
# LATEST: "pkg=version" pairs the stub serves for /latest. EXISTS: exact "pkg/version" paths it
# accepts. Anything else is a 404, and an empty LATEST entry simulates an unreachable registry.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
path="${url#https://registry.npmjs.org/}"
if [ "${path##*/}" = "latest" ]; then
    pkg="${path%/latest}"; pkg="$(printf '%s' "$pkg" | sed 's|%2f|/|g')"
    for pair in $STUB_LATEST; do
        if [ "${pair%%=*}" = "$pkg" ]; then
            v="${pair#*=}"
            [ -n "$v" ] || exit 22
            printf '{"name":"%s","version":"%s"}\n' "$pkg" "$v"; exit 0
        fi
    done
    exit 22
fi
for known in $STUB_EXISTS; do [ "$(printf '%s' "$path" | sed 's|%2f|/|g')" = "$known" ] && exit 0; done
exit 22
STUB
chmod +x "$TMP_DIR/bin/curl"
export PATH="$TMP_DIR/bin:$PATH"

ALL_LATEST="@anthropic-ai/claude-code=9.9.9 @openai/codex=8.8.8 opencode-ai=7.7.7 @earendil-works/pi-coding-agent=6.6.6"

fixture() {
    local target="$TMP_DIR/$1"
    cp "$ROOT/Dockerfile" "$target"
    printf '%s' "$target"
}

run() {  # run FIXTURE [args...] -> writes stdout+stderr to $TMP_DIR/out, returns the exit code
    local df="$1"; shift
    set +e
    STUB_LATEST="$ALL_LATEST" STUB_EXISTS="$STUB_EXISTS_VALUE" \
        bash "$SCRIPT" --dockerfile "$df" "$@" > "$TMP_DIR/out" 2>&1
    local code=$?
    set -e
    return $code
}
STUB_EXISTS_VALUE=""

# 1. Report changes nothing and names every CLI.
df=$(fixture report.Dockerfile)
run "$df" || fail "report exited non-zero: $(cat "$TMP_DIR/out")"
cmp -s "$df" "$ROOT/Dockerfile" || fail 'a report modified the Dockerfile'
for name in claude codex opencode pi; do
    grep -q "^$name " "$TMP_DIR/out" || fail "report omitted $name"
done
grep -q 'unchanged' "$TMP_DIR/out" || fail 'report did not say the file was left alone'
ok

# 2. --apply moves exactly the four pins, and touches nothing else.
df=$(fixture apply.Dockerfile)
run "$df" --apply || fail "apply exited non-zero: $(cat "$TMP_DIR/out")"
expected="ARG CLAUDE_CODE_VERSION=9.9.9
ARG CODEX_VERSION=8.8.8
ARG OPENCODE_VERSION=7.7.7
ARG PI_VERSION=6.6.6"
actual=$(grep -E '^ARG (CLAUDE_CODE|CODEX|OPENCODE|PI)_VERSION=' "$df")
[ "$actual" = "$expected" ] || fail "apply wrote the wrong pins:
$actual"
[ "$(wc -l < "$df")" = "$(wc -l < "$ROOT/Dockerfile")" ] || fail 'apply changed the line count'
# Every OTHER line must be byte-identical - no stray pin, flag, or whitespace edit.
if diff <(grep -vE '^ARG (CLAUDE_CODE|CODEX|OPENCODE|PI)_VERSION=' "$ROOT/Dockerfile") \
        <(grep -vE '^ARG (CLAUDE_CODE|CODEX|OPENCODE|PI)_VERSION=' "$df") > "$TMP_DIR/other" 2>&1; then :; else
    fail "apply touched lines outside the four agent pins:
$(cat "$TMP_DIR/other")"
fi
# Named explicitly because these are the two the change must never reach.
grep -q 'ALLOW_TOOL_UPGRADES' "$ROOT/entrypoint.sh" || fail 'ALLOW_TOOL_UPGRADES vanished from the entrypoint'
grep -q 'DISABLE_AUTOUPDATER' "$df" || fail 'apply removed DISABLE_AUTOUPDATER from the Dockerfile'
ok

# 3. A named subset moves only that pin.
df=$(fixture subset.Dockerfile)
run "$df" --apply codex || fail "subset apply exited non-zero: $(cat "$TMP_DIR/out")"
grep -q '^ARG CODEX_VERSION=8.8.8$' "$df" || fail 'subset apply did not move the named pin'
grep -q '^ARG CLAUDE_CODE_VERSION=2' "$df" || fail 'subset apply moved a pin it was not given'
ok

# 4. An explicit version the registry does not serve is refused, and nothing is written.
df=$(fixture badpin.Dockerfile)
STUB_EXISTS_VALUE=""
if run "$df" --apply claude=99.99.99; then fail 'a nonexistent explicit version was accepted'; fi
cmp -s "$df" "$ROOT/Dockerfile" || fail 'a refused explicit version still modified the Dockerfile'
grep -q 'NOT IN REGISTRY' "$TMP_DIR/out" || fail 'the refusal did not say the version is unknown'
grep -q 'nothing was written' "$TMP_DIR/out" || fail 'the refusal did not say nothing was written'
ok

# 5. An explicit version the registry DOES serve is accepted.
df=$(fixture goodpin.Dockerfile)
STUB_EXISTS_VALUE="@anthropic-ai/claude-code/2.0.0"
run "$df" --apply claude=2.0.0 || fail "a valid explicit pin was refused: $(cat "$TMP_DIR/out")"
grep -q '^ARG CLAUDE_CODE_VERSION=2.0.0$' "$df" || fail 'the explicit pin was not written'
STUB_EXISTS_VALUE=""
ok

# 6. A registry that cannot be reached is a refusal, NOT "already up to date".
df=$(fixture offline.Dockerfile)
set +e
STUB_LATEST="@anthropic-ai/claude-code= @openai/codex=8.8.8 opencode-ai=7.7.7 @earendil-works/pi-coding-agent=6.6.6" \
    bash "$SCRIPT" --dockerfile "$df" --apply > "$TMP_DIR/out" 2>&1
code=$?
set -e
[ "$code" != "0" ] || fail 'an unreachable registry was treated as success'
cmp -s "$df" "$ROOT/Dockerfile" || fail 'a failed lookup still modified the Dockerfile'
grep -q 'LOOKUP FAILED' "$TMP_DIR/out" || fail 'the failed lookup was not reported'
grep -q 'nothing was written' "$TMP_DIR/out" || fail 'a partial apply was not prevented'
ok

# 7. An unknown CLI name is refused before anything is read.
df=$(fixture unknown.Dockerfile)
if run "$df" --apply notacli; then fail 'an unknown CLI name was accepted'; fi
cmp -s "$df" "$ROOT/Dockerfile" || fail 'an unknown CLI name still modified the Dockerfile'
ok

# 8. Re-running after an apply reports "up to date" and writes nothing further.
df=$(fixture idempotent.Dockerfile)
run "$df" --apply || fail 'first apply failed'
before=$(cat "$df")
run "$df" --apply || fail 'second apply failed'
[ "$before" = "$(cat "$df")" ] || fail 'a second apply changed the file again'
grep -q 'up to date' "$TMP_DIR/out" || fail 'a current pin was not reported as up to date'
ok

# 9. The real Dockerfile still carries all four pins, one line each - the script asserts this too,
#    but a rename here should fail loudly rather than turn the tool into a no-op.
for arg in CLAUDE_CODE_VERSION CODEX_VERSION OPENCODE_VERSION PI_VERSION; do
    count=$(grep -c "^ARG $arg=" "$ROOT/Dockerfile" || true)
    [ "$count" = "1" ] || fail "expected exactly one 'ARG $arg=' line in the Dockerfile, found $count"
done
ok

printf 'PASS: the host-side pin updater moves the four agent pins and fails closed (%d checks)\n' "$PASSED"
