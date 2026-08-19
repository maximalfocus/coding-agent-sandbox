#!/usr/bin/env bash
# An advisory scan must stay advisory on Windows PowerShell 5.1 (issue #119).
#
# A scanner prints progress and INFO to stderr on a fully successful run. Under
# `$ErrorActionPreference = "Stop"` 5.1 turns native stderr into a TERMINATING NativeCommandError,
# and redirection does not prevent it. `scan.ps1` therefore aborted on a healthy image, taking
# `run.ps1` and `setup-windows.ps1` with it: a fresh Windows + Docker Desktop operator with no
# native `trivy` on PATH -- the default -- could not finish the documented setup at all.
#
# This is structural, and deliberately so: pwsh 7 does not turn native stderr into a terminating
# error, so no container can reproduce the behaviour. The behavioural half belongs to the
# `os:windows` runtime pass, exactly as `docs/verification-hosts.md` describes.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
PWSH_IMAGE=${PWSH_IMAGE:-coding-agent-sandbox-pwsh:7.6.5}
GATE=scripts/scan-advisory-gate.ps1

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -f "$GATE" ] || fail "$GATE is missing"

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP: no Docker daemon for the parser-based scan"; exit 0; }
docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1 || docker build -q -f "$ROOT/Dockerfile.pwsh" -t "$PWSH_IMAGE" "$ROOT" >/dev/null 2>&1 \
    || { echo "SKIP: the pinned pwsh image is unavailable"; exit 0; }

run_gate() {  # directory containing a scan.ps1 -> gate output
    docker run --rm -v "$ROOT/$GATE:/g.ps1:ro" -v "$1:/w:ro" -w /w \
        --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" -NoProfile -File /g.ps1 2>&1
}

out=$(run_gate "$ROOT")
printf '%s\n' "$out" | sed 's/^/    /'
calls=$(sed -nE 's/.*scanner-calls=([0-9]+).*/\1/p' <<<"$out")
unrelaxed=$(sed -nE 's/.*unrelaxed=([0-9]+).*/\1/p' <<<"$out")
[ "${calls:-0}" -gt 0 ] || fail "no scanner invocations were examined — the check has stopped matching"
ok "$calls scanner invocations examined by the parser in scan.ps1"
[ "${unrelaxed:-1}" -eq 0 ] || fail "$unrelaxed scanner call(s) still abort on the scanner's own stderr"
ok "every scanner call relaxes \$ErrorActionPreference and restores it in a finally"

# --- the check must be able to fail ----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/s"

grep -v "ErrorActionPreference = 'Continue'" scan.ps1 > "$TMP/s/scan.ps1"
grep -q "ErrorActionPreference = 'Continue'" "$TMP/s/scan.ps1" && fail "the mutation did not take"
out=$(run_gate "$TMP/s")
grep -q 'UNRELAXED' <<<"$out" || fail "a scanner call with nothing relaxing the preference was not detected: $out"
ok "a scanner call that would abort on stderr IS detected"

awk '{ if ($0 ~ /finally \{ \$ErrorActionPreference = \$prevEap \}/) next; print }' scan.ps1 > "$TMP/s/scan.ps1"
out=$(run_gate "$TMP/s")
grep -qE 'UNRESTORED|UNRELAXED' <<<"$out" || fail "a scanner call that never restores the preference was not detected: $out"
ok "a scanner call that leaves \$ErrorActionPreference relaxed IS detected"

# --- relaxing must not disarm STRICT ---------------------------------------
# The exit code is the scanner's real verdict, and TRIVY_STRICT is what turns it into a gate.
grep -qE '^\$gate = if \(\$env:TRIVY_STRICT\)' scan.ps1 || fail "TRIVY_STRICT no longer selects the gate mode"
grep -q '"--exit-code", "\$gate"' scan.ps1 || fail "the scanner is no longer told to gate on \$gate"
ok "TRIVY_STRICT still drives --exit-code, so a strict scan still blocks"
grep -qE '^exit \$rc$' scan.ps1 || fail "scan.ps1 no longer exits with the scanner's own code"
ok "scan.ps1 still exits with the scanner's exit code"

# --- the launcher must not block on an advisory scan either -----------------
# scan.ps1 no longer aborts, but run.ps1 still refused to start on ANY non-zero scan code and
# announced "STRICT scan failed" while the scan was advisory. run.sh has always split these.
run_ps1_scan_branch=$(awk '/\$scanRc = \$LASTEXITCODE/{f=1} f{print} f&&/^}/{exit}' run.ps1)
[ -n "$run_ps1_scan_branch" ] || fail "could not locate run.ps1's scan branch"
grep -q 'TRIVY_STRICT' <<<"$run_ps1_scan_branch" || fail "run.ps1 blocks on an advisory scan failure — it does not check TRIVY_STRICT"
ok "run.ps1 gates only when TRIVY_STRICT is set"
grep -q 'advisory scan could not complete' <<<"$run_ps1_scan_branch" || fail "run.ps1 has no advisory continue path"
ok "run.ps1 warns and continues when an ADVISORY scan cannot complete, as run.sh does"
grep -q 'advisory scan could not complete' run.sh || fail "run.sh lost its advisory continue path — the halves have diverged"
ok "run.sh and run.ps1 agree that an advisory scan never blocks the start"

# --- parity with the Unix half ---------------------------------------------
grep -q 'TRIVY_STRICT' scan.sh || fail "scan.sh lost its TRIVY_STRICT opt-in — the two halves have diverged"
ok "scan.sh keeps the same advisory-by-default contract"

printf '\nAll %d checks passed.\n' "$PASSED"
