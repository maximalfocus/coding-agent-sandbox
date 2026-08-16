#!/usr/bin/env bash
# Secret-free probe for issue #78's gVisor feasibility verdict (docs/gvisor-variant-feasibility.md).
#
# Re-establishes the facts that verdict rests on. It reads no credential, prints no secret, mounts no
# volume, and reaches no network beyond what a container start needs. Every check reports one of:
#
#   PASS        the fact still holds as the verdict describes it
#   CHANGED     the fact no longer holds — the verdict needs revisiting
#   UNVERIFIED  this host cannot evaluate the check (no gVisor, wrong platform, image absent)
#
# UNVERIFIED is never a pass. gVisor can only be exercised on a Linux host running Docker on its own
# kernel; on macOS and Windows, Docker runs inside a Linux VM and every gVisor check here is
# legitimately unevaluable. See docs/verification-hosts.md.
#
# Usage:
#   scripts/probe-gvisor-support.sh          human-readable
#   scripts/probe-gvisor-support.sh --json   machine-readable
#
# Exit status: 0 when no relied-on fact is contradicted (UNVERIFIED included),
#              1 when a relied-on fact has CHANGED.
set -uo pipefail

VERDICT_DOC=docs/gvisor-variant-feasibility.md
RUNSC_BIN=${RUNSC_BIN:-runsc}
PROBE_IMAGE=${PROBE_IMAGE:-alpine:latest}
JSON=0
case "${1:-}" in
    --json) JSON=1 ;;
    "") ;;
    *) printf 'usage: %s [--json]\n' "${0##*/}" >&2; exit 2 ;;
esac

CHANGED=0
RESULTS=()

record() { # status name detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    [[ $1 == CHANGED ]] && CHANGED=1
    return 0
}

json_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

emit() {
    if [[ $JSON -eq 1 ]]; then
        printf '{\n  "verdictDoc": "%s",\n  "checks": [\n' "$VERDICT_DOC"
        local first=1 line status name detail
        for line in ${RESULTS+"${RESULTS[@]}"}; do
            IFS=$'\t' read -r status name detail <<<"$line"
            [[ $first -eq 0 ]] && printf ',\n'
            first=0
            printf '    {"status": "%s", "check": "%s", "detail": "%s"}' \
                "$status" "$(json_escape "$name")" "$(json_escape "$detail")"
        done
        printf '\n  ],\n  "relianceContradicted": %s\n}\n' \
            "$([[ $CHANGED -eq 1 ]] && echo true || echo false)"
    else
        local line status name detail
        for line in ${RESULTS+"${RESULTS[@]}"}; do
            IFS=$'\t' read -r status name detail <<<"$line"
            printf '%-11s %-30s %s\n' "$status" "$name" "$detail"
        done
        printf '\n'
        if [[ $CHANGED -eq 1 ]]; then
            printf 'RESULT: a fact the gVisor verdict relies on has CHANGED — revisit %s\n' "$VERDICT_DOC"
        else
            printf 'RESULT: no fact the gVisor verdict relies on was contradicted\n'
        fi
    fi
}

unverified_rest() { # reason
    record UNVERIFIED gvisor-interposes "$1"
    record UNVERIFIED iptables-needs-net-raw "$1"
    record UNVERIFIED baseline-caps-insufficient "$1"
    record UNVERIFIED nested-daemon-unsupported "$1"
}

# --- can this host evaluate anything at all? -------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    record UNVERIFIED runsc-present "Docker is unavailable"
    unverified_rest "requires Docker"
    emit; exit 0
fi

host_os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)
if ! command -v "$RUNSC_BIN" >/dev/null 2>&1; then
    record UNVERIFIED runsc-present \
        "runsc is not installed (host: ${host_os:-unknown}); gVisor needs a bare-kernel Linux host"
    unverified_rest "requires runsc"
    emit; exit 0
fi

version=$("$RUNSC_BIN" --version 2>&1 | head -1)
record PASS runsc-present "${version:-version unreadable}"

if ! docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null | grep -qw runsc; then
    record UNVERIFIED gvisor-interposes "runsc is installed but not registered as a Docker runtime"
    record UNVERIFIED iptables-needs-net-raw "requires the runsc runtime"
    record UNVERIFIED baseline-caps-insufficient "requires the runsc runtime"
    record UNVERIFIED nested-daemon-unsupported "requires the runsc runtime"
    emit; exit 0
fi

if ! docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
    record UNVERIFIED gvisor-interposes "probe image $PROBE_IMAGE is not present locally"
    unverified_rest "requires $PROBE_IMAGE"
    emit; exit 0
fi

# --- 1. gVisor actually interposes -----------------------------------------
# If this ever stopped being true, every other conclusion below would be describing runc.
guest_kernel=$(docker run --rm --runtime=runsc "$PROBE_IMAGE" uname -r 2>/dev/null)
if [[ "$guest_kernel" == *gvisor* ]]; then
    record PASS gvisor-interposes "container reports $guest_kernel"
else
    record CHANGED gvisor-interposes "container reports '${guest_kernel:-nothing}', expected a *-gvisor kernel"
fi

# --- 2/3. the blocking finding ---------------------------------------------
# The verdict rests on iptables being unavailable under the CAS-R002 capability baseline and
# available once NET_RAW is added. Both halves are checked, because either one changing would
# reopen the question.
caps_baseline=(--cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE)

ipt_probe() { # extra-caps... -> 0 when iptables works
    docker run --rm --runtime=runsc "${caps_baseline[@]}" "$@" \
        --security-opt no-new-privileges:true "$PROBE_IMAGE" \
        sh -c 'apk add --no-cache iptables-legacy >/dev/null 2>&1; iptables-legacy -S OUTPUT >/dev/null 2>&1' \
        >/dev/null 2>&1
}

if ipt_probe; then
    record CHANGED baseline-caps-insufficient \
        "iptables now works under the CAS-R002 baseline — the blocking conflict may be gone"
else
    record PASS baseline-caps-insufficient "iptables still unavailable without CAP_NET_RAW"
fi

# The other half of the contrast needs BOTH the capability and a runtime registered with
# `--net-raw=true`: that flag only stops gVisor stripping CAP_NET_RAW, and the capability alone is
# useless without it. A host that has not registered such a runtime cannot evaluate this, and saying
# so is the honest answer — reporting CHANGED here because the runtime is absent would be a false
# alarm, and a probe that cries wolf is worth less than no probe.
netraw_runtime=$(docker info --format '{{json .Runtimes}}' 2>/dev/null \
    | python3 -c '
import json, sys
try:
    runtimes = json.load(sys.stdin)
except Exception:
    sys.exit()
for name, cfg in (runtimes or {}).items():
    if any("--net-raw=true" in str(a) for a in (cfg.get("runtimeArgs") or [])):
        print(name); break
' 2>/dev/null)

if [[ -z "$netraw_runtime" ]]; then
    record UNVERIFIED iptables-needs-net-raw \
        "no Docker runtime is registered with --net-raw=true, so the contrast cannot be evaluated here"
elif docker run --rm --runtime="$netraw_runtime" "${caps_baseline[@]}" --cap-add NET_RAW \
        --security-opt no-new-privileges:true "$PROBE_IMAGE" \
        sh -c 'apk add --no-cache iptables-legacy >/dev/null 2>&1; iptables-legacy -S OUTPUT >/dev/null 2>&1' \
        >/dev/null 2>&1; then
    record PASS iptables-needs-net-raw \
        "iptables works with NET_RAW on runtime '$netraw_runtime', as the verdict describes"
else
    record CHANGED iptables-needs-net-raw \
        "iptables no longer works even with NET_RAW on runtime '$netraw_runtime' — the failure mode has changed"
fi

# --- 4. the SL-14 combination ----------------------------------------------
DIND_IMAGE=${DIND_IMAGE:-docker:29.6.2-dind}
if ! docker image inspect "$DIND_IMAGE" >/dev/null 2>&1; then
    record UNVERIFIED nested-daemon-unsupported "nested-daemon image $DIND_IMAGE is not present locally"
else
    # Wait long enough for a verdict either way. The failure takes tens of seconds to surface, so a
    # short window would report "it started" for a daemon that was still on its way to failing —
    # which is why this looks for a positive signal in both directions and reports UNVERIFIED when
    # it sees neither, rather than inferring success from silence.
    dind_out=$(docker run --rm --runtime=runsc --privileged "$DIND_IMAGE" \
        sh -c 'dockerd --host=tcp://0.0.0.0:2375 >/tmp/d.log 2>&1 &
               for _ in $(seq 1 40); do
                   grep -q "failed to start daemon" /tmp/d.log && { echo FAILED; exit 0; }
                   grep -q "API listen on" /tmp/d.log && { echo STARTED; exit 0; }
                   sleep 1
               done
               echo INCONCLUSIVE' 2>/dev/null | tail -1)
    case "$dind_out" in
        FAILED)  record PASS nested-daemon-unsupported "nested daemon still fails to start under gVisor" ;;
        STARTED) record CHANGED nested-daemon-unsupported \
                     "the nested daemon now starts under gVisor — CAS-R142 should be redetermined" ;;
        *)       record UNVERIFIED nested-daemon-unsupported \
                     "the nested daemon neither started nor reported a failure within the probe window" ;;
    esac
fi

emit
[[ $CHANGED -eq 1 ]] && exit 1
exit 0
