#!/usr/bin/env bash
# Deterministic coverage for issue #70's sidecar agent healthcheck.
# Drives mitm/agent-healthcheck.sh against a stub iptables and a real local listener; never starts a
# container, never touches a firewall, and never reaches the network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/mitm/agent-healthcheck.sh"
COMPOSE="$ROOT/docker-compose.sidecar.yml"
TMP_DIR=$(mktemp -d)
trap 'cleanup' EXIT

LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$CHECK" ] || fail "agent healthcheck is missing or not executable"
ok "agent healthcheck is present and executable"

# --- the check must stay read-only ----------------------------------------
# A healthcheck that could mutate the firewall would be a way to weaken the boundary it reports on.
if grep -nE '^[^#]*\b(iptables|ip6tables)\b[^|]*\s-(A|D|I|F|X|P|N|R)\b' "$CHECK" >/dev/null 2>&1; then
    fail "healthcheck contains an iptables mutation"
fi
ok "healthcheck performs no iptables mutation"

if grep -nE '^[^#]*\b(curl|wget|nc|getent)\b' "$CHECK" >/dev/null 2>&1; then
    fail "healthcheck issues a request or a name lookup beyond the TCP connect"
fi
ok "healthcheck opens no request path to the network"

# coreutils `timeout` exists in the Debian container but not on macOS, where this suite runs.
# Depending on it made the check report a healthy proxy as unreachable.
if grep -nE '^[^#]*(^|[;&|[:space:]])timeout[[:space:]]' "$CHECK" >/dev/null 2>&1; then
    fail "healthcheck invokes coreutils timeout, which is absent on macOS"
fi
ok "healthcheck depends on no non-POSIX external timeout command"

# --- fixture: a stub iptables whose OUTPUT chain we control ----------------
STUB_DIR="$TMP_DIR/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/iptables" <<'STUB'
#!/usr/bin/env bash
# Stub: prints the chain fixture named by IPTABLES_FIXTURE, or fails when it is "error".
[ "${IPTABLES_FIXTURE:-}" = error ] && exit 1
cat "${IPTABLES_FIXTURE:?}"
STUB
chmod +x "$STUB_DIR/iptables"

# Captured verbatim from `iptables -S OUTPUT` in a running sidecar agent container. Using real
# output rather than a hand-written approximation is deliberate: an idealised fixture claimed the
# catch-all rule was `-A OUTPUT -j REJECT`, while iptables actually renders it with
# `--reject-with icmp-port-unreachable`. The fixture passed and the live stack reported unhealthy.
HEALTHY_RULES="$TMP_DIR/healthy.rules"
cat >"$HEALTHY_RULES" <<'RULES'
-P OUTPUT DROP
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -o lo -j ACCEPT
-A OUTPUT -d 192.168.164.2/32 -o eth0 -p tcp -m tcp --dport 8888 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -p tcp -m tcp --dport 53 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 0.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 10.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 100.64.0.0/10 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 127.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 172.16.0.0/12 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 192.168.0.0/16 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 198.18.0.0/15 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 224.0.0.0/4 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -d 240.0.0.0/4 -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -j REJECT --reject-with icmp-port-unreachable
RULES

# --- fixture: a real local listener standing in for the sidecar proxy ------
# Bound to loopback, accepts a connection and closes it: exactly the TCP reachability the check
# probes, with nothing behind it.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$PORT" <<'PY' &
import socket, sys
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1])))
srv.listen(16)
while True:
    try:
        conn, _ = srv.accept()
        conn.close()
    except OSError:
        break
PY
LISTENER_PID=$!
disown "$LISTENER_PID" 2>/dev/null || true   # keep the shell from printing "Terminated" at cleanup
for _ in $(seq 1 50); do
    if bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then break; fi
    sleep 0.1
done

CLOSED_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

run_check() { # rules-fixture host port -> sets STATUS and OUT
    set +e
    OUT=$(PATH="$STUB_DIR:$PATH" \
        IPTABLES_FIXTURE="$1" \
        AGENT_HEALTHCHECK_SIDECAR_HOST="$2" \
        AGENT_HEALTHCHECK_SIDECAR_PORT="$3" \
        AGENT_HEALTHCHECK_CONNECT_TIMEOUT=2 \
        "$CHECK" 2>&1)
    STATUS=$?
    set -e
}

# --- healthy -------------------------------------------------------------
# The fixture pins port 8888, so point the rule check at the same port the listener uses by
# rewriting the fixture rather than relaxing the check.
HEALTHY_ON_PORT="$TMP_DIR/healthy-port.rules"
sed "s/--dport 8888/--dport $PORT/" "$HEALTHY_RULES" >"$HEALTHY_ON_PORT"
run_check "$HEALTHY_ON_PORT" 127.0.0.1 "$PORT"
[ $STATUS -eq 0 ] || fail "a healthy stack should exit 0 (got $STATUS): $OUT"
grep -q '^healthy:' <<<"$OUT" || fail "a healthy stack should say so: $OUT"
ok "healthy stack reports healthy and exits 0"

# --- negative: the firewall was never installed or was flushed ------------
FLUSHED="$TMP_DIR/flushed.rules"
printf -- '-P OUTPUT ACCEPT\n' >"$FLUSHED"
run_check "$FLUSHED" 127.0.0.1 "$PORT"
[ $STATUS -eq 1 ] || fail "a flushed firewall must exit 1 (got $STATUS)"
grep -qi 'policy is not DROP' <<<"$OUT" || fail "must name the policy as the failing condition: $OUT"
ok "flushed firewall is unhealthy and names the policy"

EMPTY="$TMP_DIR/empty.rules"
: >"$EMPTY"
run_check "$EMPTY" 127.0.0.1 "$PORT"
[ $STATUS -eq 1 ] || fail "an empty OUTPUT chain must exit 1 (got $STATUS)"
grep -qi 'not installed' <<<"$OUT" || fail "must name the absent firewall: $OUT"
ok "empty OUTPUT chain is unhealthy and names the absent firewall"

# --- negative: the pinned proxy rule is gone ------------------------------
NO_PIN="$TMP_DIR/no-pin.rules"
grep -v -- '--dport 8888' "$HEALTHY_RULES" >"$NO_PIN"
run_check "$NO_PIN" 127.0.0.1 "$PORT"
[ $STATUS -eq 1 ] || fail "a missing pinned proxy rule must exit 1 (got $STATUS)"
grep -qi 'no pinned ACCEPT rule' <<<"$OUT" || fail "must name the missing pin: $OUT"
ok "missing pinned proxy rule is unhealthy and names the pin"

# --- negative: egress would not fail closed -------------------------------
NO_REJECT="$TMP_DIR/no-reject.rules"
grep -vE '^-A OUTPUT -j REJECT' "$HEALTHY_ON_PORT" >"$NO_REJECT"
run_check "$NO_REJECT" 127.0.0.1 "$PORT"
[ $STATUS -eq 1 ] || fail "a missing catch-all REJECT must exit 1 (got $STATUS)"
grep -qi 'catch-all' <<<"$OUT" || fail "must name the missing catch-all: $OUT"
ok "missing catch-all REJECT is unhealthy and names it"

# --- negative: iptables cannot be read at all -----------------------------
run_check error 127.0.0.1 "$PORT"
[ $STATUS -eq 1 ] || fail "an unreadable OUTPUT chain must exit 1 (got $STATUS)"
grep -qi 'cannot read the OUTPUT chain' <<<"$OUT" || fail "must name the unreadable chain: $OUT"
ok "unreadable OUTPUT chain is unhealthy and names the cause"

# --- negative: the sidecar proxy is unreachable ---------------------------
CLOSED_RULES="$TMP_DIR/closed.rules"
sed "s/--dport 8888/--dport $CLOSED_PORT/" "$HEALTHY_RULES" >"$CLOSED_RULES"
run_check "$CLOSED_RULES" 127.0.0.1 "$CLOSED_PORT"
[ $STATUS -eq 1 ] || fail "an unreachable proxy must exit 1 (got $STATUS)"
grep -qi 'cannot reach the pinned sidecar proxy' <<<"$OUT" || fail "must name the unreachable proxy: $OUT"
ok "unreachable sidecar proxy is unhealthy and names it"

# The firewall is checked before the connect, so a stack that is broken in both ways reports the
# firewall — the more actionable of the two.
run_check "$FLUSHED" 127.0.0.1 "$CLOSED_PORT"
[ $STATUS -eq 1 ] || fail "both-broken must exit 1 (got $STATUS)"
grep -qi 'policy is not DROP' <<<"$OUT" || fail "both-broken should report the firewall first: $OUT"
ok "when both invariants fail, the firewall is reported first"

# --- the compose wiring ---------------------------------------------------
grep -q 'agent-healthcheck.sh:/usr/local/bin/agent-healthcheck.sh:ro' "$COMPOSE" \
    || fail "the sidecar compose file does not mount the agent healthcheck"
grep -q '/usr/local/bin/agent-healthcheck.sh' "$COMPOSE" \
    || fail "the sidecar compose file does not run the agent healthcheck"
ok "sidecar compose mounts and runs the agent healthcheck"

# The default and MITM variants must keep the healthchecks they already had.
grep -q 'pgrep -x tinyproxy' "$ROOT/Dockerfile" \
    || fail "the base image healthcheck changed; issue #70 must leave it alone"
grep -q 'pgrep -x mitmdump' "$ROOT/Dockerfile.mitm" \
    || fail "the MITM image healthcheck changed; issue #70 must leave it alone"
if grep -qE '^\s*healthcheck:' "$ROOT/docker-compose.yml" "$ROOT/docker-compose.mitm.yml"; then
    fail "a healthcheck override leaked into the default or MITM compose file"
fi
ok "default and MITM variant healthchecks are unchanged"

printf '\nAll %d checks passed.\n' "$PASSED"
