#!/usr/bin/env bash
# Live egress-binding self-test (issue #169). Installed as /usr/local/bin/verify-egress-binding and
# run by BOTH root entrypoints, so the default and mediation stacks cannot drift on it.
#
# The boot self-tests already probe the private-range and metadata constraints, but they do it as
# ROOT, and root is caught by the terminal catch-all REJECT under every ordering. So they report
# success whether or not the rule they are named after is the one that matched. The proxy user is
# the identity those rules actually constrain: it is the only user allowed to originate public
# traffic, so it is the only one for which "reject private ranges" is a live decision rather than a
# foregone one.
#
# A connection attempt is not evidence on its own. `curl` failing looks the same whether the
# firewall rejected the packet or nothing was listening, and 169.254.169.254 DOES answer on a cloud
# host - so a return code means different things on different machines. What is unambiguous is the
# rule's own packet counter: it increments only when that rule matched this packet. Measured against
# a live chain with the proxy accept on either side of the private-range rejects:
#
#   shipped   curl rc=7    169.254.0.0/16 REJECT packets 0 -> 1   (the rule matched)
#   hoisted   curl rc=28   169.254.0.0/16 REJECT packets 0 -> 0   (an ACCEPT matched first)
#
# Exit status: 0 when every probe's intended rule matched,
#              1 when a probe's rule did not match, or a rule it names is absent (fail closed).
set -uo pipefail

PROXY_USER=${EGRESS_BINDING_PROXY_USER:-tinyproxy}
QUIET=${SANDBOX_QUIET:-}
say() { [ -n "$QUIET" ] || echo "$@"; }

# Packets matched by the OUTPUT REJECT whose destination is exactly $1. Prints nothing when no such
# rule exists, which the caller treats as fatal rather than as zero.
reject_packets() {
    iptables -nvxL OUTPUT 2>/dev/null \
        | awk -v net="$1" '$3 == "REJECT" && $9 == net { print $1; exit }'
}

# probe <label> <rule-destination> <target-url> <identity>
#   identity "proxy"   -> run as $PROXY_USER, the user the rule constrains
#   identity "root"    -> run as the current user
# Requires the named rule to exist AND to have matched one more packet afterwards.
probe() {
    local label=$1 net=$2 url=$3 identity=$4 before after
    before=$(reject_packets "$net")
    if [ -z "$before" ]; then
        echo "ERROR: no OUTPUT REJECT for $net; $label cannot be verified" >&2
        return 1
    fi
    # The proxy variables MUST be unset. With them set, curl sends the request to the proxy on
    # loopback instead of to $url, so no packet is ever addressed to the range under test and the
    # rule's counter cannot move — the probe would report a violation that is purely its own doing.
    # (Observed exactly that on a live container before this was added.)
    if [ "$identity" = proxy ]; then
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy \
            gosu "$PROXY_USER" curl -s -o /dev/null --connect-timeout 3 "$url" >/dev/null 2>&1 || true
    else
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy \
            curl -s -o /dev/null --connect-timeout 3 "$url" >/dev/null 2>&1 || true
    fi
    after=$(reject_packets "$net")
    if [ "${after:-0}" -le "${before:-0}" ]; then
        echo "ERROR: $label — the packet did not hit the $net REJECT (counter ${before} -> ${after:-?})." >&2
        echo "       A rule above it matched first; the private-range boundary is not in force for" >&2
        echo "       this identity even though every rule is still present." >&2
        return 1
    fi
    say "  ok: $label hit the $net REJECT (${before} -> ${after})"
    return 0
}

failed=0

# The order-sensitive probes. These are the ones that fail when the proxy-UID ACCEPT is hoisted
# above the private/bogon REJECTs - the transposition that opens the proxy user's path to cloud
# metadata and to other containers while every existing check still reports success.
probe "proxy user -> cloud-metadata range"  169.254.0.0/16 http://169.254.169.254/  proxy || failed=1
probe "proxy user -> private 10/8 range"    10.0.0.0/8     http://10.255.255.254/   proxy || failed=1

# A non-proxy identity is caught by the terminal catch-all under every ordering, so this probe is
# NOT sensitive to that transposition and is deliberately not counted as covering it. It is kept
# because it does cover something else: that the private-range rules apply to every identity rather
# than only to the one allowed to egress.
probe "non-proxy identity -> cloud-metadata range" 169.254.0.0/16 http://169.254.169.254/ root || failed=1

if [ "$failed" -ne 0 ]; then
    echo "ERROR: egress binding self-test failed — refusing to start." >&2
    exit 1
fi
say "  ok: every egress constraint was exercised through the identity that binds it"
exit 0
