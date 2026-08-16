#!/usr/bin/env bash
# Deterministic coverage for issue #78's gVisor feasibility probe.
# Drives the probe against fixture `docker` binaries; never starts a container, never installs
# anything, never contacts a network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$ROOT/scripts/probe-gvisor-support.sh"
DOC="$ROOT/docs/gvisor-variant-feasibility.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[[ -x "$PROBE" ]] || fail "the probe is missing or not executable"
[[ -f "$DOC" ]] || fail "the gVisor verdict document is missing"
ok "probe and verdict document are present"

# The probe reports on the host; it must not reconfigure it. Registering a runtime or editing
# daemon.json from a probe would change the thing being measured.
if grep -nE '^[^#]*(daemon\.json|runsc install|runsc uninstall|systemctl|tee /etc)' "$PROBE" >/dev/null 2>&1; then
    fail "the probe mutates host runtime configuration"
fi
ok "probe makes no change to host runtime configuration"

if grep -nE '^[^#]*(\.env|credentials\.json|api-key|TTYD_PASS)' "$PROBE" >/dev/null 2>&1; then
    fail "the probe reads a credential location"
fi
ok "probe reads no credential location"

# --- fixture docker -----------------------------------------------------------
STUB_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_DIR"

# $1 scenario, consumed via DOCKER_SCENARIO
cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
case "${DOCKER_SCENARIO:-}" in
  no-docker) exit 1 ;;
esac
case "$1" in
  info)
    case "${2:-}" in
      --format)
        case "$3" in
          *OperatingSystem*) echo "Fixture Linux" ;;
          *Runtimes*)
            if [[ "$3" == *json* ]]; then
              if [[ "${DOCKER_SCENARIO:-}" == netraw ]]; then
                echo '{"runsc":{"path":"/usr/local/bin/runsc"},"runsc-netraw":{"path":"/usr/local/bin/runsc","runtimeArgs":["--net-raw=true"]}}'
              else
                echo '{"runsc":{"path":"/usr/local/bin/runsc"}}'
              fi
            else
              [[ "${DOCKER_SCENARIO:-}" == no-runtime ]] && echo "runc " || echo "runc runsc "
            fi
            ;;
        esac
        ;;
      *) exit 0 ;;
    esac
    ;;
  image) [[ "${DOCKER_SCENARIO:-}" == no-image ]] && exit 1 || exit 0 ;;
  run)
    # `uname -r` probe
    if [[ "$*" == *"uname -r"* ]]; then
      [[ "${DOCKER_SCENARIO:-}" == not-interposing ]] && echo "6.1.0-generic" || echo "4.19.0-gvisor"
      exit 0
    fi
    # iptables probes: succeed only when NET_RAW is present AND the netraw runtime was selected
    if [[ "$*" == *iptables-legacy* ]]; then
      if [[ "$*" == *"--cap-add NET_RAW"* && "$*" == *runsc-netraw* ]]; then exit 0; fi
      exit 1
    fi
    # nested daemon probe
    if [[ "$*" == *dockerd* ]]; then
      [[ "${DOCKER_SCENARIO:-}" == dind-starts ]] && echo STARTED || echo FAILED
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"

cat >"$STUB_DIR/runsc" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --version ]] && echo "runsc version release-fixture.0"
exit 0
STUB
chmod +x "$STUB_DIR/runsc"

run_probe() { # scenario [--json] -> sets STATUS and OUT
    set +e
    OUT=$(PATH="$STUB_DIR:$PATH" DOCKER_SCENARIO="$1" "$PROBE" ${2:-} 2>&1)
    STATUS=$?
    set -e
}

status_of() { awk -v n="$1" '$2 == n { print $1; found = 1 } END { if (!found) print "ABSENT" }' <<<"$OUT"; }

# --- no Docker at all: everything unevaluable, and that is not a failure -----
run_probe no-docker
[[ $STATUS -eq 0 ]] || fail "an unevaluable host must exit 0, not $STATUS"
grep -q '^PASS ' <<<"$OUT" && fail "reported PASS with no Docker available"
[[ "$(status_of runsc-present)" == UNVERIFIED ]] || fail "runsc-present should be UNVERIFIED: $OUT"
ok "with no Docker, every check is UNVERIFIED and nothing passes"

# --- runsc absent -------------------------------------------------------------
run_probe no-runtime
[[ $STATUS -eq 0 ]] || fail "an unregistered runtime must exit 0, not $STATUS"
[[ "$(status_of gvisor-interposes)" == UNVERIFIED ]] \
    || fail "gvisor-interposes should be UNVERIFIED when the runtime is unregistered: $OUT"
ok "an unregistered runsc runtime yields UNVERIFIED, not a pass"

# --- the healthy case: the verdict still holds --------------------------------
run_probe healthy
[[ $STATUS -eq 0 ]] || fail "the verdict-holds case must exit 0, not $STATUS: $OUT"
[[ "$(status_of gvisor-interposes)" == PASS ]] || fail "gVisor should be reported as interposing: $OUT"
[[ "$(status_of baseline-caps-insufficient)" == PASS ]] \
    || fail "the blocking fact should still be PASS: $OUT"
[[ "$(status_of nested-daemon-unsupported)" == PASS ]] \
    || fail "the nested-daemon fact should still be PASS: $OUT"
ok "when the verdict still holds, the relied-on facts report PASS and the run exits 0"

# The NET_RAW contrast needs a --net-raw runtime; absent one, it must be UNVERIFIED rather than a
# false alarm. This is the exact false positive an earlier draft of the probe produced.
[[ "$(status_of iptables-needs-net-raw)" == UNVERIFIED ]] \
    || fail "without a --net-raw runtime the contrast must be UNVERIFIED: $OUT"
ok "the NET_RAW contrast is UNVERIFIED without a --net-raw runtime, not CHANGED"

run_probe netraw
[[ "$(status_of iptables-needs-net-raw)" == PASS ]] \
    || fail "with a --net-raw runtime the contrast must evaluate: $OUT"
[[ $STATUS -eq 0 ]] || fail "the netraw case must exit 0, not $STATUS"
ok "with a --net-raw runtime the contrast evaluates and passes"

# --- the verdict stops holding ------------------------------------------------
run_probe not-interposing
[[ $STATUS -eq 1 ]] || fail "a runtime that stopped interposing must exit 1, not $STATUS"
[[ "$(status_of gvisor-interposes)" == CHANGED ]] || fail "should be CHANGED: $OUT"
grep -q 'CHANGED' <<<"$OUT" || fail "the summary should say a relied-on fact changed"
ok "a runtime that no longer interposes is CHANGED with exit 1"

run_probe dind-starts
[[ $STATUS -eq 1 ]] || fail "a nested daemon that now starts must exit 1, not $STATUS"
[[ "$(status_of nested-daemon-unsupported)" == CHANGED ]] || fail "should be CHANGED: $OUT"
grep -qi 'CAS-R142' <<<"$OUT" || fail "should name the requirement to redetermine: $OUT"
ok "a nested daemon that now starts is CHANGED and names CAS-R142"

# --- machine-readable output --------------------------------------------------
run_probe healthy --json
python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$OUT" || fail "--json is not valid JSON"
python3 - "$OUT" <<'PY' || fail "--json payload does not describe the run correctly"
import json, sys
d = json.loads(sys.argv[1])
assert d["relianceContradicted"] is False
statuses = {c["check"]: c["status"] for c in d["checks"]}
assert set(statuses.values()) <= {"PASS", "CHANGED", "UNVERIFIED"}, statuses
assert statuses["baseline-caps-insufficient"] == "PASS"
PY
ok "--json emits valid JSON matching the human report"

printf '\nAll %d checks passed.\n' "$PASSED"
