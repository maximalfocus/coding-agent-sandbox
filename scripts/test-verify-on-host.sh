#!/usr/bin/env bash
# Deterministic coverage for issue #80's cross-machine verification wrapper.
# Drives it against a fixture fleet tool and a fixture ssh; contacts no network and reaches no host.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER="$ROOT/scripts/verify-on-host.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$WRAPPER" ] || fail "the wrapper is missing or not executable"
ok "wrapper is present and executable"

# --- CAS-R163's central constraint: no second discovery implementation -------
# Not a convention — an assertion. A copy of the fleet tool's logic here would drift from the
# maintained one and be exercised far less, which is the whole reason the requirement exists.
discovery_re='\b(arp|ssh-keyscan|ssh-keygen -lf)\b|([0-9a-f]{2}:){5}[0-9a-f]{2}'
if grep -nE "$discovery_re" "$WRAPPER" >/dev/null 2>&1; then
    fail "the wrapper implements host discovery of its own"
fi
ok "wrapper contains no discovery logic"

offenders=$(grep -rlnE "$discovery_re" "$ROOT/scripts" 2>/dev/null | grep -v 'test-verify-on-host.sh' || true)
[ -z "$offenders" ] || fail "a second discovery implementation exists: $offenders"
ok "no second discovery implementation anywhere in scripts/"

# The check above must be capable of failing. Prove it against a fixture that deliberately has one.
DECOY_DIR="$TMP_DIR/decoy"
mkdir -p "$DECOY_DIR"
printf '#!/usr/bin/env bash\narp -an | grep aa:bb:cc:dd:ee:ff\n' >"$DECOY_DIR/rogue-discovery.sh"
grep -rlnE "$discovery_re" "$DECOY_DIR" >/dev/null 2>&1 \
    || fail "the no-second-implementation check cannot detect a real one"
ok "the no-second-implementation check detects a deliberate offender"

# --- fixtures ----------------------------------------------------------------
STUB_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/find-host" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --list ]] && { printf 'mini\nidd\nwin\n'; exit 0; }
case "${FIND_HOST_SCENARIO:-ok}" in
  unknown-alias) echo "Unknown alias $1" >&2; exit 2 ;;
  not-found)     echo "could not find $1" >&2; exit 1 ;;
  empty)         exit 0 ;;
  *)             echo "10.0.0.42"; exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/find-host"

cat >"$STUB_DIR/ssh" <<'STUB'
#!/usr/bin/env bash
# Record that ssh was reached at all, so "must not fall back" is checkable.
printf 'ssh-invoked\n' >>"${SSH_TRACE:-/dev/null}"
args=("$@")
last=${args[${#args[@]}-1]}
if [[ "$last" == *"uname -m"* ]]; then
  # Model real ssh: without -n it reads stdin, which silently steals a caller's piped data.
  [[ " $* " == *" -n "* ]] || cat >/dev/null
  [[ "${SSH_FACTS_SCENARIO:-ok}" == silent ]] && exit 1
  # A Windows host runs PowerShell, so the POSIX probe finds no `uname` and yields nothing.
  [[ "${SSH_FACTS_SCENARIO:-ok}" == powershell ]] && exit 1
  echo "x86_64 bare Linux"
  exit 0
fi
if [[ "$last" == *'$env:OS'* ]]; then
  [[ " $* " == *" -n "* ]] || cat >/dev/null
  [[ "${SSH_FACTS_SCENARIO:-ok}" == powershell ]] || exit 1
  printf 'AMD64 vm Windows\r\n'          # real Windows OpenSSH emits CRLF
  exit 0
fi
if [[ "$last" == *STDIN-RELAY* ]]; then
  printf 'RELAYED:'; cat
  exit 0
fi
echo "COMMAND-RAN: $last"
exit "${SSH_COMMAND_STATUS:-0}"
STUB
chmod +x "$STUB_DIR/ssh"

run_wrapper() { # -> sets STATUS and OUT; env supplies scenarios
    set +e
    OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" "$WRAPPER" "$@" 2>&1)
    STATUS=$?
    set -e
}

# --- the fleet tool is unavailable: stop, never fall back --------------------
TRACE="$TMP_DIR/ssh.trace"
: >"$TRACE"
set +e
OUT=$(PATH="$STUB_DIR:$PATH" SSH_TRACE="$TRACE" HOME="$TMP_DIR/empty-home" FIND_HOST="$TMP_DIR/nonexistent" \
      "$WRAPPER" idd -- 'echo hi' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "an unavailable fleet tool must exit 2 (got $STATUS)"
grep -q 'COULD NOT RUN' <<<"$OUT" || fail "an unavailable fleet tool must say it could not run"
[ ! -s "$TRACE" ] || fail "the wrapper fell back to ssh when the fleet tool was unavailable"
ok "an unavailable fleet tool stops the run and never falls back to ssh"

# --- unknown alias -----------------------------------------------------------
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" FIND_HOST_SCENARIO=unknown-alias \
      "$WRAPPER" nosuch -- 'echo hi' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "an unknown alias must exit 2 (got $STATUS)"
grep -q 'not a known host' <<<"$OUT" || fail "an unknown alias must say so: $OUT"
grep -q 'idd' <<<"$OUT" || fail "an unknown alias must list the known aliases: $OUT"
ok "an unknown alias fails with the known-alias list, not a connection error"

# --- the host cannot be located ---------------------------------------------
: >"$TRACE"
set +e
OUT=$(PATH="$STUB_DIR:$PATH" SSH_TRACE="$TRACE" FIND_HOST="$STUB_DIR/find-host" FIND_HOST_SCENARIO=not-found \
      "$WRAPPER" idd -- 'echo hi' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "an unlocatable host must exit 2 (got $STATUS)"
grep -q 'could not locate' <<<"$OUT" || fail "an unlocatable host must say so: $OUT"
[ ! -s "$TRACE" ] || fail "the wrapper tried ssh for a host the fleet tool could not locate"
ok "a host the fleet tool cannot locate stops the run, and no ssh is attempted"

# --- a resolution that yields no address ------------------------------------
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" FIND_HOST_SCENARIO=empty \
      "$WRAPPER" idd -- 'echo hi' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "an empty address must exit 2 (got $STATUS)"
ok "a successful resolution with no address is treated as a failure"

# --- unreadable host facts ---------------------------------------------------
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" SSH_FACTS_SCENARIO=silent \
      "$WRAPPER" idd -- 'echo hi' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "unreadable host facts must exit 2 (got $STATUS)"
grep -qi 'host facts' <<<"$OUT" || fail "should name the unreadable facts: $OUT"
grep -q 'COMMAND-RAN' <<<"$OUT" && fail "the command ran against a host whose class was unknown"
ok "a host whose class cannot be read does not get the command"

# --- the happy path ----------------------------------------------------------
run_wrapper idd -- 'echo hi'
[ "$STATUS" -eq 0 ] || fail "a resolvable host should exit 0 (got $STATUS): $OUT"
grep -q 'COMMAND-RAN' <<<"$OUT" || fail "the command did not run: $OUT"
grep -q 'host-class: arch:x86_64 kernel:bare' <<<"$OUT" \
    || fail "the run must report the host class it reached: $OUT"
grep -q '10.0.0.42' <<<"$OUT" || fail "the run should name the resolved address: $OUT"
ok "a resolvable host runs the command and reports its host class"

# --- piped stdin reaches the command ----------------------------------------
# The host-facts probe runs first; without `ssh -n` it drains stdin and a caller piping data through
# loses it silently. That broke `git archive | verify-on-host.sh host -- 'tar xf -'`.
set +e
OUT=$(printf 'PAYLOAD\n' | PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" \
      "$WRAPPER" idd -- 'STDIN-RELAY' 2>/dev/null)
STATUS=$?
set -e
grep -q 'RELAYED:PAYLOAD' <<<"$OUT" || fail "piped stdin did not reach the command: $OUT"
ok "piped stdin reaches the command rather than being drained by the host-facts probe"

# --- the command's own status is preserved -----------------------------------
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" SSH_COMMAND_STATUS=7 \
      "$WRAPPER" idd -- 'exit 7' 2>&1)
STATUS=$?
set -e
[ "$STATUS" -eq 7 ] || fail "the command's exit status must be preserved (got $STATUS)"
ok "the command's own exit status is preserved, not masked"

# --- --list delegates --------------------------------------------------------
run_wrapper --list
[ "$STATUS" -eq 0 ] || fail "--list should exit 0"
grep -q '^idd$' <<<"$OUT" || fail "--list should delegate to the fleet tool: $OUT"
ok "--list delegates to the fleet tool"

# --- usage errors ------------------------------------------------------------
run_wrapper idd 'echo hi'
[ "$STATUS" -eq 2 ] || fail "a missing -- separator must exit 2 (got $STATUS)"
run_wrapper idd --
[ "$STATUS" -eq 2 ] || fail "a missing command must exit 2 (got $STATUS)"
ok "usage errors fail closed with exit 2"


# --- a PowerShell host is classified rather than rejected (issue #104) -------
# Windows OpenSSH hands each session PowerShell, so the POSIX probe finds no `uname`. That is the one
# host class docs/verification-hosts.md still records as unverified, and reaching it any other way
# would re-introduce the second implementation #80 removed.
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" SSH_FACTS_SCENARIO=powershell \
      "$WRAPPER" win -- 'hostname' 2>&1)
STATUS=$?
set -e
grep -q 'arch:AMD64' <<<"$OUT" || fail "a PowerShell host's architecture was not reported: $OUT"
grep -q 'kernel:vm' <<<"$OUT" || fail "a PowerShell host was not classified kernel:vm: $OUT"
grep -q 'Windows' <<<"$OUT" || fail "a PowerShell host was not named as Windows: $OUT"
[ "$STATUS" -eq 0 ] || fail "a PowerShell host stopped the run (status $STATUS): $OUT"
ok "a PowerShell host is classified as arch:AMD64 kernel:vm Windows"

# The CRLF real Windows OpenSSH emits must not survive into the reported facts.
grep -q $'\r' <<<"$OUT" && fail "carriage returns leaked into the host facts"
ok "carriage returns from a Windows host are stripped"

# The POSIX answer must win: no Unix host's classification can change because a fallback exists.
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" "$WRAPPER" idd -- 'hostname' 2>&1)
set -e
grep -q 'arch:x86_64 kernel:bare' <<<"$OUT" || fail "a Unix host's classification changed: $OUT"
grep -q 'Windows' <<<"$OUT" && fail "a Unix host was probed as Windows"
ok "the POSIX probe still answers first, so Unix hosts are unaffected"

# A host that answers neither probe must still stop, not be reported as unknown-but-acceptable.
set +e
OUT=$(PATH="$STUB_DIR:$PATH" FIND_HOST="$STUB_DIR/find-host" SSH_FACTS_SCENARIO=silent \
      "$WRAPPER" win -- 'hostname' 2>&1)
STATUS=$?
set -e
grep -q 'could not read its host facts' <<<"$OUT" || fail "a silent host did not stop the run: $OUT"
[ "$STATUS" -ne 0 ] || fail "a silent host returned success"
ok "a host answering neither probe still stops the run"

printf '\nAll %d checks passed.\n' "$PASSED"
