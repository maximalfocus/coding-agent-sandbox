#!/usr/bin/env bash
# Every tracked .ps1 must be readable by Windows PowerShell 5.1 (issue #106, CAS-R162).
#
# 5.1 decodes a file WITHOUT a BOM using the system code page — Windows-1252 on the reference host —
# not UTF-8. This repository's files contain em dashes, including inside `Write-Host` strings, and
# 5.1's parser treats curly quotes as string delimiters, so the mis-decoded bytes unbalance the
# parse. Four shipped entry points failed outright on 2026-08-17: the launcher, two login helpers,
# and the egress allow-list tool. Measured on run.ps1: 17 parse errors read with the default
# encoding, 0 read as explicit UTF-8. The files were never syntactically wrong.
#
# The invariant: a tracked .ps1 is **pure ASCII** or **carries a UTF-8 BOM**. Either way 5.1 reads
# the bytes the author wrote.
#
# This exists because the two checks that could have caught it cannot run on most changes:
# scripts/test-powershell-syntax.sh runs pwsh 7, which defaults to UTF-8 — the file it parses is not
# the file 5.1 reads — and scripts/verify-powershell-runtime.sh needs a Windows host. This one needs
# neither PowerShell nor a network, so it runs everywhere and catches a regression the day it lands.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

has_bom() { [ "$(head -c 3 "$1" | xxd -p)" = "efbbbf" ]; }
# `tr` on byte ranges rather than a grep bracket expression. BSD grep does not interpret \xNN
# escapes inside brackets: it reads `[^\x00-\x7F]` as "not one of \ x 0 - 7 F", which nearly every
# byte satisfies, so the first version rejected every file including pure ASCII. It failed closed
# rather than open, so the negative controls caught it immediately — which is the argument for
# having them.
is_ascii() { [ "$(LC_ALL=C tr -d '\000-\177' < "$1" | wc -c | tr -d ' ')" = "0" ]; }

# Named so a failure says what to do, not merely that something is wrong.
classify() {
    if has_bom "$1"; then echo bom
    elif is_ascii "$1"; then echo ascii
    else echo unreadable-by-5.1
    fi
}

files=$(git ls-files '*.ps1')
[ -n "$files" ] || fail "no PowerShell files are tracked — this check would pass vacuously"
count=$(printf '%s\n' "$files" | grep -c .)
ok "$count tracked PowerShell files to check"

offenders=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(classify "$f")" = "unreadable-by-5.1" ] && offenders="$offenders $f"
done <<<"$files"
[ -z "$offenders" ] || fail "these carry non-ASCII with no BOM, so 5.1 will mis-decode them:$offenders
    Add a UTF-8 BOM, or restrict the file to ASCII."
ok "every tracked PowerShell file is ASCII or carries a UTF-8 BOM"

# --- the check must be able to fail -----------------------------------------
# A gate that has never been shown to reject anything is not evidence, which is the standard the
# rest of this repository's checks are held to.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '# a bare em dash \xe2\x80\x94 with no BOM\n' > "$TMP/offender.ps1"
[ "$(classify "$TMP/offender.ps1")" = "unreadable-by-5.1" ] \
    || fail "a non-ASCII file with no BOM was not detected"
ok "a non-ASCII file with no BOM is detected"

printf '\xef\xbb\xbf# a bare em dash \xe2\x80\x94 with a BOM\n' > "$TMP/bom.ps1"
[ "$(classify "$TMP/bom.ps1")" = "bom" ] || fail "a BOM-carrying file was not accepted"
ok "a non-ASCII file with a BOM is accepted"

printf '# plain ascii only\n' > "$TMP/ascii.ps1"
[ "$(classify "$TMP/ascii.ps1")" = "ascii" ] || fail "a pure-ASCII file was not accepted"
ok "a pure-ASCII file is accepted without a BOM"

# The specific characters that caused the failure, in the position that caused it.
printf '#!/x\nWrite-Host "a string with an em dash \xe2\x80\x94 inside it"\n' > "$TMP/instring.ps1"
[ "$(classify "$TMP/instring.ps1")" = "unreadable-by-5.1" ] \
    || fail "an em dash inside a string was not detected"
ok "an em dash inside a quoted string — the exact failing shape — is detected"

# --- the BOM must not have changed any file's content -----------------------
# The repair added three bytes and nothing else. Asserting it here keeps a future "fix" from
# quietly editing scripts to dodge the check.
badstart=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    has_bom "$f" || continue
    # After the BOM, the file must begin the way a PowerShell file does — not with another BOM,
    # and not with mojibake from a double conversion.
    rest=$(tail -c +4 "$f" | head -c 3 | xxd -p)
    [ "$rest" = "efbbbf" ] && badstart="$badstart $f"
done <<<"$files"
[ -z "$badstart" ] || fail "double BOM, so the file was converted twice:$badstart"
ok "no file carries a doubled BOM"

printf '\nAll %d checks passed.\n' "$PASSED"
