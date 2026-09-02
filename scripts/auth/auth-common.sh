#!/usr/bin/env bash
# Shared guard and custody disclosure for the host-side sign-in commands (issue #151, CAS-R034).
#
# Sourced, never executed. Before this existed each sign-in helper hand-rolled its own "is the stack
# running" and "is the gate on" checks, worded its refusals differently, and said nothing at all
# about where the credential it just created ends up. Three helpers, three shapes, and an operator
# left to infer the custody tier from the Compose file.
#
# The tier is NOT restated here. It is read from docs/credential-custody.md, which
# scripts/check-credential-custody.sh proves against the shipped Compose wiring — so a command
# cannot claim a tier the configuration does not implement.
#
# Nothing here moves a credential between tiers, weakens a tier, or grants egress. A refusal is a
# refusal: it never enters the underlying login flow.

AUTH_ROOT=${AUTH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
AUTH_CUSTODY_DOC=${AUTH_CUSTODY_DOC:-$AUTH_ROOT/docs/credential-custody.md}
AUTH_SERVICE=${AUTH_SERVICE:-claude-sandbox}

auth_die() { printf 'REFUSING: %s\n' "$1" >&2; shift; for line in "$@"; do printf '  %s\n' "$line" >&2; done; exit 1; }

auth_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# auth_row ID -> the row's fields, tab-separated, or a hard failure. The table is the single source
# of truth for every command, so an id with no row is a broken install rather than a default.
auth_row() {
    local want=$1 line id tool command gate volume path tier isolation note
    [ -r "$AUTH_CUSTODY_DOC" ] || auth_die "the credential custody table is missing." \
        "expected: $AUTH_CUSTODY_DOC"
    while IFS= read -r line; do
        line=$(auth_trim "$line")
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r id tool command gate volume path tier isolation note <<EOF
$line
EOF
        [ "$(auth_trim "$id")" = "$want" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(auth_trim "$tool")" "$(auth_trim "$command")" "$(auth_trim "$gate")" \
            "$(auth_trim "$volume")" "$(auth_trim "$path")" "$(auth_trim "$tier")" \
            "$(auth_trim "$isolation")" "$(auth_trim "$note")"
        return 0
    done < <(awk '/^```credential-custody$/{f=1;next} f&&/^```/{f=0} f' "$AUTH_CUSTODY_DOC")
    auth_die "no custody row for '$want' in docs/credential-custody.md." \
        "A sign-in command must not run without one: the operator would not be told where the credential lands."
}

# auth_require_stack -> refuse by name when the sandbox is not up, rather than letting the exec fail.
auth_require_stack() {
    if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
        auth_die "the sandbox is not running, so there is nothing to sign in to." \
            "Start it first:  ./run.sh"
    fi
}

# auth_require_gate ID -> refuse by name when the capability gate this tool's provider needs is off.
# Without this the login starts and dies several steps later as a proxy 403, which reads as a
# provider or network fault rather than as a switch the operator never turned on.
auth_require_gate() {
    local gate probe name
    gate=$(printf '%s' "$1" | cut -f3)
    [ "$gate" = "-" ] && return 0
    name=${gate%%:*}
    probe=${gate#*:}
    [ "$probe" = "-" ] && return 0
    if ! docker compose exec -T "$AUTH_SERVICE" grep -qi -- "$probe" /etc/tinyproxy/filter 2>/dev/null; then
        auth_die "$name is off, so this sign-in would be refused by the egress proxy partway through." \
            "Set $name=true in .env, run ./run.sh, then run this again."
    fi
}

# auth_disclose ID -> say where the credential lands and who can read it. Printed on the success
# path, after the flow returns, because that is when the operator has actually created one.
auth_disclose() {
    local row tool command gate volume path tier isolation note tier_text
    row=$1
    tool=$(printf '%s' "$row" | cut -f1)
    volume=$(printf '%s' "$row" | cut -f4)
    path=$(printf '%s' "$row" | cut -f5)
    tier=$(printf '%s' "$row" | cut -f6)
    isolation=$(printf '%s' "$row" | cut -f7)
    note=$(printf '%s' "$row" | cut -f8)
    case "$tier" in
        agent-readable) tier_text="agent-readable container volume" ;;
        proxy-vault)    tier_text="proxy-owned same-container vault" ;;
        sidecar-owned)  tier_text="sidecar-owned store" ;;
        none)           tier_text="no credential" ;;
        *)              auth_die "unknown custody tier '$tier' for $tool." "Fix docs/credential-custody.md." ;;
    esac
    printf '\n'
    printf 'Credential custody for %s\n' "$tool"
    printf '  location   %s' "$path"
    [ "$volume" = "-" ] || printf '  (volume %s)' "$volume"
    printf '\n'
    printf '  tier       %s\n' "$tier_text"
    if [ "$tier" = "agent-readable" ]; then
        printf '             Any process running as the agent user can read this credential.\n'
    fi
    printf '  isolation  %s\n' "$isolation"
    printf '  %s\n' "$note"
    printf '\n'
    printf 'Recorded in docs/credential-custody.md; this command changed no tier.\n'
}
