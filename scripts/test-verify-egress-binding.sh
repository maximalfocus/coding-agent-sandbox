#!/usr/bin/env bash
# scripts/verify-egress-binding.sh decides one thing: did the packet this probe generated hit the
# REJECT rule it names? That decision is what makes the self-test sensitive to a reordering, and it
# is what these cases pin down.
#
# The helper invokes `iptables`, `gosu` and `curl` by name, so the cases shim them on PATH and drive
# the decision directly. The shim is the point rather than a shortcut: it can present a counter that
# does NOT move - the signature of an ACCEPT matching first - which is precisely the state a real
# container cannot be put into without breaking its own firewall.
#
# The live behaviour on a real chain is verified separately by starting the sandbox; this suite
# covers the logic that reads the evidence.
#
# Runs offline: no container, no network, no credential, no iptables.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/verify-egress-binding.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); printf 'PASS: %s\n' "$*"; }

[ -x "$HELPER" ] || fail 'scripts/verify-egress-binding.sh is missing or not executable'

if grep -Eq 'declare -A|local -A' "$HELPER"; then
    fail 'the helper uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

BIN="$TMP_DIR/bin"; mkdir -p "$BIN"
STATE="$TMP_DIR/state"

# `gosu <user> <cmd...>` and `curl` both just record that they ran; the counter is what decides.
cat > "$BIN/gosu" <<'EOF'
#!/usr/bin/env bash
shift          # drop the user
echo "gosu $*" >> "$STATE/ran"
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Record whether a proxy variable survived into the probe. With one set, curl sends the request to
# the proxy on loopback rather than to the address under test, so no packet is ever addressed to
# the range being probed and its counter cannot move - the helper would then report a violation
# that is purely its own doing. Observed on a live container before the helper unset them.
for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    eval "val=\${$v-}"
    [ -n "$val" ] && echo "proxied-via $v=$val" >> "$STATE/ran"
done
echo "curl $*" >> "$STATE/ran"
exit 7         # a rejected connection, the ambiguous signal the helper must NOT rely on
EOF
# The shim renders an `iptables -nvxL OUTPUT` table. MODE decides how the counters behave:
#   moving  - every REJECT counter increments on each read (the rule matched)
#   static  - counters never move (an ACCEPT above it matched first)
#   norule  - the private-range REJECT for the probed net is absent entirely
cat > "$BIN/iptables" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$STATE/reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE/reads"
case "${MODE:-moving}" in
  moving) c=$n ;;
  static) c=0 ;;
  norule) printf '%8s %8s %-10s %-4s %-3s %-6s %-6s %-20s %-20s\n' 0 0 ACCEPT all -- '*' '*' 0.0.0.0/0 0.0.0.0/0; exit 0 ;;
esac
printf '%8s %8s %-10s %-4s %-3s %-6s %-6s %-20s %-20s\n' "$c" 0 REJECT all -- '*' '*' 0.0.0.0/0 169.254.0.0/16
printf '%8s %8s %-10s %-4s %-3s %-6s %-6s %-20s %-20s\n' "$c" 0 REJECT all -- '*' '*' 0.0.0.0/0 10.0.0.0/8
EOF
chmod +x "$BIN/gosu" "$BIN/curl" "$BIN/iptables"

run() {  # run <MODE> -> output in $TMP_DIR/out, returns the helper's exit code
    rm -rf "$STATE"; mkdir -p "$STATE"
    set +e
    # Exported the way the container exports them, so a probe that fails to unset them is caught.
    STATE="$STATE" MODE="$1" PATH="$BIN:$PATH" \
        HTTP_PROXY=http://127.0.0.1:8888 HTTPS_PROXY=http://127.0.0.1:8888 \
        http_proxy=http://127.0.0.1:8888 https_proxy=http://127.0.0.1:8888 \
        bash "$HELPER" > "$TMP_DIR/out" 2>&1
    local rc=$?
    set -e
    return $rc
}

expect_rc() {  # expect_rc <mode> <wanted> <description>
    local rc=0
    run "$1" || rc=$?
    if [ "$rc" -ne "$2" ]; then
        cat "$TMP_DIR/out" >&2
        fail "$3: expected exit $2, got $rc"
    fi
    ok "$3"
}

# --- the decision itself -------------------------------------------------------------------------
expect_rc moving 0 'a counter that moves is a rule that matched: the probe passes'

expect_rc static 1 'a counter that does not move fails, which is the transposition signature'
grep -q 'did not hit the' "$TMP_DIR/out" || fail 'the failure does not say the packet missed the rule'
grep -q 'matched first' "$TMP_DIR/out" || fail 'the failure does not name the cause'
ok 'the failure names the cause rather than only reporting a bad exit'

expect_rc norule 1 'a missing private-range REJECT fails closed rather than passing vacuously'
grep -q 'no OUTPUT REJECT for' "$TMP_DIR/out" || fail 'the missing-rule failure does not name the rule'
ok 'the missing-rule failure names the rule it could not find'

# --- the identity actually used ------------------------------------------------------------------
run moving || true
grep -q '^gosu .*169.254.169.254' "$STATE/ran" \
    || fail 'the metadata probe did not run through gosu, so it did not use the proxy identity'
ok 'the order-sensitive probes run as the proxy user, not as root'
grep -q '^curl .*169.254.169.254' "$STATE/ran" \
    || fail 'the non-proxy probe did not run as the current identity'
ok 'a non-proxy identity is still exercised alongside the proxy one'

# --- the probe must not be routed through the proxy it is testing around ----------------------
run moving || true
if grep -q '^proxied-via ' "$STATE/ran"; then
    grep '^proxied-via ' "$STATE/ran" >&2
    fail 'a probe inherited the container proxy variables, so it never addressed the range under test'
fi
ok 'probes unset the container proxy variables, so the packet reaches the range being probed'

# --- wiring: one helper, both stacks, installed in the image --------------------------------------
for f in entrypoint.sh mitm/entrypoint.sh; do
    grep -q '/usr/local/bin/verify-egress-binding' "$ROOT/$f" \
        || fail "$f does not run the egress-binding self-test"
done
ok 'both root entrypoints run the same helper, so the two stacks cannot drift on it'

grep -q 'COPY scripts/verify-egress-binding.sh /usr/local/bin/verify-egress-binding' "$ROOT/Dockerfile" \
    || fail 'the Dockerfile does not install the helper'
grep -q 'chmod +x .*verify-egress-binding\|verify-egress-binding' "$ROOT/Dockerfile" \
    || fail 'the Dockerfile does not make the helper executable'
ok 'the image installs the helper and makes it executable'

# A script the Dockerfile COPYs must also be re-included in .dockerignore, which excludes the whole
# scripts/ tree. Without the re-include the build fails outright with "not found" — caught here
# because the shell suites alone cannot see it, and only an actual build otherwise would.
grep -qx '!scripts/verify-egress-binding.sh' "$ROOT/.dockerignore" \
    || fail '.dockerignore does not re-include the helper, so the image build cannot COPY it'
ok '.dockerignore re-includes the helper, so the build context contains it'

printf '\n%d passed, 0 failed\n' "$PASSED"
