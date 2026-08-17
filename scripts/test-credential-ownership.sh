#!/usr/bin/env bash
# Coverage for issue #108: a credential file the agent cannot read is not the same as no login.
#
# The agent container sets no default user — the entrypoint needs root to install the mandatory
# firewall before `exec gosu node` — so `docker exec` lands as root and a login run that way writes
# ~/.claude/.credentials.json owned by root, mode 0600. The agent runs as `node` and cannot read it.
#
# The smoke test reads as the agent, so that file arrives as empty content and classifies as
# `absent`, and the smoke test then told the operator to log in again — the exact act that produced
# the state. A message that closes the loop rather than opening one.
#
# This is #89's defect class in a state #89 did not know about. #89 separated *empty* from *absent*;
# this is a third thing, **present but unreadable by the account that needs it**.
#
# Reads source and drives the classifier; starts no container.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
SMOKE=sidecar-smoketest.sh
CLASSIFY=scripts/credential-state.sh

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

bash -n "$SMOKE" || fail "the smoke test does not parse"
ok "the smoke test parses"

block=$(awk '/credential-state.sh "\$PLACEHOLDER"/{f=1} f; /^esac/{if(f) exit}' "$SMOKE")
[ -n "$block" ] || fail "could not locate the credential classification block"

# --- the new state exists and is distinct -----------------------------------
grep -qE '^[[:space:]]*unreadable\)' <<<"$block" || fail "there is no branch for an unreadable credential file"
ok "the smoke test has a named branch for an unreadable credential file"

branch() { awk -v s="$1" '$0 ~ "^[[:space:]]*"s"\\)" {f=1; next} f && /;;/ {exit} f' <<<"$block"; }

unreadable=$(branch unreadable)
absent=$(branch absent)
[ -n "$unreadable" ] && [ -n "$absent" ] || fail "one of the two branches is empty"

[ "$(tr -d '[:space:]' <<<"$unreadable")" != "$(tr -d '[:space:]' <<<"$absent")" ] \
    || fail "the unreadable and absent branches report the same thing"
ok "an unreadable credential file is reported differently from no login at all"

grep -qi 'no login yet' <<<"$unreadable" && fail "the unreadable branch still claims there is no login"
ok "the unreadable branch does not claim there is no login"

# --- it must fail, not skip -------------------------------------------------
# A login the agent cannot use is a broken stack, not a state to shrug at. `absent` is a legitimate
# skip; this is not.
grep -qE '^[[:space:]]*no ' <<<"$unreadable" || fail "an unreadable credential file does not fail the smoke test"
ok "an unreadable credential file fails the smoke test rather than skipping"

# --- the message must name the cause and the repair -------------------------
grep -qi 'u node' <<<"$unreadable" || fail "the unreadable branch does not name the missing -u node"
ok "the message names the cause: a docker exec login without -u node"
grep -qi 'chown' <<<"$unreadable" || fail "the unreadable branch does not name the repair"
grep -qi 'restart' <<<"$unreadable" || fail "the unreadable branch does not mention that a restart also repairs it"
ok "the message names both repairs, including the restart that silently fixes it"

# --- the absent branch must stop manufacturing the state --------------------
grep -q 'u node' <<<"$absent" || fail "the absent branch still tells the operator to exec without -u node"
ok "the absent branch directs the operator to -u node"

# --- the detection has to read as root, or it cannot see the file -----------
detect=$(grep -n 'cred_state=unreadable' -B3 "$SMOKE" | head -6)
grep -q 'rexec' <<<"$detect" || fail "the existence probe does not run as root, so it cannot see a root-owned file"
ok "the existence probe runs as root, which is the only way to see the file"

# --- the classifier must stay content-only ----------------------------------
# It takes stdin and knows nothing about users or files. The user context lives at the call site,
# which is the only place that knows which account did the reading.
grep -qE 'docker|exec|test -f|-u node' "$CLASSIFY" && fail "the classifier gained knowledge of users or containers"
ok "the classifier still takes only content, with no knowledge of users or files"

# Empty content must still classify as absent — the classifier is not where this is distinguished.
[ "$(printf '' | ./$CLASSIFY)" = "absent" ] || fail "empty content no longer classifies as absent"
ok "empty content still classifies as absent at the classifier level"

# --- documentation must not manufacture the state ---------------------------
# Enumerated from the docs rather than a remembered list: any documented `docker exec` that runs
# `claude` writes to ~/.claude and must therefore run as node.
offenders=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -q 'u node' <<<"$line" || offenders="$offenders
    $line"
done < <(grep -rhn 'docker exec' docs/*.md README.md SECURITY.md 2>/dev/null \
         | grep -E 'claude( |$)|claude setup-token|bash -lc .claude')
[ -z "$offenders" ] || fail "documented invocations run claude without -u node:$offenders"
ok "every documented docker exec that runs claude uses -u node"

printf '\nAll %d checks passed.\n' "$PASSED"
