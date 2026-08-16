#!/usr/bin/env bash
# Deterministic coverage for issue #82's two-architecture build gate.
# Drives it against fixture docker / verify-on-host binaries; builds nothing and reaches no host.
#
# The real two-machine run and the corrupted-checksum failure are recorded on the pull request — a
# unit test cannot build a multi-gigabyte image. What this covers is the reporting contract, which is
# where the gate can lie: an architecture that was not built must never be folded into a pass.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GATE="$ROOT/scripts/verify-image-architectures.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$GATE" ] || fail "the gate is missing or not executable"
ok "gate is present and executable"

# --- it must defeat the build cache -----------------------------------------
# A cached layer never executes, so a warm-cache build does not run sha256sum at all. Corrupting an
# architecture's checksum and rebuilding reported CACHED and succeeded; only --no-cache caught it.
# Without this the gate would pass a broken architecture branch.
docker_build_lines=$(grep -nE '^[^#]*docker build' "$GATE" || true)
[ -n "$docker_build_lines" ] || fail "the gate no longer builds anything"
while IFS= read -r line; do
    grep -q -- '--no-cache' <<<"$line" || fail "a build without --no-cache would not exercise checksums: $line"
done <<<"$docker_build_lines"
ok "every build the gate runs uses --no-cache"

# --- it must not grow a second way of reaching a machine --------------------
if grep -nE '^[^#]*\bssh\b' "$GATE" >/dev/null 2>&1; then
    fail "the gate connects to a host directly instead of via verify-on-host.sh"
fi
grep -q 'verify-on-host.sh' "$GATE" || fail "the gate no longer uses verify-on-host.sh"
ok "remote access goes only through verify-on-host.sh"

# --- fixtures ----------------------------------------------------------------
STUB_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info)  [[ "${DOCKER_SCENARIO:-}" == no-docker ]] && exit 1; exit 0 ;;
  build) [[ "${LOCAL_BUILD:-ok}" == fail ]] && { echo "sha256sum: WARNING: 1 computed checksum did NOT match" >&2; exit 1; }; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# Stand-in for verify-on-host.sh, so no host is contacted.
FAKE_VOH="$TMP_DIR/verify-on-host.sh"
cat >"$FAKE_VOH" <<'STUB'
#!/usr/bin/env bash
case "${REMOTE_SCENARIO:-ok}" in
  unreachable) exit 2 ;;
esac
last=${@: -1}
if [[ "$last" == *"uname -m"* ]]; then
  [[ "${REMOTE_SCENARIO:-ok}" == same-arch ]] && printf 'arm64\nLinux\n' || printf 'x86_64\nLinux\n'
  exit 0
fi
if [[ "$last" == *"tar xf"* ]]; then
  cat >/dev/null
  [[ "${REMOTE_SCENARIO:-ok}" == ship-fails ]] && exit 1
  exit 0
fi
if [[ "$last" == *"docker build"* ]]; then
  [[ "${REMOTE_SCENARIO:-ok}" == build-fails ]] && { echo "remote build broke"; exit 1; }
  exit 0
fi
exit 0
STUB
chmod +x "$FAKE_VOH"

# The gate resolves verify-on-host.sh relative to its own directory, so run a copy from a fixture
# tree whose scripts/ holds the stand-in.
FIX_ROOT="$TMP_DIR/repo"
mkdir -p "$FIX_ROOT/scripts"
cp "$GATE" "$FIX_ROOT/scripts/"
cp "$FAKE_VOH" "$FIX_ROOT/scripts/verify-on-host.sh"
printf 'FROM scratch\n' >"$FIX_ROOT/Dockerfile"
git -C "$FIX_ROOT" init -q 2>/dev/null && git -C "$FIX_ROOT" add -A 2>/dev/null \
    && git -C "$FIX_ROOT" -c user.email=t@t -c user.name=t commit -qm fixture 2>/dev/null

run_gate() { # -> STATUS, OUT
    set +e
    OUT=$(cd "$FIX_ROOT" && PATH="$STUB_DIR:$PATH" env "$@" ./scripts/verify-image-architectures.sh 2>&1)
    STATUS=$?
    set -e
}

# --- both architectures build ------------------------------------------------
run_gate
[ $STATUS -eq 0 ] || fail "both-built should exit 0 (got $STATUS): $OUT"
grep -q 'arm64 *BUILT' <<<"$OUT" || grep -q 'x86_64 *BUILT' <<<"$OUT" || fail "no local BUILT row: $OUT"
grep -qE 'amd64 +BUILT' <<<"$OUT" || fail "no remote BUILT row: $OUT"
grep -q 'both architecture branches built' <<<"$OUT" || fail "missing the pass line: $OUT"
ok "both architectures building yields a pass and names each host"

# --- an unreachable host is NOT COVERED, and not a pass ----------------------
run_gate REMOTE_SCENARIO=unreachable
[ $STATUS -eq 2 ] || fail "an unreachable host must exit 2, not $STATUS: $OUT"
grep -q 'NOT COVERED' <<<"$OUT" || fail "must report NOT COVERED: $OUT"
grep -q 'both architecture branches built' <<<"$OUT" && fail "reported a pass with an architecture missing"
ok "an unreachable host is NOT COVERED and never folded into a pass"

# --- shipping the tree failing is NOT COVERED, not a silent pass -------------
run_gate REMOTE_SCENARIO=ship-fails
[ $STATUS -eq 2 ] || fail "a failed tree transfer must exit 2, not $STATUS"
grep -q 'NOT COVERED' <<<"$OUT" || fail "must report NOT COVERED: $OUT"
ok "a failed tree transfer is NOT COVERED"

# --- a host of the same architecture covers nothing new ----------------------
run_gate REMOTE_SCENARIO=same-arch
[ $STATUS -eq 2 ] || fail "a same-architecture host must exit 2, not $STATUS"
grep -qi 'same as this machine' <<<"$OUT" || fail "must say the host adds no coverage: $OUT"
ok "a host of the same architecture is NOT COVERED, with the reason"

# --- a build failure is a failure, and outranks NOT COVERED ------------------
run_gate LOCAL_BUILD=fail REMOTE_SCENARIO=unreachable
[ $STATUS -eq 1 ] || fail "a build failure must exit 1 even alongside NOT COVERED (got $STATUS): $OUT"
grep -qE 'FAILED' <<<"$OUT" || fail "must report FAILED: $OUT"
grep -qi 'checksum did NOT match' <<<"$OUT" || fail "must surface why the build failed: $OUT"
ok "a build failure exits 1, outranks NOT COVERED, and surfaces the cause"

run_gate REMOTE_SCENARIO=build-fails
[ $STATUS -eq 1 ] || fail "a remote build failure must exit 1 (got $STATUS): $OUT"
grep -qE 'amd64 +FAILED' <<<"$OUT" || fail "must attribute the failure to the remote architecture: $OUT"
ok "a remote build failure is attributed to that architecture"

# --- no Docker locally -------------------------------------------------------
run_gate DOCKER_SCENARIO=no-docker
[ $STATUS -eq 2 ] || fail "no local Docker must exit 2, not $STATUS"
grep -q 'Docker is unavailable' <<<"$OUT" || fail "must say Docker is unavailable: $OUT"
ok "no local Docker is NOT COVERED rather than a pass"

printf '\nAll %d checks passed.\n' "$PASSED"
