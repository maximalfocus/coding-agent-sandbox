#!/usr/bin/env bash
# Deterministic coverage for issue #89's credential-state classifier.
# Drives it with fixture credential documents; starts no container and reads no real credential.
#
# This suite is the actual fix for #89. The misreporting it corrects was possible because the logic
# lived inline in a live-only script, so it could never be exercised without a running stack and a
# real login — and so never was. Every state the file can be in now has a fixture.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLASSIFY="$ROOT/scripts/credential-state.sh"
SMOKE="$ROOT/sidecar-smoketest.sh"
PLACEHOLDER="sandbox-placeholder-do-not-use"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$CLASSIFY" ] || fail "the classifier is missing or not executable"
bash -n "$CLASSIFY" || fail "the classifier does not parse"
ok "classifier is present, executable, and parses"

state() { printf '%s' "$1" | "$CLASSIFY" "$PLACEHOLDER"; }

expect() { # description json expected
    local got
    got=$(state "$2")
    [ "$got" = "$3" ] || fail "$1: expected '$3', got '$got'"
    ok "$1 -> $3"
}

# --- the five states ---------------------------------------------------------
expect "an absent file" "" absent
expect "a whitespace-only file" "$(printf '\n\n  \t\n')" absent
expect "content with no accessToken" '{"claudeAiOauth":{"subscriptionType":"max"}}' malformed
expect "truncated json" '{"claudeAiOauth":{"acc' malformed
expect "the placeholder" \
    "{\"claudeAiOauth\":{\"accessToken\":\"$PLACEHOLDER\",\"refreshToken\":\"$PLACEHOLDER\"}}" placeholder
expect "cleared tokens" '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' cleared
expect "a real credential" \
    '{"claudeAiOauth":{"accessToken":"sk-real-value-never-log","expiresAt":1}}' credential

# --- the state that caused the bug -------------------------------------------
# A cleared file is neither the placeholder nor a credential. Under the old if/elif/else it landed in
# the branch asserting a real token was present, which is what misled #86's investigation.
cleared='{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'
[ "$(state "$cleared")" != "credential" ] || fail "a cleared file is still reported as a credential"
ok "a cleared file is never reported as a credential"

# --- the mirror error: never call it cleared while something claimable remains ---
# `cleared` routes the operator away from claim-token. That advice is only safe when there is truly
# nothing left to move, so a surviving token on EITHER field has to keep it out of that branch.
expect "an empty access token beside a real refresh token" \
    '{"claudeAiOauth":{"accessToken":"","refreshToken":"sk-real-value-never-log"}}' credential
expect "an empty refresh token beside a real access token" \
    '{"claudeAiOauth":{"accessToken":"sk-real-value-never-log","refreshToken":""}}' credential
expect "an access token cleared and no refresh field at all" \
    '{"claudeAiOauth":{"accessToken":"","expiresAt":0}}' cleared

# --- formatting must not change the verdict ----------------------------------
expect "whitespace around the colon" \
    "{\"claudeAiOauth\":{\"accessToken\" :  \"$PLACEHOLDER\"}}" placeholder
expect "pretty-printed json" \
    "$(printf '{\n  "claudeAiOauth": {\n    "accessToken": "%s"\n  }\n}' "$PLACEHOLDER")" placeholder
expect "cleared, pretty-printed" \
    "$(printf '{\n  "claudeAiOauth": {\n    "accessToken": ""\n  }\n}')" cleared

# --- the pass condition must not have become easier --------------------------
# Only an exact placeholder match may yield `placeholder`; near-misses must not.
for near in "${PLACEHOLDER}x" "x${PLACEHOLDER}" "${PLACEHOLDER%?}" "SANDBOX-PLACEHOLDER-DO-NOT-USE"; do
    got=$(state "{\"claudeAiOauth\":{\"accessToken\":\"$near\"}}")
    [ "$got" = "credential" ] || fail "near-miss '$near' classified as '$got', expected credential"
done
ok "near-miss placeholder values are not accepted as the placeholder"

# A placeholder appearing on some other field must not count.
expect "placeholder on a different field" \
    "{\"claudeAiOauth\":{\"refreshToken\":\"$PLACEHOLDER\",\"accessToken\":\"real-value\"}}" credential

# --- the placeholder is taken as a literal, not a pattern --------------------
odd='plain.*value'
got=$(printf '{"claudeAiOauth":{"accessToken":"plainXvalue"}}' | "$CLASSIFY" "$odd")
[ "$got" = "credential" ] || fail "placeholder was treated as a regex: got '$got'"
ok "the placeholder is matched literally, not as a pattern"

# --- it emits nothing but the state ------------------------------------------
out=$(state '{"claudeAiOauth":{"accessToken":"sk-real-value-never-log"}}')
[ "$out" = "credential" ] || fail "extra output alongside the state: '$out'"
case "$out" in *sk-real-value-never-log*) fail "the classifier echoed credential material" ;; esac
ok "the classifier prints only the state, never credential material"

# --- the smoke test consumes every state ------------------------------------
# The classifier is only half the fix. If the smoke test drops a state, that state silently falls
# into a branch describing some other state — which is exactly how #89 happened.
[ -f "$SMOKE" ] || fail "sidecar-smoketest.sh is missing"
bash -n "$SMOKE" || fail "the smoke test does not parse"

grep -q 'credential-state.sh' "$SMOKE" || fail "the smoke test no longer uses the classifier"
ok "the smoke test classifies through the shared script"

block=$(awk '/credential-state.sh/,/^esac/' "$SMOKE")
[ -n "$block" ] || fail "could not locate the classification block in the smoke test"

# Every state the classifier can print must be handled by name.
for st in $(grep -oE "^[[:space:]]*printf '[a-z]+" "$CLASSIFY" | grep -oE "[a-z]+$" | sort -u); do
    grep -qE "^[[:space:]]*${st}\)" <<<"$block" || fail "the smoke test has no branch for '$st'"
done
ok "every state the classifier emits has a named branch in the smoke test"

branch() { awk -v s="$1" '$0 ~ "^[[:space:]]*"s"\\)" {f=1; next} f && /;;/ {exit} f' <<<"$block"; }

# The two failure states must fail, and must not describe a credential that isn't there.
for st in malformed; do
    b=$(branch "$st")
    grep -qE '^[[:space:]]*no ' <<<"$b" || fail "the '$st' branch does not report a failure"
    grep -qi 'real token' <<<"$b" && fail "the '$st' branch claims a real token is present"
done
ok "a malformed credential file is reported as a failure, not as a credential"

catchall=$(awk '/^[[:space:]]*\*\)/{f=1; next} f && /;;/ {exit} f' <<<"$block")
[ -n "$catchall" ] || fail "the classification block has no catch-all"
grep -qE '^[[:space:]]*no ' <<<"$catchall" || fail "the catch-all does not report a failure"
grep -qi 'real token' <<<"$catchall" && fail "the catch-all still claims a real token is present"
ok "an unrecognised classifier result fails rather than being described as a credential"

# The three informational states must not be reported as failures.
for st in placeholder absent cleared credential; do
    b=$(branch "$st")
    [ -n "$b" ] || fail "the '$st' branch is empty"
    grep -qE '^[[:space:]]*no ' <<<"$b" && fail "the '$st' branch reports a hard failure"
done
ok "the informational states are reported without failing the smoke test"

# The distinct states must give distinct advice — merged wording is how a state gets lost.
adv=$(for st in placeholder absent cleared credential; do branch "$st" | tr -d '[:space:]'; echo; done)
[ "$(sort <<<"$adv" | uniq -d | wc -l)" -eq 0 ] || fail "two states report the same message"
ok "each state reports a message distinct from every other state"

# The state at the heart of #89 must say the claim cannot help, not tell the operator to claim.
cl=$(branch cleared)
grep -qi 'erased\|empty' <<<"$cl" || fail "the cleared branch does not say the login was erased"
grep -qi 'cannot help' <<<"$cl" || fail "the cleared branch does not say claiming cannot help here"
ok "the cleared branch tells the operator to log in again, not to re-run the claim"

printf '\nAll %d checks passed.\n' "$PASSED"
