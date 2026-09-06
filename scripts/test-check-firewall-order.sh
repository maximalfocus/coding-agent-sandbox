#!/usr/bin/env bash
# scripts/check-firewall-order.sh asserts a property that is invisible in the rules themselves: the
# ORDER of the shipped OUTPUT chains. A check for an ordering is worth exactly what its negative
# controls are worth, because the shipped tree passes by construction - so every mutation below
# takes a real chain, makes one change a careless edit could make, and requires the check to fail.
#
# The transposition cases are the ones that matter most: they are the exact edit that was
# reproduced against a live container before this check existed, where the proxy user reached a
# neighbour on a private range while the boot self-test still reported success.
#
# The over-strictness cases matter for the opposite reason. The sidecar-agent chain deliberately
# places pinned accepts BEFORE its private-range rejects, and every chain has connection-tracking
# and loopback accepts there too. A check that failed those would be wrong about the product, so
# they are asserted to pass rather than merely left untested.
#
# Runs offline: no container, no network, no credential, no running stack.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-firewall-order.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); printf 'PASS: %s\n' "$*"; }

[ -x "$CHECK" ] || fail 'scripts/check-firewall-order.sh is missing or not executable'

# macOS ships bash 3.2. An associative array parses on 4+ and dies on the shell most users have.
if grep -Eq 'declare -A|local -A' "$CHECK"; then
    fail 'the check uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

DEFAULT_CHAIN=init-firewall.sh
AGENT_CHAIN=mitm/agent-entrypoint.sh
EGRESS_CHAIN=mitm/sidecar-entrypoint.sh

FIX="$TMP_DIR/tree"
reset_fixture() {
    rm -rf "$FIX"
    mkdir -p "$FIX/mitm"
    cp "$ROOT/$DEFAULT_CHAIN" "$FIX/$DEFAULT_CHAIN"
    cp "$ROOT/$AGENT_CHAIN"   "$FIX/$AGENT_CHAIN"
    cp "$ROOT/$EGRESS_CHAIN"  "$FIX/$EGRESS_CHAIN"
}

run() {  # run -> combined output in $TMP_DIR/out, returns the check's exit code
    set +e
    FIREWALL_ORDER_ROOT="$FIX" bash "$CHECK" > "$TMP_DIR/out" 2>&1
    local rc=$?
    set -e
    return $rc
}

expect_rc() {  # expect_rc <wanted> <description>
    local want=$1 desc=$2 rc=0
    run || rc=$?
    if [ "$rc" -ne "$want" ]; then
        printf '%s\n' "--- check output ---" >&2
        cat "$TMP_DIR/out" >&2
        fail "$desc: expected exit $want, got $rc"
    fi
    ok "$desc"
}

# Hoist the owner-wide proxy accept above the private/bogon reject loop: the transposition that
# opens the proxy user's path to private ranges while every rule is still present.
# The accept sits after the loop in the shipped chain, so this is deliberately two passes: a
# single pass cannot move a line backwards, and an awk that tried would silently DELETE the accept
# instead of hoisting it - a different mutation that this check is not making a claim about.
transpose_owner_accept() {  # transpose_owner_accept <file-in-fixture>
    local f="$FIX/$1" line
    line=$(grep -E '^iptables -A OUTPUT .*--uid-owner.* -j ACCEPT' "$f" | grep -v -- ' -o lo' | head -1)
    [ -n "$line" ] || fail "fixture assumption broken: no owner-wide accept in $1"
    grep -vxF "$line" "$f" > "$f.tmp"
    awk -v ins="$line" '/^for net in/ && !placed { print ins; placed = 1 } { print }' "$f.tmp" > "$f"
    rm -f "$f.tmp"
    grep -q "$(printf '%s' "$line" | cut -c1-40)" "$f" || fail "fixture broken: the accept was dropped, not hoisted, in $1"
}

# --- positive control ----------------------------------------------------------------------------
# Ordered first: if the shipped tree did not pass, every failure below would be meaningless.
reset_fixture
expect_rc 0 'the three shipped chains pass unchanged'

# The sidecar-agent chain is the over-strictness guard. Its pinned accepts, and every chain's
# conntrack and loopback accepts, sit before the private-range rejects on purpose.
reset_fixture
if ! grep -q 'ESTABLISHED,RELATED' "$FIX/$AGENT_CHAIN"; then
    fail 'fixture assumption broken: the sidecar-agent chain has no conntrack accept to exempt'
fi
if ! grep -Eq '^[[:space:]]*iptables -A OUTPUT -o "\$SIDECAR_IF".*--dport 8888 -j ACCEPT' "$FIX/$AGENT_CHAIN"; then
    fail 'fixture assumption broken: the sidecar-agent pinned pre-reject accept changed shape'
fi
expect_rc 0 'pinned, conntrack and loopback accepts before the rejects are accepted, not flagged'

# --- transposition: the demonstrated hole --------------------------------------------------------
reset_fixture
transpose_owner_accept "$DEFAULT_CHAIN"
expect_rc 1 'default chain: owner-wide accept hoisted above the private/bogon rejects fails'
grep -q 'owner-wide ACCEPT precedes' "$TMP_DIR/out" \
    || fail 'the transposition failure does not name the cause'
ok 'the transposition failure names the cause rather than only the file'

reset_fixture
transpose_owner_accept "$EGRESS_CHAIN"
expect_rc 1 'sidecar-egress chain: the same transposition fails'

# --- weakening a pinned pre-reject accept --------------------------------------------------------
# Each of these keeps the accept before the rejects, where it must be, and widens exactly one of
# the three things that make it narrow enough to be safe there.
reset_fixture
sed -i.bak 's/\(-d "\$SIDECAR_IP\/32"\) --dport 8888/\1/' "$FIX/$AGENT_CHAIN"
expect_rc 1 'pinned accept that loses its destination port fails'

reset_fixture
sed -i.bak 's|-d "\$SIDECAR_IP/32"|-d "$SIDECAR_NET/16"|' "$FIX/$AGENT_CHAIN"
expect_rc 1 'pinned accept widened from /32 to a whole subnet fails'

reset_fixture
sed -i.bak 's/-o "\$SIDECAR_IF" -p tcp -d "\$SIDECAR_IP\/32"/-p tcp -d "$SIDECAR_IP\/32"/' "$FIX/$AGENT_CHAIN"
expect_rc 1 'pinned accept that drops its interface pin fails'

# --- the chain's own closure ---------------------------------------------------------------------
reset_fixture
sed -i.bak 's/^iptables -P OUTPUT DROP$/iptables -P OUTPUT ACCEPT/' "$FIX/$DEFAULT_CHAIN"
expect_rc 1 'a chain whose policy is not DROP fails'

reset_fixture
# Drop the terminal catch-all only, leaving the rest of the chain intact.
awk '!(/^iptables -A OUTPUT -j REJECT/)' "$FIX/$DEFAULT_CHAIN" > "$FIX/$DEFAULT_CHAIN.new"
mv "$FIX/$DEFAULT_CHAIN.new" "$FIX/$DEFAULT_CHAIN"
expect_rc 1 'a chain whose last rule is not the catch-all REJECT fails'

reset_fixture
awk '!(/^[[:space:]]*iptables -A OUTPUT -d "\$net" -j REJECT/)' "$FIX/$DEFAULT_CHAIN" > "$FIX/$DEFAULT_CHAIN.new"
mv "$FIX/$DEFAULT_CHAIN.new" "$FIX/$DEFAULT_CHAIN"
expect_rc 1 'a chain with no private/bogon REJECT fails rather than passing vacuously'

# --- fail closed when the chain cannot be read ---------------------------------------------------
# Distinct from an ordering violation: the invariant was never evaluated, so this must not be
# reported as exit 1, and must never be exit 0.
reset_fixture
rm -f "$FIX/$EGRESS_CHAIN"
expect_rc 2 'a missing chain file exits 2, not 0 and not 1'

reset_fixture
: > "$FIX/$AGENT_CHAIN"
expect_rc 2 'a chain yielding no OUTPUT rules exits 2 rather than passing vacuously'

reset_fixture
# Every OUTPUT statement, appended or policy, at any indentation: the bogon reject is inside a
# loop body and so is indented, and a mutation that missed it would leave the chain readable and
# test a different path than the one named here.
sed -i.bak 's/^\([[:space:]]*\)iptables -\([PA]\) OUTPUT/\1# iptables -\2 OUTPUT/' "$FIX/$DEFAULT_CHAIN"
expect_rc 2 'a chain whose rules are all commented out exits 2 rather than passing vacuously'

printf '\n%d passed, 0 failed\n' "$PASSED"
