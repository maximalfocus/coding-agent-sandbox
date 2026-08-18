#!/usr/bin/env bash
# A PowerShell function that forwards arbitrary arguments to a native command must be a SIMPLE
# function using $args (issue #115).
#
# `[Parameter(ValueFromRemainingArguments = $true)]` makes the function ADVANCED, which gives it the
# common parameters — and PowerShell then tries to bind a literal `-token` in the caller's source as
# a PARAMETER NAME before treating it as a value. So `Invoke-Docker exec -it -u node -w /workspace …`
# threw `AmbiguousParameter` (`-w` is an ambiguous prefix of -WarningAction/-WarningVariable) before
# docker ran at all. `shell.ps1` could not open a shell on Windows on ANY Docker path.
#
# Measured on Windows PowerShell 5.1:
#   with the attribute:     -w -e -o ambiguous;  -d silently binds to -Debug
#   simple function/$args:  all four arrive as plain values
#
# Neither existing gate can see this. It is valid syntax that fails at BINDING time, so the parser in
# scripts/test-powershell-syntax.sh accepts it, and scripts/verify-powershell-runtime.sh only parses.
# Reaching the call also needs a running sandbox container on Windows, which is why it shipped.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

# Switches that a common parameter shadows. Not a guess: measured on 5.1 and recorded here so a
# reviewer can see exactly what the rule protects.
AMBIGUOUS='-w -e -o -d'

files=$(git ls-files '*.ps1')
[ -n "$files" ] || fail "no PowerShell files are tracked — this check would pass vacuously"

# --- no forwarder may be an advanced function ------------------------------
# Scoped to FUNCTIONS that forward to a native command. A script-level `param()` with
# ValueFromRemainingArguments is a different shape and is fine: scripts/network/allow-domain.ps1
# collects domain names, which never begin with `-`, so nothing can be shadowed there.
# Comments are excluded, or this file's own explanation of the rule would trip it.
offenders=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        n=${hit%%:*}
        # inside a function block?
        prev=$(sed -n "1,${n}p" "$f" | grep -cE '^[[:space:]]*function [A-Za-z-]+[[:space:]]*\{')
        [ "$prev" -gt 0 ] || continue
        offenders="$offenders
    $f:$n"
    done < <(grep -nE 'ValueFromRemainingArguments' "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
done <<<"$files"
[ -z "$offenders" ] || fail "these forward arguments through an ADVANCED function, so a caller's -w/-e/-o/-d
  will bind to a common parameter instead of being passed through:$offenders
    Use a simple function and \$args instead."
ok "no argument-forwarding function uses ValueFromRemainingArguments"

# --- the forwarders that exist must still forward --------------------------
fwd=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE '^[[:space:]]*function Invoke-Docker[[:space:]]*\{' "$f" || continue
    fwd=$((fwd + 1))
    body=$(awk '/^[[:space:]]*function Invoke-Docker[[:space:]]*\{/{f=1} f{print} f&&/^\}/{exit}' "$f")
    [ -n "$body" ] || fail "$f: could not extract Invoke-Docker's body — the scan pattern is broken"
    grep -q '\$args' <<<"$body" || fail "$f: Invoke-Docker no longer forwards \$args"
    grep -q 'param(' <<<"$body" && fail "$f: Invoke-Docker regained a param block — it is advanced again"
done <<<"$files"
[ "$fwd" -gt 0 ] || fail "no Invoke-Docker forwarder found — the scan has stopped matching"
ok "$fwd Invoke-Docker forwarder(s) are simple functions that forward \$args"

# --- call sites carrying a shadowed switch must go through a safe forwarder -
sites=0
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    f=${hit%%:*}
    line=${hit#*:}; line=${line#*:}
    for sw in $AMBIGUOUS; do
        case " $line " in
            *" $sw "*)
                sites=$((sites + 1))
                grep -qE '^\s*function Invoke-Docker\s*\{' "$f" \
                    || fail "$f calls Invoke-Docker with $sw but defines no forwarder to check"
                ;;
        esac
    done
done < <(grep -rn 'Invoke-Docker ' --include='*.ps1' . 2>/dev/null | grep -v '^\./\.git' | grep -v 'function Invoke-Docker')
ok "$sites call site(s) carry a shadowed switch, each in a file whose forwarder is simple"

# --- the check must be able to fail ----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf 'function Invoke-Docker {\n    param([Parameter(ValueFromRemainingArguments = $true)]$DockerArgs)\n    & docker @DockerArgs\n}\n' > "$TMP/bad.ps1"
grep -q 'ValueFromRemainingArguments' "$TMP/bad.ps1" || fail "the advanced-function pattern is not detectable"
ok "an advanced forwarder is detectable — the scan is not vacuous"

printf 'function Invoke-Docker {\n    & docker @args\n}\n' > "$TMP/good.ps1"
grep -q 'ValueFromRemainingArguments' "$TMP/good.ps1" && fail "a simple forwarder was flagged"
ok "a simple forwarder is accepted"

printf '\nAll %d checks passed.\n' "$PASSED"
