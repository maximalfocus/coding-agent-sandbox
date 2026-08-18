#!/usr/bin/env bash
# Every native-command PROBE in a PowerShell file must be able to report failure (issue #111).
#
# Under `$ErrorActionPreference = "Stop"` — which every launcher here sets — Windows PowerShell 5.1
# turns a native command's **stderr** into a TERMINATING `NativeCommandError`. `*> $null` redirects
# the stream but does not prevent the error. So an unguarded probe THROWS instead of returning, and
# the caller's own fail-closed branch is never reached: `shell.ps1` shipped a correct
# "Docker not found…" message that was unreachable, and the operator got a stack trace instead.
#
# This is 5.1-specific. PowerShell 7 does not do it by default, so the pinned pwsh 7.6.5 container
# gate cannot reproduce it and this check is structural rather than behavioural. The behavioural
# proof belongs to the `os:windows` runtime pass.
#
# The rule: a native invocation whose result is INSPECTED (`$LASTEXITCODE`, or its output assigned)
# is a probe and must be wrapped in try/catch. A native invocation whose failure should propagate —
# `wsl --install`, the manager call in deepseek-key.ps1 — is an action and is deliberately exempt.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

# Actions, not probes: a failure here must stop the script rather than be swallowed.
is_exempt() {
    case "$1" in
        *"wsl --install"*) return 0 ;;               # provisioning, not a check
        *"& docker @compose"*) return 0 ;;           # the manager call itself
        *"& docker @configArgs"*) return 1 ;;        # a resolution probe — must be guarded
    esac
    return 1
}

# A site is guarded when its line, or the line above it, opens a try.
guarded() { # file line
    local body prev
    body=$(sed -n "$2p" "$1"); prev=$(sed -n "$(( $2 - 1 ))p" "$1")
    grep -q 'try {' <<<"$body" && return 0
    grep -qE 'try \{\s*$' <<<"$prev" && return 0
    return 1
}

files=$(git ls-files '*.ps1')
[ -n "$files" ] || fail "no PowerShell files are tracked — this check would pass vacuously"

checked=0; offenders=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q 'ErrorActionPreference *= *"Stop"' "$f" || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        n=${hit%%:*}; body=${hit#*:}
        is_exempt "$body" && continue
        checked=$((checked + 1))
        guarded "$f" "$n" || offenders="$offenders
    $f:$n:$(printf '%s' "$body" | sed 's/^[[:space:]]*//' | cut -c1-70)"
    # Match guarded and unguarded alike — anchoring at line start would stop matching the moment a
    # site is wrapped in `try { ... }`, silently reducing this gate to zero examined sites.
    done < <(grep -nE '& (wsl|docker|git|npm|gh|tar|curl)\b' "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
done <<<"$files"

[ "$checked" -gt 0 ] || fail "no native probes were examined — the scan pattern has stopped matching"
ok "$checked native probe sites examined across the tracked PowerShell files"
[ -z "$offenders" ] || fail "these native probes can throw instead of reporting failure:$offenders
    Wrap in try/catch, or add to is_exempt() if the failure must propagate."
ok "every native probe is guarded against a terminating NativeCommandError"

# --- the check must be able to fail -----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '$ErrorActionPreference = "Stop"\n& docker info *> $null\nif ($LASTEXITCODE -eq 0) { "up" }\n' > "$TMP/bad.ps1"
if ! guarded "$TMP/bad.ps1" 2; then ok "an unguarded probe is detected"; else fail "an unguarded probe was not detected"; fi
printf '$ErrorActionPreference = "Stop"\ntry { & docker info *> $null } catch { }\n' > "$TMP/good.ps1"
if guarded "$TMP/good.ps1" 2; then ok "a guarded probe is accepted"; else fail "a guarded probe was rejected"; fi
printf '$ErrorActionPreference = "Stop"\ntry {\n    & docker info *> $null\n} catch { }\n' > "$TMP/multi.ps1"
if guarded "$TMP/multi.ps1" 3; then ok "a probe guarded by a multi-line try is accepted"; else fail "multi-line try not recognised"; fi

# --- the specific regression that started this ------------------------------
grep -q 'Docker not found' shell.ps1 || fail "shell.ps1 lost its fail-closed message"
awk '/& wsl /{ if ($0 !~ /try \{/) { print "UNGUARDED"; exit } }' shell.ps1 | grep -q UNGUARDED \
    && fail "shell.ps1's WSL probe is unguarded again — its 'Docker not found' branch is unreachable"
grep -q 'try { & wsl' shell.ps1 || fail "shell.ps1 no longer probes WSL through a guarded call"
ok "shell.ps1's WSL probe is guarded, so its fail-closed message is reachable"

printf '\nAll %d checks passed.\n' "$PASSED"
