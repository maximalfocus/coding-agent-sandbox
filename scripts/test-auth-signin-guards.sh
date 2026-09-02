#!/usr/bin/env bash
# The host-side sign-in commands must refuse by NAME, and must refuse BEFORE entering the login
# flow (issue #151, CAS-R034).
#
# The failure this holds shut is quiet: with the stack down or a capability gate off, an unguarded
# sign-in starts, prints a URL, and dies several steps later as a proxy 403. That reads as a provider
# outage or a network fault, and an operator can spend a long time on it before discovering they
# never set ALLOW_OPENAI. A refusal that names the unmet condition costs nothing and ends that class
# of investigation before it begins.
#
# Assertions are about what the commands actually invoke, through a `docker` shim on PATH, so no
# container is started, no credential is read, and no login flow is entered.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); }

# id:command, from the custody table's own rows, so a command added there is covered here the day it
# is added rather than the day someone remembers to update this list.
ROWS=$(awk '
    $0 == "```credential-custody" { inb = 1; next }
    inb && /^```/ { inb = 0; next }
    inb { print }
' "$ROOT/docs/credential-custody.md" | awk -F'|' '
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $4)
      if ($1 == "" || substr($1,1,1) == "#" || $3 == "-") next
      print $1 ":" $3 ":" $4 }')
[ -n "$ROWS" ] || fail 'no sign-in commands found in the custody table — this check would pass vacuously'

# Only the commands that drive the running sandbox are in scope here. deepseek-key provisions into a
# one-off sidecar container that is not running yet, so "is the sandbox up" is not its precondition;
# its own stack guard is covered by test-auth-helper-targeting.sh.
SIGNINS=""
for row in $ROWS; do
    case "${row#*:}" in deepseek-key:*) continue ;; esac
    SIGNINS="$SIGNINS $row"
done
[ -n "$SIGNINS" ] || fail 'no stack-driven sign-in commands found'

# --- the docker shim --------------------------------------------------------
# `ps` answers with whatever the test wants running; `exec` answers the allowlist probe with
# $FILTER_HAS and otherwise records and stops, so the login flow is never reached.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case " $* " in
    *" ps "*) printf '%s\n' "$RUNNING_CONTAINERS"; exit 0 ;;
    *" grep "*)
        # The allowlist probe. Exit 0 only when the requested gate string is present.
        for a in "$@"; do
            case " $FILTER_HAS " in *" $a "*) exit 0 ;; esac
        done
        exit 1 ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/docker"

invoke() { # invoke SCRIPT RUNNING FILTER_HAS
    : > "$TMP/log"
    set +e
    DOCKER_LOG="$TMP/log" RUNNING_CONTAINERS="$2" FILTER_HAS="$3" PATH="$TMP/bin:$PATH" \
        bash "$ROOT/scripts/auth/$1" > "$TMP/out" 2>&1
    local code=$?
    set -e
    return $code
}
entered_flow() { grep -Eq 'auth login|login --device-auth' "$TMP/log"; }

for entry in $SIGNINS; do
    id=${entry%%:*}
    rest=${entry#*:}
    command=${rest%%:*}
    gate=${rest#*:}
    script="$command.sh"
    [ -f "$ROOT/scripts/auth/$script" ] || fail "$script is missing"

    # 1. Stack down -> refuse, name that condition, and do not enter the flow.
    invoke "$script" "" "" && fail "$script did not refuse with the sandbox down"
    grep -q 'REFUSING' "$TMP/out" || fail "$script refused without saying so: $(cat "$TMP/out")"
    grep -q 'not running' "$TMP/out" || fail "$script did not name the unmet condition: $(cat "$TMP/out")"
    grep -q 'run.sh' "$TMP/out" || fail "$script did not say how to fix it"
    entered_flow && fail "$script entered the login flow despite refusing"
    ok

    # 2. Stack up, gate off -> refuse, NAME the gate and where to set it, and do not enter the flow.
    #    A command with no gate has nothing to refuse for and must proceed instead.
    if [ "$gate" != "-" ] && [ "${gate#*:}" != "-" ]; then
        name=${gate%%:*}
        invoke "$script" "claude-sandbox" "" && fail "$script did not refuse with $name off"
        grep -q "$name is off" "$TMP/out" || fail "$script did not name $name: $(cat "$TMP/out")"
        grep -q '\.env' "$TMP/out" || fail "$script did not say where to set $name"
        entered_flow && fail "$script entered the login flow with $name off"
        ok

        # 3. Stack up, gate on -> the guard lets it through and the flow IS entered.
        probe=${gate#*:}
        invoke "$script" "claude-sandbox" "$probe" || true
        entered_flow || fail "$script did not reach the login flow with $name on: $(cat "$TMP/log")"
        grep -q 'REFUSING' "$TMP/out" && fail "$script refused even with $name on"
        ok
    else
        invoke "$script" "claude-sandbox" "" || true
        entered_flow || fail "$script has no gate but still did not reach the login flow"
        ok
    fi

    # 4. The disclosure is printed on the success path, names the tier, and for an agent-readable
    #    credential says plainly who can read it. That last sentence is the point of the whole
    #    requirement: the tier is disclosed rather than left to be inferred.
    grep -q 'Credential custody for' "$TMP/out" || fail "$script did not disclose custody on success"
    tier=$(awk -F'|' -v want="$id" '
        $0 ~ /^[a-z]/ { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $7)
                        if ($1 == want) print $7 }' "$ROOT/docs/credential-custody.md")
    case "$tier" in
        agent-readable)
            grep -q 'agent-readable container volume' "$TMP/out" || fail "$script did not name its tier"
            grep -q 'Any process running as the agent user can read this credential' "$TMP/out" \
                || fail "$script hid who can read an agent-readable credential" ;;
        *) grep -q 'tier ' "$TMP/out" || fail "$script did not name its tier" ;;
    esac
    ok

    # 5. An entry point only: it must not touch a vault, a placeholder, or another tool's volume.
    grep -Eq 'claim-token|claude-secret|deepseek' "$TMP/log" \
        && fail "$script touched a custody boundary; it is a sign-in, not a credential move"
    ok
done

printf 'PASS: %d sign-in guard checks across %s\n' "$PASSED" "$(printf '%s' "$SIGNINS" | wc -w | tr -d ' ') commands"
