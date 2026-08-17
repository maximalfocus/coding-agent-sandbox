#!/usr/bin/env bash
# Parse every shipped PowerShell file on a REAL Windows PowerShell 5.1 runtime (issue #104,
# `CAS-R162`). This is the periodic runtime pass `docs/verification-hosts.md` describes, not the
# per-change gate — `scripts/test-powershell-syntax.sh` remains that.
#
# Why a container cannot close this. The container gate runs pwsh 7.6.5 and infers 5.1 incompatibility
# from the parser's TOKEN STREAM: the file parses under 7, and constructs that did not exist in 5.1
# are rejected. That inference is sound and worth keeping, but it is an inference. Under real 5.1 a
# 7-only construct is not a token to recognise — it is a hard parse error. This asserts the property
# instead of deducing it.
#
# The host is reached through scripts/verify-on-host.sh, so resolution stays delegated to the
# maintained fleet tool and the run reports the host class it actually reached (`CAS-R163`).
#
#   scripts/verify-powershell-runtime.sh [alias]     # default alias: win
#
# Exits non-zero if any file fails to parse, if the runtime is not 5.1, or if the negative control
# does not fail there — a gate that cannot be shown to fail is not evidence.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
ALIAS=${1:-win}
VERIFY="$ROOT/scripts/verify-on-host.sh"

[ -x "$VERIFY" ] || { echo "scripts/verify-on-host.sh is missing"; exit 2; }

count=$(git ls-files '*.ps1' | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || { echo "no PowerShell files are tracked — nothing to verify"; exit 2; }
git ls-files '*.ps1' | grep -q 'scripts/powershell-runtime-check.ps1' \
    || { echo "scripts/powershell-runtime-check.ps1 is not tracked, so it would not be shipped"; exit 2; }
echo "Verifying $count tracked PowerShell files on '$ALIAS'."

# The check is a shipped file rather than an inline script: what runs on the host is reviewable here,
# and it is itself covered by the container gate, which parses every tracked .ps1.
#
# Two steps rather than one. Windows OpenSSH hands each session PowerShell, so these statements are
# sent as-is with no `powershell -Command` wrapper — nesting bash quoting inside an ssh command string
# inside PowerShell quoting mangles the variables and produced an empty path that looked like a tar
# failure. Single-quoted here so bash expands nothing; PowerShell does its own expansion remotely.
#
# `git archive` sends only committed content, so an untracked scratch file cannot enter the result.
work='cas-pwsh-runtime-check'

unpack='$d="$env:TEMP\'"$work"'"; Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $d | Out-Null; Set-Location $d; tar xf -'
runit='Set-Location "$env:TEMP\'"$work"'"; & .\scripts\powershell-runtime-check.ps1; exit $LASTEXITCODE'

if ! git archive --format=tar HEAD -- '*.ps1' | "$VERIFY" "$ALIAS" -- "$unpack" >/dev/null 2>&1; then
    echo "VERDICT: NOT COVERED — could not ship the tracked PowerShell files to '$ALIAS'"
    exit 1
fi

out=$("$VERIFY" "$ALIAS" -- "$runit" 2>&1)
status=$?

printf '%s\n' "$out"

if grep -q 'CONTROL ACCEPTED-7-ONLY-SYNTAX' <<<"$out"; then
    echo "VERDICT: NOT COVERED — the runtime accepted PowerShell 7-only syntax, so a pass proves nothing"
    exit 1
fi
grep -q 'CONTROL rejected-7-only-syntax-as-expected' <<<"$out" || {
    echo "VERDICT: NOT COVERED — the negative control did not run, so this is not evidence"
    exit 1
}
grep -q 'RUNTIME version=5' <<<"$out" || {
    echo "VERDICT: NOT COVERED — the host did not report a PowerShell 5.x runtime"
    exit 1
}
if [ "$status" -ne 0 ]; then
    echo "VERDICT: FAILED on $ALIAS"
    exit "$status"
fi
echo "VERDICT: every tracked PowerShell file parses on a real Windows PowerShell 5.1 runtime ($ALIAS)"
