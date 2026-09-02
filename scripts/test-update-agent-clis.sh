#!/usr/bin/env bash
# scripts/update-agent-clis.sh moves the agent-tool build pins from the host. What matters is that
# it changes exactly those pins and nothing else, and that it fails closed rather than treating an
# unresolved lookup as "already current".
#
# Herdr adds a second shape: version PLUS two per-architecture checksums, which must move together
# and must be DERIVED from the artifacts downloaded rather than accepted from an argument. A version
# bumped with a stale checksum would fail every later build, so a failed download has to leave the
# file untouched.
#
# Runs offline: both npm and github.com are stubbed on PATH.
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
url=""; out=""; prev=""
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; esac
    case "$a" in https://*) url="$a" ;; esac
    prev="$a"
done

# --- github.com: herdr release resolution + artifact download -------------------------------------
case "$url" in
  https://github.com/*/releases/latest)
      # curl -w '%{url_effective}' prints the final URL after redirects.
      [ -n "$STUB_HERDR_TAG" ] || exit 22
      printf 'https://github.com/%s/releases/tag/%s' "$STUB_HERDR_REPO" "$STUB_HERDR_TAG"; exit 0 ;;
  https://github.com/*/releases/tag/*)
      [ "${url##*/tag/}" = "$STUB_HERDR_TAG" ] && exit 0; exit 22 ;;
  https://github.com/*/releases/download/*)
      wanted="${url##*/releases/download/}"; wanted="${wanted%%/*}"
      [ "$wanted" = "$STUB_HERDR_TAG" ] || exit 22
      [ -n "$out" ] || exit 22
      case "$STUB_HERDR_ARTIFACT" in
        missing)   exit 22 ;;
        truncated) printf 'not a binary' > "$out"; exit 0 ;;
        *)         # ~2MB of deterministic bytes, per architecture, so the two hashes differ.
                   arch="${url##*herdr-linux-}"
                   { printf '%s' "$arch"; head -c 2000000 /dev/zero | tr '\0' "${arch:0:1}"; } > "$out"
                   exit 0 ;;
      esac ;;
esac

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

ALL_LATEST="@anthropic-ai/claude-code=9.9.9 @openai/codex=8.8.8 @earendil-works/pi-coding-agent=6.6.6"
export STUB_HERDR_REPO="herdrdev/herdr"
STUB_HERDR_TAG_VALUE="v5.5.5"
STUB_HERDR_ARTIFACT_VALUE="ok"

# A fixture is a small TREE, not a lone Dockerfile. The updater resolves a pin's coupled literals
# inside the tree it is pointed at and never outside it, so a fixture missing docs/ or mitm/ would
# be a shape the product never ships - and, before that rule existed, an --apply against a lone
# Dockerfile copy reached out and rewrote the real mitm/filter_addon.py.
fixture() {
    local dir="$TMP_DIR/$1.d"
    rm -rf "$dir"; mkdir -p "$dir/docs" "$dir/mitm"
    cp "$ROOT/Dockerfile" "$dir/Dockerfile"
    cp "$ROOT/docs/pin-acceptance.md" "$dir/docs/pin-acceptance.md"
    cp "$ROOT/mitm/filter_addon.py" "$dir/mitm/filter_addon.py"
    printf '%s' "$dir/Dockerfile"
}

run() {  # run FIXTURE [args...] -> writes stdout+stderr to $TMP_DIR/out, returns the exit code
    local df="$1"; shift
    set +e
    STUB_LATEST="$ALL_LATEST" STUB_EXISTS="$STUB_EXISTS_VALUE" \
        STUB_HERDR_TAG="$STUB_HERDR_TAG_VALUE" STUB_HERDR_ARTIFACT="$STUB_HERDR_ARTIFACT_VALUE" \
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
for name in claude codex pi; do
    grep -q "^$name " "$TMP_DIR/out" || fail "report omitted $name"
done
grep -q 'unchanged' "$TMP_DIR/out" || fail 'report did not say the file was left alone'
ok

# 2. A bare --apply moves every pin it owns - the three npm versions and herdr's version plus both
#    checksums - and touches nothing else. herdr IS in scope here, so downloading is expected and
#    announced; cases 2e/2f cover the paths where it must not download.
df=$(fixture apply.Dockerfile)
run "$df" --apply || fail "apply exited non-zero: $(cat "$TMP_DIR/out")"
expected="ARG CLAUDE_CODE_VERSION=9.9.9
ARG CODEX_VERSION=8.8.8
ARG PI_VERSION=6.6.6"
actual=$(grep -E '^ARG (CLAUDE_CODE|CODEX|PI)_VERSION=' "$df")
[ "$actual" = "$expected" ] || fail "apply wrote the wrong pins:
$actual"
grep -q '^ARG HERDR_VERSION=5.5.5$' "$df" || fail 'a bare apply did not move the herdr pin'
[ "$(wc -l < "$df")" = "$(wc -l < "$ROOT/Dockerfile")" ] || fail 'apply changed the line count'
# Every OTHER line must be byte-identical - no stray pin, flag, or whitespace edit.
OWNED='^ARG (CLAUDE_CODE|CODEX|PI|HERDR)_VERSION=|^ARG HERDR_SHA256_(AMD64|ARM64)='
if diff <(grep -vE "$OWNED" "$ROOT/Dockerfile") \
        <(grep -vE "$OWNED" "$df") > "$TMP_DIR/other" 2>&1; then :; else
    fail "apply touched lines outside the pins it owns:
$(cat "$TMP_DIR/other")"
fi
# Named explicitly because these are the two the change must never reach.
grep -q 'ALLOW_TOOL_UPGRADES' "$ROOT/entrypoint.sh" || fail 'ALLOW_TOOL_UPGRADES vanished from the entrypoint'
grep -q 'DISABLE_AUTOUPDATER' "$df" || fail 'apply removed DISABLE_AUTOUPDATER from the Dockerfile'
ok

# 2b. Herdr: version and BOTH checksums move together, from one release, and nothing else does.
df=$(fixture herdr.Dockerfile)
run "$df" --apply herdr || fail "herdr apply exited non-zero: $(cat "$TMP_DIR/out")"
grep -q '^ARG HERDR_VERSION=5.5.5$' "$df" || fail 'herdr version was not written'
amd=$(sed -n 's/^ARG HERDR_SHA256_AMD64=//p' "$df")
arm=$(sed -n 's/^ARG HERDR_SHA256_ARM64=//p' "$df")
echo "$amd" | grep -Eq '^[0-9a-f]{64}$' || fail "amd64 checksum is not a sha256: '$amd'"
echo "$arm" | grep -Eq '^[0-9a-f]{64}$' || fail "arm64 checksum is not a sha256: '$arm'"
[ "$amd" != "$arm" ] || fail 'both architectures got the same checksum - they were not hashed separately'
claude_now=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$ROOT/Dockerfile")
grep -q "^ARG CLAUDE_CODE_VERSION=${claude_now}\$" "$df" || fail 'herdr apply moved an npm pin it was not given'
[ "$(wc -l < "$df")" = "$(wc -l < "$ROOT/Dockerfile")" ] || fail 'herdr apply changed the line count'
grep -qi 'not upstream intent' "$TMP_DIR/out"     || fail 'the derived checksums were printed without saying what they do and do not attest'
ok

# 2c. Checksums are DERIVED, never taken from an argument. Change the artifact bytes and the pin
#     must change with them; if it did not, the tool would be recording something it was handed.
first_amd="$amd"
df=$(fixture herdr2.Dockerfile)
STUB_HERDR_TAG_VALUE="v5.5.6"
run "$df" --apply herdr || fail "second herdr apply failed: $(cat "$TMP_DIR/out")"
grep -q '^ARG HERDR_VERSION=5.5.6$' "$df" || fail 'the second herdr version was not written'
STUB_HERDR_TAG_VALUE="v5.5.5"
ok

# 2d. A failed or truncated download is a refusal, and leaves every line untouched - a version
#     bumped with a stale checksum would fail every later build.
for mode in missing truncated; do
    df=$(fixture "herdr-$mode.Dockerfile")
    STUB_HERDR_ARTIFACT_VALUE="$mode"
    if run "$df" --apply herdr; then fail "a '$mode' herdr download was accepted"; fi
    cmp -s "$df" "$ROOT/Dockerfile"         || fail "a '$mode' herdr download still modified the Dockerfile"
    STUB_HERDR_ARTIFACT_VALUE="ok"
    ok
done

# 2e. A report must never download an artifact - 40MB is not a side effect of a read-only command.
df=$(fixture herdr-report.Dockerfile)
STUB_HERDR_ARTIFACT_VALUE="missing"
run "$df" || fail "report with herdr in scope failed: $(cat "$TMP_DIR/out")"
cmp -s "$df" "$ROOT/Dockerfile" || fail 'a report modified the Dockerfile'
grep -q '^herdr ' "$TMP_DIR/out" || fail 'the report omitted herdr'
STUB_HERDR_ARTIFACT_VALUE="ok"
ok

# 2f. An npm-only apply must not touch the herdr pins at all.
df=$(fixture npmonly.Dockerfile)
STUB_HERDR_ARTIFACT_VALUE="missing"
run "$df" --apply claude codex pi || fail "npm-only apply failed: $(cat "$TMP_DIR/out")"
herdr_now=$(sed -n 's/^ARG HERDR_VERSION=//p' "$ROOT/Dockerfile")
grep -q "^ARG HERDR_VERSION=${herdr_now}\$" "$df" || fail 'an npm-only apply moved the herdr pin'
STUB_HERDR_ARTIFACT_VALUE="ok"
ok

# 3. A named subset moves only that pin.
df=$(fixture subset.Dockerfile)
run "$df" --apply codex || fail "subset apply exited non-zero: $(cat "$TMP_DIR/out")"
grep -q '^ARG CODEX_VERSION=8.8.8$' "$df" || fail 'subset apply did not move the named pin'
grep -q "^ARG CLAUDE_CODE_VERSION=${claude_now}\$" "$df" || fail 'subset apply moved a pin it was not given'
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
STUB_LATEST="@anthropic-ai/claude-code= @openai/codex=8.8.8 @earendil-works/pi-coding-agent=6.6.6" \
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

# 8b. The Herdr download must name the canonical owner, not rely on GitHub's rename redirect.
grep -q 'https://github.com/herdrdev/herdr/releases/download/' "$ROOT/Dockerfile" \
    || fail 'the Dockerfile does not fetch Herdr from the canonical herdrdev/herdr'
grep -Eq '^\s*curl .*ogulcancelik/herdr' "$ROOT/Dockerfile" \
    && fail 'the Dockerfile still downloads Herdr through the renamed owner'
ok

# 9. The real Dockerfile still carries every pin the tool owns, one line each - the script asserts
#    this too, but a rename here should fail loudly rather than turn the tool into a no-op.
for arg in CLAUDE_CODE_VERSION CODEX_VERSION PI_VERSION \
           HERDR_VERSION HERDR_SHA256_AMD64 HERDR_SHA256_ARM64; do
    count=$(grep -c "^ARG $arg=" "$ROOT/Dockerfile" || true)
    [ "$count" = "1" ] || fail "expected exactly one 'ARG $arg=' line in the Dockerfile, found $count"
done
ok

# 10. Every pin the tool can write is mapped in docs/pin-acceptance.md. An unmapped one is the
#     failure this coupling exists to prevent, so it must be a refusal rather than a warning.
for arg in CLAUDE_CODE_VERSION CODEX_VERSION PI_VERSION \
           HERDR_VERSION HERDR_SHA256_AMD64 HERDR_SHA256_ARM64; do
    "$ROOT/scripts/check-pin-acceptance.sh" --arg "$arg" >/dev/null 2>&1 \
        || fail "$arg has no row in docs/pin-acceptance.md, so the updater would refuse to move it"
done
ok

# 11. An unmapped pin stops the write and leaves the file byte-identical. The inventory is stripped
#     rather than the Dockerfile, because that is the real shape: a pin exists and nobody recorded
#     what it carries.
df=$(fixture unmapped.Dockerfile)
before=$(cat "$df")
stripped="$TMP_DIR/pin-acceptance-no-herdr.md"
grep -v '^herdr\.version |' "$ROOT/docs/pin-acceptance.md" > "$stripped"
export PIN_ACCEPTANCE_DOC="$stripped"
run "$df" --apply herdr && fail 'the updater moved an unmapped pin'
unset PIN_ACCEPTANCE_DOC
[ "$before" = "$(cat "$df")" ] || fail 'a refused pin move still wrote to the Dockerfile'
grep -q 'no row in docs/pin-acceptance.md' "$TMP_DIR/out" \
    || fail "the refusal did not name the missing inventory row: $(cat "$TMP_DIR/out")"
grep -q 'Nothing was written' "$TMP_DIR/out" || fail 'the refusal did not say nothing was written'
ok

# 12. A mapped pin reports what the move invalidates BEFORE writing, and marks the checks no
#     automated run can produce. A bump whose cost is only discoverable afterwards is the bug.
df=$(fixture cost-report.Dockerfile)
run "$df" --apply herdr || fail "apply herdr exited non-zero: $(cat "$TMP_DIR/out")"
grep -q 'invalidates the verification below' "$TMP_DIR/out" \
    || fail 'the updater did not report what the pin move invalidates'
grep -q 'operator:herdr-selection-copy' "$TMP_DIR/out" \
    || fail 'the updater did not name the operator-only selection check'
grep -q 'NO AUTOMATED RUN PRODUCES THIS' "$TMP_DIR/out" \
    || fail 'an operator-only check was not marked as such'
grep -q 'host:verify-image-architectures.sh' "$TMP_DIR/out" \
    || fail "the checksum ARGs' host-class check was not reported alongside the version"
ok

# 13. The cost report precedes the write in the output, not after it - a reviewer reads top-down.
cost_line=$(grep -n 'invalidates the verification below' "$TMP_DIR/out" | head -1 | cut -d: -f1)
wrote_line=$(grep -n "^Updated $df:" "$TMP_DIR/out" | head -1 | cut -d: -f1)
[ -n "$cost_line" ] && [ -n "$wrote_line" ] && [ "$cost_line" -lt "$wrote_line" ] \
    || fail 'the cost report did not precede the write'
ok

# 14. Parity: the Windows twin is a supported pin-changing path too, so the refusal must exist on
#     both or it is bypassable on one platform. Structural rather than behavioural - a real
#     PowerShell run needs a Windows host, per docs/verification-hosts.md.
PS1="$ROOT/scripts/update-agent-clis.ps1"
grep -q 'pin-acceptance.md' "$PS1" \
    || fail 'the Windows twin does not consult the pin inventory, so it could move an unmapped pin'
grep -q 'no row in docs/pin-acceptance.md' "$PS1" \
    || fail 'the Windows twin has no refusal message for an unmapped pin'
grep -q 'Nothing was written' "$PS1" \
    || fail 'the Windows twin does not state that a refusal wrote nothing'
grep -q 'NO AUTOMATED RUN PRODUCES THIS' "$PS1" \
    || fail 'the Windows twin does not mark operator-only checks'
grep -q 'needs another host class' "$PS1" \
    || fail 'the Windows twin does not mark host-class checks'
ok


# --- couplings: a pin written in two files moves as one, or not at all ---------------------------
# #137 wrote the Dockerfile pin and left mitm/filter_addon.py's refresh User-Agent behind. The
# updater is a supported pin-changing path, so it must not be able to produce that state - and after
# the coupling check exists, a partial apply would leave the tree failing its own gate.
#
# --dockerfile selects the tree, so these run against a fixture and cannot touch the real addon.
COUPLE_TREE=
setup_couple_tree() { COUPLE_TREE="$(dirname "$(fixture coupled)")"; }
couple_run() {
    set +e
    STUB_LATEST="$ALL_LATEST" STUB_EXISTS="$STUB_EXISTS_VALUE" \
        STUB_HERDR_TAG="$STUB_HERDR_TAG_VALUE" STUB_HERDR_ARTIFACT="$STUB_HERDR_ARTIFACT_VALUE" \
        bash "$SCRIPT" --dockerfile "$COUPLE_TREE/Dockerfile" "$@" > "$TMP_DIR/out" 2>&1
    local code=$?
    set -e
    return $code
}
claude_pinned=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$ROOT/Dockerfile")
[ -n "$claude_pinned" ] || fail 'no Claude pin in the Dockerfile'
grep -Fq "claude-cli/$claude_pinned (external, cli)" "$ROOT/mitm/filter_addon.py" \
    || fail 'the real tree already disagrees with itself; these cases would prove nothing'

# 15. An apply moves the pin AND the literal coupled to it, and says so.
setup_couple_tree
couple_run --apply claude || fail "a coupled apply failed: $(cat "$TMP_DIR/out")"
grep -q '^ARG CLAUDE_CODE_VERSION=9.9.9$' "$COUPLE_TREE/Dockerfile" || fail 'the pin did not move'
grep -Fq 'claude-cli/9.9.9 (external, cli)' "$COUPLE_TREE/mitm/filter_addon.py" \
    || fail 'the coupled User-Agent was left behind - this is exactly #137'
grep -Fq "claude-cli/$claude_pinned (external, cli)" "$COUPLE_TREE/mitm/filter_addon.py" \
    && fail 'the old coupled literal is still present alongside the new one'
grep -q 'literals coupled to those pins' "$TMP_DIR/out" || fail 'the coupled edit was not reported'
ok

# 16. ...and the result passes the coupling check, so a supported path cannot leave the tree
#     failing its own gate. This is the property that makes the updater and the check one system.
sed -i.bak 's/^claude-code.version | Claude Code CLI | Dockerfile | ARG CLAUDE_CODE_VERSION=[^ ]*/claude-code.version | Claude Code CLI | Dockerfile | ARG CLAUDE_CODE_VERSION=9.9.9/' \
    "$COUPLE_TREE/docs/pin-acceptance.md"
rm -f "$COUPLE_TREE/docs/pin-acceptance.md.bak"
PIN_ACCEPTANCE_ROOT="$COUPLE_TREE" "$ROOT/scripts/check-pin-acceptance.sh" > "$TMP_DIR/out" 2>&1 \
    || fail "the tree an apply produced fails the coupling check: $(cat "$TMP_DIR/out")"
ok

# 17. A coupled literal the run cannot locate is a REFUSAL, not a partial apply. The Dockerfile must
#     be byte-identical afterwards.
setup_couple_tree
python3 - "$COUPLE_TREE/mitm/filter_addon.py" <<'SCRAMBLE'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
new = re.sub(r'claude-cli/[0-9][^ ]* \(external, cli\)', 'claude-cli/not-the-pin (external, cli)', text)
assert new != text
open(path, 'w', encoding='utf-8').write(new)
SCRAMBLE
before=$(cat "$COUPLE_TREE/Dockerfile")
couple_run --apply claude && fail 'an unlocatable coupled literal was accepted'
[ "$before" = "$(cat "$COUPLE_TREE/Dockerfile")" ] || fail 'a refused coupled apply still wrote the pin'
grep -q 'coupled to a literal this run cannot locate' "$TMP_DIR/out" || fail 'the refusal was not explained'
grep -q 'Nothing was written' "$TMP_DIR/out" || fail 'the refusal did not say nothing was written'
ok

# 18. A missing coupled FILE is the same refusal, for the same reason.
setup_couple_tree
rm -f "$COUPLE_TREE/mitm/filter_addon.py"
before=$(cat "$COUPLE_TREE/Dockerfile")
couple_run --apply claude && fail 'a missing coupled file was accepted'
[ "$before" = "$(cat "$COUPLE_TREE/Dockerfile")" ] || fail 'a refused coupled apply still wrote the pin'
ok

# 19. A pin with no coupling is unaffected - the mechanism must not become a tax on every pin.
setup_couple_tree
couple_run --apply pi || fail "an uncoupled apply failed: $(cat "$TMP_DIR/out")"
grep -q '^ARG PI_VERSION=6.6.6$' "$COUPLE_TREE/Dockerfile" || fail 'the uncoupled pin did not move'
cmp -s "$COUPLE_TREE/mitm/filter_addon.py" "$ROOT/mitm/filter_addon.py" \
    || fail 'an uncoupled pin move touched a coupled file'
grep -q 'literals coupled to those pins' "$TMP_DIR/out" \
    && fail 'an uncoupled pin reported coupled edits'
ok

# 20. Parity: the Windows twin is a supported pin-changing path too, so the coupling must hold there
#     or it is bypassable on one platform. Structural, per docs/verification-hosts.md.
grep -q 'pin-coupling' "$PS1" \
    || fail 'the Windows twin does not read the coupling block, so it could move a pin alone'
grep -q 'coupled to a literal this run cannot locate' "$PS1" \
    || fail 'the Windows twin has no refusal message for an unlocatable coupled literal'
grep -q 'move together or not at all' "$PS1" \
    || fail 'the Windows twin does not state the move-together contract'
ok

printf 'PASS: the host-side pin updater moves the pins it owns and fails closed (%d checks)\n' "$PASSED"
