#!/usr/bin/env bash
# Rule-ORDER check for the shipped iptables OUTPUT chains (issue #167).
#
# The firewall's guarantees are a property of rule order, not just of the rules present. Moving one
# line changes what is reachable while every rule still exists. Nothing asserted that order: the
# boot self-test in entrypoint.sh probes the private-range, metadata and IPv6 constraints as ROOT,
# and root is caught by the terminal catch-all REJECT under every ordering, so it cannot observe a
# reordering that only affects the proxy user - the one identity those rules exist to constrain.
# sidecar-smoketest.sh asserts `-P OUTPUT DROP`, which is the chain's default rather than its order.
#
# Reproduced before this check existed: transpose the proxy-UID ACCEPT and the private/bogon REJECTs
# in init-firewall.sh and the proxy user reaches a neighbour container on a private range, while the
# boot self-test still reports success.
#
# There are three chains and they do NOT share one shape:
#
#   init-firewall.sh            default + standalone mediation  broad --uid-owner ACCEPT after rejects
#   mitm/agent-entrypoint.sh    sidecar agent                   pinned iface+/32+port ACCEPT before
#   mitm/sidecar-entrypoint.sh  sidecar egress                  broad --uid-owner ACCEPT after rejects
#
# The middle chain is deliberate: the sidecar and the nested daemon live on an RFC1918 network, so
# their accepts MUST precede the private-range rejects. A check written to the first chain's shape
# alone would fail that chain for being correct. So the invariant is stated over what an ACCEPT can
# admit rather than over its position alone:
#
#   1. the chain's policy is DROP;
#   2. its last OUTPUT rule is a catch-all REJECT (no match criteria);
#   3. an owner-wide ACCEPT - one selecting by uid alone, so any destination - follows every
#      private/bogon REJECT;
#   4. an ACCEPT placed BEFORE those rejects that could admit a NEW non-loopback flow pins one
#      directly attached interface, one /32 destination, and one destination port.
#
# Connection-tracking (ESTABLISHED,RELATED) and loopback-only accepts are exempt from (4): the first
# admits no new flow, and the second cannot leave the container. Every chain has both, so a check
# that did not exempt them would fail all three.
#
# Two boundaries are deliberate. A chain with no owner-wide ACCEPT at all satisfies (3) vacuously,
# because the sidecar-agent chain legitimately has none - so deleting the proxy's accept outright
# is not reported here. That is a functional regression rather than an ordering one, and the boot
# self-test catches it immediately: the proxy stops reaching the API. And the check reads the
# scripts that BUILD each chain, not a chain loaded in a kernel, so it cannot see a rule added at
# runtime by something other than these three files.
#
# This is a STATIC check: it reads the shipped scripts and starts no container, makes no network
# connection, reads no credential, and needs no running stack. That is deliberate - it must be able
# to run on a change that never boots the sandbox. Proving the live behaviour of these constraints
# through the selector that binds each one is a separate, complementary concern.
#
# Usage:
#   scripts/check-firewall-order.sh            human-readable
#   scripts/check-firewall-order.sh --quiet     only failures
#
# Exit status: 0 when every chain satisfies every rule above,
#              1 when at least one chain violates one,
#              2 when a chain file is missing or yields no OUTPUT rules (fail closed).
set -uo pipefail

ROOT=${FIREWALL_ORDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# label:path - bash 3.2 (macOS default) has no associative arrays, so this stays a plain list.
CHAINS='default-and-standalone-mediation:init-firewall.sh
sidecar-agent:mitm/agent-entrypoint.sh
sidecar-egress:mitm/sidecar-entrypoint.sh'

failures=0
structural=0
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }
# A chain this check cannot read at all is a different failure from a chain it read and found
# wrong: the invariant was never evaluated, so reporting it as an ordering violation would be a
# claim the check did not make. It exits 2 instead, and never 0.
fatal() { printf 'FAIL [%s] %s\n' "$1" "$2" >&2; structural=1; }

# Normalize a chain script into one iptables statement per line, in source order:
# join line continuations, drop comments, split compound `a; b` statements, and keep only
# statements that set or append the OUTPUT chain of the IPv4 table. ip6tables is a separate
# stack with its own contract and is deliberately not matched here.
extract_rules() {
    sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' \
    | tr ';' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g' \
    | grep -E '^iptables (-[A-Za-z] [A-Za-z]+ )*-[PA] OUTPUT( |$)'
}

# What a single ACCEPT can admit, which is what decides whether its position matters.
#   conntrack  - ESTABLISHED,RELATED: opens no new flow
#   loopback   - bound to `-o lo`: cannot leave the container
#   pinned     - one interface + one /32 destination + one destination port
#   owner-wide - selects by uid alone, so any destination
#   broad      - anything else that could admit a new non-loopback flow
classify_accept() {
    local r=$1
    case "$r" in *ESTABLISHED*) echo conntrack; return;; esac
    case "$r" in *" -o lo "*|*" -o lo") echo loopback; return;; esac
    if printf '%s' "$r" | grep -Eq ' -o "?\$?[A-Za-z_][A-Za-z0-9_]*"?( |$)' \
       && printf '%s' "$r" | grep -Eq ' -d "?[^" ]*/32"?( |$)' \
       && printf '%s' "$r" | grep -q ' --dport '; then
        echo pinned; return
    fi
    case "$r" in *--uid-owner*) echo owner-wide; return;; esac
    echo broad
}

# A private/bogon REJECT. All three chains express these as a `for net in ...` loop whose body
# rejects "$net", so the loop variable is the reliable marker rather than the literal ranges.
is_bogon_reject() {
    case "$1" in *'-d "$net"'*-j' 'REJECT*) return 0;; esac
    return 1
}

# The terminal catch-all: a REJECT with no match criteria at all, so it applies to everything the
# rules above did not settle.
is_catch_all_reject() {
    printf '%s' "$1" | grep -Eq '^iptables -A OUTPUT -j REJECT( --reject-with [a-z-]+)?$'
}

while IFS= read -r entry; do
    label=${entry%%:*}
    rel=${entry#*:}
    file="$ROOT/$rel"

    if [ ! -f "$file" ]; then
        fatal "$label" "$rel is missing"
        continue
    fi
    rules=$(extract_rules "$file")
    if [ -z "$rules" ]; then
        fatal "$label" "$rel yielded no OUTPUT rules; the parser or the chain changed shape"
        continue
    fi

    # (1) policy is DROP
    if printf '%s\n' "$rules" | grep -qx 'iptables -P OUTPUT DROP'; then
        say "  ok  [$label] policy is DROP"
    else
        bad "$label" "no 'iptables -P OUTPUT DROP'; the chain does not default closed"
    fi

    # (2) the last appended rule is a catch-all REJECT
    last=$(printf '%s\n' "$rules" | grep '^iptables -A OUTPUT' | tail -n 1)
    if is_catch_all_reject "$last"; then
        say "  ok  [$label] last rule is the catch-all REJECT"
    else
        bad "$label" "last OUTPUT rule is not a catch-all REJECT: $last"
    fi

    # (3) and (4) - walk the chain in order, tracking whether the bogon rejects have been passed.
    seen_bogon=0
    bogon_count=0
    while IFS= read -r rule; do
        case "$rule" in 'iptables -A OUTPUT'*) ;; *) continue;; esac
        if is_bogon_reject "$rule"; then
            seen_bogon=1
            bogon_count=$((bogon_count + 1))
            continue
        fi
        case "$rule" in *' -j ACCEPT'*) ;; *) continue;; esac
        kind=$(classify_accept "$rule")
        if [ "$seen_bogon" = 0 ]; then
            case "$kind" in
                conntrack|loopback|pinned) ;;
                owner-wide)
                    bad "$label" "owner-wide ACCEPT precedes the private/bogon REJECTs, so the proxy user reaches private ranges and cloud metadata: $rule" ;;
                *)
                    bad "$label" "ACCEPT before the private/bogon REJECTs is not pinned to one interface, one /32 and one port: $rule" ;;
            esac
        fi
    done <<EOF
$rules
EOF

    if [ "$bogon_count" -eq 0 ]; then
        bad "$label" "no private/bogon REJECT found; the chain cannot be ordered against one"
    else
        say "  ok  [$label] $bogon_count private/bogon REJECT(s), and every accept before them is exempt or pinned"
    fi
done <<EOF
$CHAINS
EOF

if [ "$structural" -ne 0 ]; then
    printf 'FAIL: firewall rule order — a chain could not be read; the invariant was not evaluated\n' >&2
    exit 2
fi
if [ "$failures" -eq 0 ]; then
    say "PASS: firewall rule order (3 chains)"
    exit 0
fi
printf 'FAIL: firewall rule order — %d violation(s)\n' "$failures" >&2
exit 1
