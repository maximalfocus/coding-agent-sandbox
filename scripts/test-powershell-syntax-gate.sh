#!/usr/bin/env bash
# Deterministic coverage for issue #76's PowerShell syntax gate.
# Drives scripts/powershell-syntax-gate.ps1 against fixture trees in the same pinned container the
# gate itself uses. Nothing here executes a script under test; every fixture is only parsed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GATE="$ROOT/scripts/powershell-syntax-gate.ps1"
WRAPPER="$ROOT/scripts/test-powershell-syntax.sh"
PWSH_IMAGE=${PWSH_IMAGE:-coding-agent-sandbox-pwsh:7.6.5}

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }
skip_all() { printf 'SKIP: %s\n' "$*"; exit 0; }

[ -f "$GATE" ] || fail "the gate script is missing"
[ -x "$WRAPPER" ] || fail "the gate wrapper is missing or not executable"
ok "gate and wrapper are present"

# The gate must parse, never execute. A fixture that ran would be a way to execute repository content
# inside the verification path.
if grep -nE '^[^#]*(Invoke-Expression|iex\b|&\s*\$file|\.\s+\$file|Start-Process)' "$GATE" >/dev/null 2>&1; then
    fail "the gate contains a construct that could execute a file under test"
fi
grep -q 'Parser\]::ParseFile' "$GATE" || fail "the gate no longer parses via the PowerShell parser"
ok "gate parses files and executes none of them"

# Token-based detection is the whole reason the check is usable here; a textual scan produces false
# positives on this repository's own files.
grep -q 'Kind.ToString()' "$GATE" || fail "the gate no longer inspects the parser's token stream"
ok "gate detects incompatible syntax from the token stream"

command -v docker >/dev/null 2>&1 || skip_all "docker unavailable; gate behaviour not exercised"
docker info >/dev/null 2>&1 || skip_all "Docker daemon unreachable; gate behaviour not exercised"


# Built on first use by the wrapper; build it here too so this suite is self-sufficient.
if ! docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1; then
    docker build -f "$ROOT/Dockerfile.pwsh" -t "$PWSH_IMAGE" "$ROOT" >/dev/null 2>&1 \
        || skip_all "could not build the pinned PowerShell image; gate behaviour not exercised"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

run_gate() { # fixture-root -> sets STATUS and OUT
    set +e
    OUT=$(docker run --rm --network none -v "$1:/repo:ro" --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" \
        -NoProfile -NonInteractive -File /repo/scripts/powershell-syntax-gate.ps1 -Root /repo 2>&1)
    STATUS=$?
    set -e
}

new_fixture() { # name -> echoes its path, with the gate installed
    local dir="$TMP_DIR/$1"
    mkdir -p "$dir/scripts"
    cp "$GATE" "$dir/scripts/"
    printf '%s' "$dir"
}

# --- a clean fixture passes --------------------------------------------------
clean=$(new_fixture clean)
cat >"$clean/ok.ps1" <<'PS1'
param([string] $Name = 'world')
if ($Name) { Write-Output "hello $Name" } else { Write-Output 'hello' }
PS1
run_gate "$clean"
[ $STATUS -eq 0 ] || fail "a clean fixture should exit 0 (got $STATUS): $OUT"
grep -q 'GATE-SUMMARY files=2 failed=0' <<<"$OUT" || fail "clean fixture summary is wrong: $OUT"
ok "a clean fixture passes and counts every file it parsed"

# --- a real 7-only construct is rejected, one per operator -------------------
# Note the brace form in the null-conditional cases. `?` is a legal character in a PowerShell
# variable name, so `$a?.Length` is the variable `$a?` followed by `.Length` — valid in 5.1 and
# correctly not flagged. Null-conditional access requires `${a}?.Length`, which is what 5.1 rejects.
declare -a seven=(
    'null-coalescing|$a = $null; $b = $a ?? 1'
    'null-coalescing-assign|$a = $null; $a ??= 5'
    'null-conditional|$a = $null; $b = ${a}?.Length'
    'null-conditional-index|$a = $null; $b = ${a}?[0]'
    'ternary|$c = $true ? "yes" : "no"'
    'pipeline-chain-and|Write-Output 1 && Write-Output 2'
    'pipeline-chain-or|Write-Output 1 || Write-Output 2'
)
for entry in "${seven[@]}"; do
    label=${entry%%|*}
    code=${entry#*|}
    dir=$(new_fixture "seven-$label")
    printf '%s\n' "$code" >"$dir/case.ps1"
    run_gate "$dir"
    [ $STATUS -eq 1 ] || fail "$label: a 7-only construct must exit 1 (got $STATUS): $OUT"
    grep -q '^INCOMPATIBLE case.ps1:' <<<"$OUT" || fail "$label: must be reported as INCOMPATIBLE: $OUT"
    grep -q 'failed=1' <<<"$OUT" || fail "$label: must be counted as a failure: $OUT"
done
ok "each PowerShell 7-only operator is rejected and located (${#seven[@]} cases)"

# --- an operator inside a string is NOT a construct --------------------------
# This is the false positive a textual scan produces on this repository's own files: `||` inside a
# single-quoted shell string passed to `docker compose exec`.
strings=$(new_fixture strings)
cat >"$strings/shellstring.ps1" <<'PS1'
docker compose exec -T svc sh -c 'git pull --ff-only || echo "(skipped)"'
$note = 'use && and || in shell, not here'
Write-Output $note   # a comment mentioning ?? and ?. must not trip the gate either
Get-ChildItem | ? { $_.Name }   # the Where-Object alias is a command name, valid in 5.1
$flag? = 1                      # '?' is a legal variable-name character
PS1
run_gate "$strings"
[ $STATUS -eq 0 ] || fail "operators inside strings/comments must not fail the gate: $OUT"
grep -q 'failed=0' <<<"$OUT" || fail "operators inside strings were miscounted: $OUT"
ok "operators inside strings and comments are not flagged"

# --- a parse error is caught with the parser's own message -------------------
broken=$(new_fixture broken)
printf 'function Broken {\n  if ($true) {\n' >"$broken/broken.ps1"
run_gate "$broken"
[ $STATUS -eq 1 ] || fail "a parse error must exit 1 (got $STATUS)"
grep -q '^PARSE-ERROR broken.ps1:' <<<"$OUT" || fail "a parse error must name the file and line: $OUT"
grep -qi "closing '}'" <<<"$OUT" || fail "a parse error must carry the parser's own message: $OUT"
ok "a parse error is reported with the parser's own message"

# --- an empty tree fails closed rather than passing vacuously ----------------
# The un-materialised pipeline this was first written with made `.Count` $null, so `-eq 0` was false
# and a tree with no PowerShell files would have "passed" having parsed nothing.
empty=$(new_fixture empty)
rm -f "$empty/scripts/powershell-syntax-gate.ps1"
mkdir -p "$empty/scripts"
cp "$GATE" "$TMP_DIR/gate-only.ps1"
run_gate_empty() {
    set +e
    OUT=$(docker run --rm --network none \
        -v "$TMP_DIR/gate-only.ps1:/gate.ps1:ro" -v "$empty:/repo:ro" --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" \
        -NoProfile -NonInteractive -File /gate.ps1 -Root /repo 2>&1)
    STATUS=$?
    set -e
}
run_gate_empty
[ $STATUS -eq 2 ] || fail "a tree with no PowerShell files must exit 2, not pass (got $STATUS): $OUT"
grep -q 'GATE-ERROR no PowerShell files' <<<"$OUT" || fail "an empty tree must say why: $OUT"
ok "a tree with no PowerShell files fails closed instead of passing vacuously"

# --- the wrapper never reports success when it could not run -----------------
set +e
missing_out=$(PWSH_IMAGE="coding-agent-sandbox-pwsh:does-not-exist" PWSH_DOCKERFILE=/nonexistent/Dockerfile "$WRAPPER" 2>&1)
missing_rc=$?
set -e
[ $missing_rc -eq 2 ] || fail "an unbuildable image must exit 2 (got $missing_rc)"
grep -q 'COULD NOT RUN' <<<"$missing_out" || fail "an unbuildable image must say it could not run"
grep -q '^PASS' <<<"$missing_out" && fail "the wrapper reported PASS while unable to run"
ok "the wrapper reports 'could not run' rather than success when the image cannot be built"

# --- the real tree passes ----------------------------------------------------
set +e
real_out=$("$WRAPPER" 2>&1)
real_rc=$?
set -e
[ $real_rc -eq 0 ] || fail "the repository's own PowerShell files must pass: $real_out"
grep -q '^PASS: ' <<<"$real_out" || fail "the wrapper did not report a pass for the real tree"
ok "the repository's own PowerShell files pass the gate"

printf '\nAll %d checks passed.\n' "$PASSED"
