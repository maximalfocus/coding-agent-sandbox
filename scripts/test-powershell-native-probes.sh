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
PWSH_IMAGE=${PWSH_IMAGE:-coding-agent-sandbox-pwsh:7.6.5}

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

# The scan is done by scripts/native-probe-gate.ps1 in the pinned pwsh container, using the PARSER.
# A textual scan cannot do this correctly: #111's version matched only `& native` and missed every
# bare invocation (issue #117), and broadening the regex then flagged `docker`/`git` occurring inside
# single-quoted shell strings passed to `docker compose exec` — the same false positives #76 hit
# before it switched to the token stream.
#
# A "probe" is a native invocation whose result the script reads: assigned to a variable, or followed
# by a `$LASTEXITCODE` test. An invocation whose failure should simply propagate is an ACTION and is
# not required to be guarded.
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP: no Docker daemon for the parser-based scan"; exit 0; }
docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1 || docker build -q -f "$ROOT/Dockerfile.pwsh" -t "$PWSH_IMAGE" "$ROOT" >/dev/null 2>&1 \
    || { echo "SKIP: the pinned pwsh image is unavailable"; exit 0; }

out=$(docker run --rm -v "$ROOT:/w:ro" -w /w --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" \
        -NoProfile -File ./scripts/native-probe-gate.ps1 2>&1)
status=$?
printf '%s\n' "$out" | grep -v '^SUMMARY' | sed 's/^/    /'
summary=$(printf '%s\n' "$out" | grep '^SUMMARY' | tail -1)
[ -n "$summary" ] || fail "the parser-based scan produced no summary: $out"
probes=$(sed -nE 's/.*probes=([0-9]+).*/\1/p' <<<"$summary")
unguarded=$(sed -nE 's/.*unguarded=([0-9]+).*/\1/p' <<<"$summary")
[ "${probes:-0}" -gt 0 ] || fail "no native probes were examined — the scan has stopped matching"
ok "$probes native probe sites examined by the parser, across every tracked .ps1"
[ "$status" -eq 0 ] && [ "${unguarded:-1}" -eq 0 ] \
    || fail "$unguarded native probe(s) can throw instead of reporting failure (listed above)"
ok "every native probe is guarded against a terminating NativeCommandError"

# --- the check must be able to fail ----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/probe"
printf '$ErrorActionPreference = "Stop"\n$r = docker compose ps 2>$null\nif ($r) { "up" }\n' > "$TMP/probe/bad.ps1"
bad=$(docker run --rm -v "$TMP/probe:/w:ro" -w /w --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" \
        -NoProfile -File /w/../w/bad.ps1 2>/dev/null; true)
out=$(docker run --rm -v "$ROOT/scripts/native-probe-gate.ps1:/g.ps1:ro" -v "$TMP/probe:/w:ro" -w /w \
        --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" -NoProfile -File /g.ps1 2>&1)
grep -q 'UNGUARDED' <<<"$out" || fail "an unguarded bare probe was not detected: $out"
ok "an unguarded BARE probe is detected — the blind spot #117 fixed stays fixed"

printf '$ErrorActionPreference = "Stop"\n$r = $null\ntry { $r = docker compose ps 2>$null } catch { $r = $null }\nif ($r) { "up" }\n' > "$TMP/probe/bad.ps1"
out=$(docker run --rm -v "$ROOT/scripts/native-probe-gate.ps1:/g.ps1:ro" -v "$TMP/probe:/w:ro" -w /w \
        --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" -NoProfile -File /g.ps1 2>&1)
grep -q 'UNGUARDED' <<<"$out" && fail "a guarded probe was flagged: $out"
ok "a guarded probe is accepted"

# A native command inside a single-quoted shell string must NOT be mistaken for an invocation.
printf '$ErrorActionPreference = "Stop"\n$r = $null\ntry { $r = docker compose exec -T x sh -c %s } catch { $r = $null }\n' "'git pull || docker ps'" > "$TMP/probe/bad.ps1"
out=$(docker run --rm -v "$ROOT/scripts/native-probe-gate.ps1:/g.ps1:ro" -v "$TMP/probe:/w:ro" -w /w \
        --entrypoint /usr/bin/pwsh "$PWSH_IMAGE" -NoProfile -File /g.ps1 2>&1)
grep -q 'UNGUARDED' <<<"$out" && fail "a native name inside a shell string was treated as an invocation: $out"
ok "a native name inside a quoted shell string is not a false positive"

# --- the specific regression that started this ------------------------------
grep -q 'Docker not found' shell.ps1 || fail "shell.ps1 lost its fail-closed message"
awk '/& wsl /{ if ($0 !~ /try \{/) { print "UNGUARDED"; exit } }' shell.ps1 | grep -q UNGUARDED \
    && fail "shell.ps1's WSL probe is unguarded again — its 'Docker not found' branch is unreachable"
grep -q 'try { & wsl' shell.ps1 || fail "shell.ps1 no longer probes WSL through a guarded call"
ok "shell.ps1's WSL probe is guarded, so its fail-closed message is reachable"

printf '\nAll %d checks passed.\n' "$PASSED"
