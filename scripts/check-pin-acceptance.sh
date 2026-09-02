#!/usr/bin/env bash
# Coverage and staleness check for the pin inventory in docs/pin-acceptance.md (issue #139).
#
# Moving a pin is a rebuild AND a revalidation. The second half is what goes missing: the pin moves,
# every automated check stays green, and verification that rested on the old component's runtime
# behaviour quietly stops being true of the shipped image. This check makes the mapping mandatory,
# so an unrecorded pin is a hard failure rather than a silent one.
#
# It reports, per pin, exactly one of:
#
#   PASS         the pin is where the inventory says it lives, its coupled literals agree with it,
#                and every check resting on it is one a repository check can re-run;
#   DRIFTED      a pin baked into the Dockerfile has no inventory row, a row's recorded pin is no
#                longer in the file it names, or a literal declared coupled to a pin no longer
#                matches that pin's current value;
#   UNEVALUATED  the pin is intact, but verification resting on it needs an operator, or a host
#                class this machine is not. Never reported as a pass.
#
# It makes no network connection, reads no credential, and starts no container.
#
# Usage:
#   scripts/check-pin-acceptance.sh                human-readable
#   scripts/check-pin-acceptance.sh --json         machine-readable
#   scripts/check-pin-acceptance.sh --arg NAME     resolve one Dockerfile ARG to its inventory row
#   scripts/check-pin-acceptance.sh --coupled NAME the literals that must move with that ARG
#
# --arg is what scripts/update-agent-clis.sh consults before it writes: it prints the row's
# verification, rerun class, and note as `verification<TAB>rerun<TAB>note`, or exits 3 when that ARG
# has no row at all. --coupled is the same idea for the OTHER half: it prints `file<TAB>literal` for
# each declared coupling, with `{pin}` still unrendered so the caller can render both the old and
# the new value, and prints nothing for a pin that has none. One parser, so the tool and the check
# can never disagree about either half.
#
# Exit status: 0 when every baked pin is mapped, every recorded pin is intact, and every coupled
#                literal matches its pin,
#              1 when at least one pin has drifted, is unmapped, or has a diverged coupled literal,
#              2 when the inventory itself is missing or malformed (fail closed),
#              3 for --arg/--coupled only, when the named ARG has no inventory row.
set -uo pipefail

ROOT=${PIN_ACCEPTANCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DOC=${PIN_ACCEPTANCE_DOC:-$ROOT/docs/pin-acceptance.md}
DOCKERFILE=${PIN_ACCEPTANCE_DOCKERFILE:-$ROOT/Dockerfile}
DOC_LABEL=docs/pin-acceptance.md

JSON=0
ARG_QUERY=
COUPLED_QUERY=
case "${1:-}" in
    --json) JSON=1 ;;
    --arg)  shift; [[ $# -gt 0 ]] || { printf 'usage: %s --arg NAME\n' "${0##*/}" >&2; exit 2; }
            ARG_QUERY=$1 ;;
    --coupled) shift; [[ $# -gt 0 ]] || { printf 'usage: %s --coupled NAME\n' "${0##*/}" >&2; exit 2; }
            COUPLED_QUERY=$1 ;;
    "") ;;
    *) printf 'usage: %s [--json | --arg NAME | --coupled NAME]\n' "${0##*/}" >&2; exit 2 ;;
esac

DRIFTED=0
UNEVALUATED=0
PASSED=0
RESULTS=()

die() { printf 'check-pin-acceptance: %s\n' "$*" >&2; exit 2; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

record() { # status id detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    case $1 in
        DRIFTED)     DRIFTED=$((DRIFTED + 1)) ;;
        UNEVALUATED) UNEVALUATED=$((UNEVALUATED + 1)) ;;
        PASS)        PASSED=$((PASSED + 1)) ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# --- enumerate the pins the image actually bakes ---------------------------
# Three shapes, each unambiguous. Build-platform args (TARGETOS/TARGETARCH) and the apt cache-buster
# pin nothing external and match none of them, so they need no row.
baked_pins() {
    awk '
        /^FROM .*@sha256:[0-9a-f]{64}/ { print $0; next }
        /^ARG [A-Z0-9_]+_(VERSION|SHA256_AMD64|SHA256_ARM64|SOURCE_COMMIT)=/ { print $0; next }
        match($0, /"[0-9a-f]{64}  [^"]+"/) {
            s = substr($0, RSTART + 1, 64); print s; next
        }
    ' "$DOCKERFILE"
}

# arg_of PIN -> the ARG name a pin literal declares, or empty when it is not an ARG line
arg_of() {
    case "$1" in
        ARG\ *) local rest=${1#ARG }; printf '%s' "${rest%%=*}" ;;
    esac
}

# --- read the inventory ----------------------------------------------------
[[ -f "$DOC" ]] || die "inventory is missing: $DOC"
[[ -f "$DOCKERFILE" ]] || die "Dockerfile is missing: $DOCKERFILE"

block=$(awk '
    /^```pin-acceptance$/ { inblock = 1; next }
    inblock && /^```/     { inblock = 0; next }
    inblock               { print }
' "$DOC")

[[ -n "$block" ]] || die "inventory has no pin-acceptance block: $DOC"

seen_ids=""
mapped_pins=""
records=0
ROWS=()

while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue

    # Count separators before splitting so a malformed record fails closed instead of silently
    # collapsing its trailing fields into the last variable.
    fields=${line//[^|]/}
    [[ ${#fields} -eq 6 ]] || die "record must have 7 |-separated fields, got $((${#fields} + 1)): $line"

    IFS='|' read -r id component files pin verification rerun note <<<"$line"
    id=$(trim "$id"); component=$(trim "$component"); files=$(trim "$files")
    pin=$(trim "$pin"); verification=$(trim "$verification"); rerun=$(trim "$rerun")
    note=$(trim "$note")

    [[ -n "$id" && -n "$component" && -n "$files" && -n "$pin" && -n "$verification" && -n "$rerun" && -n "$note" ]] \
        || die "record has an empty field: $line"
    case " $seen_ids " in
        *" $id "*) die "duplicate pin id: $id" ;;
    esac
    seen_ids="$seen_ids $id"
    records=$((records + 1))

    case "$rerun" in
        repo|host|operator|mixed|none) ;;
        *) die "record '$id' has an invalid rerun value '$rerun' (expected repo, host, operator, mixed or none)" ;;
    esac

    # "nothing depends on this" and "nobody looked" must not be indistinguishable.
    if [[ "$verification" == "none" ]]; then
        [[ "$rerun" == "none" ]] \
            || die "record '$id' has verification=none but rerun='$rerun' (expected none)"
        [[ "$note" != "-" ]] \
            || die "record '$id' has verification=none and must state in its note why nothing depends on it"
    else
        [[ "$rerun" != "none" ]] \
            || die "record '$id' lists verification but claims rerun=none"
        # rerun must agree with the checks actually listed, or the field is decoration.
        classes=""
        IFS=',' read -r -a checks <<<"$verification"
        for c in "${checks[@]}"; do
            c=$(trim "$c")
            [[ -n "$c" ]] || die "record '$id' has an empty verification entry"
            case "$c" in
                operator:*) cls=operator ;;
                host:*)     cls=host ;;
                *)          cls=repo ;;
            esac
            case " $classes " in *" $cls "*) ;; *) classes="$classes $cls" ;; esac
        done
        set -- $classes
        if [[ $# -eq 1 ]]; then expected=$1; else expected=mixed; fi
        [[ "$rerun" == "$expected" ]] \
            || die "record '$id' declares rerun=$rerun but its checks imply $expected"
    fi

    ROWS+=("$id"$'\t'"$files"$'\t'"$pin"$'\t'"$verification"$'\t'"$rerun"$'\t'"$note")
    mapped_pins="$mapped_pins"$'\n'"$pin"
done <<<"$block"

[[ $records -gt 0 ]] || die "inventory records no pins: $DOC"

# --- couplings: pins that are the same fact written in two files ------------
# `pin_value` is what {pin} renders to. An `ARG NAME=value` pin means `value`; any other pin shape
# is its own value, because there is nothing narrower to take.
pin_value() {
    case "$1" in
        ARG\ *) printf '%s' "${1#*=}" ;;
        *) printf '%s' "$1" ;;
    esac
}

pin_of_id() { # pin_of_id ID -> that row's pin literal
    local row id files pin rest
    for row in ${ROWS+"${ROWS[@]}"}; do
        IFS=$'\t' read -r id files pin rest <<<"$row"
        [[ "$id" == "$1" ]] || continue
        printf '%s' "$pin"
        return 0
    done
    return 1
}

COUPLINGS=()
coupling_block=$(awk '
    /^```pin-coupling$/ { inblock = 1; next }
    inblock && /^```/   { inblock = 0; next }
    inblock             { print }
' "$DOC")

while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue

    fields=${line//[^|]/}
    [[ ${#fields} -eq 2 ]] || die "coupling must have 3 |-separated fields, got $((${#fields} + 1)): $line"

    IFS='|' read -r c_pin c_file c_literal <<<"$line"
    c_pin=$(trim "$c_pin"); c_file=$(trim "$c_file"); c_literal=$(trim "$c_literal")
    [[ -n "$c_pin" && -n "$c_file" && -n "$c_literal" ]] || die "coupling has an empty field: $line"

    # Fail closed on a declaration that cannot be evaluated, rather than skipping it: a coupling
    # nobody can check is indistinguishable from one nobody wrote.
    pin_of_id "$c_pin" >/dev/null || die "coupling names pin '$c_pin', which has no row in $DOC_LABEL"
    [[ "$c_literal" == *'{pin}'* ]] \
        || die "coupling for '$c_pin' has no {pin} in its literal, so it tracks nothing: $c_literal"
    [[ -f "$ROOT/$c_file" ]] || die "coupling for '$c_pin' names a file that does not exist: $c_file"

    COUPLINGS+=("$c_pin"$'\t'"$c_file"$'\t'"$c_literal")
done <<<"$coupling_block"

# --- --arg: resolve one Dockerfile ARG to its row --------------------------
if [[ -n "$ARG_QUERY" ]]; then
    for row in ${ROWS+"${ROWS[@]}"}; do
        IFS=$'\t' read -r id files pin verification rerun note <<<"$row"
        [[ "$(arg_of "$pin")" == "$ARG_QUERY" ]] || continue
        printf '%s\t%s\t%s\n' "$verification" "$rerun" "$note"
        exit 0
    done
    printf 'check-pin-acceptance: ARG %s has no row in %s\n' "$ARG_QUERY" "$DOC_LABEL" >&2
    exit 3
fi

# --- --coupled: the literals that must move with one ARG -------------------
# Prints nothing and exits 0 for a pin with no coupling, so a caller can treat "no output" as
# "nothing else to move" without a second interface.
if [[ -n "$COUPLED_QUERY" ]]; then
    found_row=0
    for row in ${ROWS+"${ROWS[@]}"}; do
        IFS=$'\t' read -r id files pin verification rerun note <<<"$row"
        [[ "$(arg_of "$pin")" == "$COUPLED_QUERY" ]] || continue
        found_row=1
        for c in ${COUPLINGS+"${COUPLINGS[@]}"}; do
            IFS=$'\t' read -r c_pin c_file c_literal <<<"$c"
            [[ "$c_pin" == "$id" ]] || continue
            printf '%s\t%s\n' "$c_file" "$c_literal"
        done
    done
    [[ $found_row -eq 1 ]] && exit 0
    printf 'check-pin-acceptance: ARG %s has no row in %s\n' "$COUPLED_QUERY" "$DOC_LABEL" >&2
    exit 3
fi

# --- coverage: every baked pin must have a row -----------------------------
while IFS= read -r baked; do
    [[ -n "$baked" ]] || continue
    found=0
    while IFS= read -r mapped; do
        [[ "$mapped" == "$baked" ]] && { found=1; break; }
    done <<<"$mapped_pins"
    if [[ $found -eq 0 ]]; then
        label=$(arg_of "$baked"); [[ -n "$label" ]] || label=$baked
        record DRIFTED "unmapped:$label" "baked into Dockerfile with no row in $DOC_LABEL"
    fi
done <<<"$(baked_pins)"

# --- staleness: every recorded pin must still be where its row says --------
for row in ${ROWS+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id files pin verification rerun note <<<"$row"
    stale=""
    IFS=',' read -r -a paths <<<"$files"
    for rel in "${paths[@]}"; do
        rel=$(trim "$rel")
        [[ -n "$rel" ]] || continue
        if [[ ! -f "$ROOT/$rel" ]]; then
            stale="recorded file is missing: $rel"; break
        fi
        if ! grep -Fq -- "$pin" "$ROOT/$rel"; then
            stale="recorded pin is absent from $rel"; break
        fi
    done

    if [[ -n "$stale" ]]; then
        record DRIFTED "$id" "$stale"
    elif [[ "$verification" == "none" ]]; then
        record PASS "$id" "no runtime verification rests on it: $note"
    elif [[ "$rerun" == "repo" ]]; then
        record PASS "$id" "pin intact; ${verification//,/, } re-runnable here"
    else
        # Name only the part this checkout cannot produce. Listing the automated checks alongside
        # would read as if they too needed a person, which is the confusion this field exists to end.
        blocked=""
        IFS=',' read -r -a checks <<<"$verification"
        for c in "${checks[@]}"; do
            c=$(trim "$c")
            case "$c" in
                operator:*|host:*) blocked="${blocked:+$blocked, }$c" ;;
            esac
        done
        case "$rerun" in
            host) record UNEVALUATED "$id" "pin intact; needs another host class: $blocked" ;;
            *)    record UNEVALUATED "$id" "pin intact; not re-runnable here: $blocked" ;;
        esac
    fi
done

# --- couplings: the same fact in two files must still say the same thing ---
# Rendering from the pin's CURRENT value is what makes one assertion cover both directions. A
# coupled literal left behind and one moved alone are equally absent, so neither can pass.
for c in ${COUPLINGS+"${COUPLINGS[@]}"}; do
    IFS=$'\t' read -r c_pin c_file c_literal <<<"$c"
    pin_literal=$(pin_of_id "$c_pin")
    value=$(pin_value "$pin_literal")
    rendered=${c_literal//\{pin\}/$value}
    if grep -Fq -- "$rendered" "$ROOT/$c_file"; then
        record PASS "$c_pin+$c_file" "coupled literal agrees: $rendered"
    else
        record DRIFTED "$c_pin+$c_file" "$c_file does not carry '$rendered'; it must move with the pin"
    fi
done

# --- report ----------------------------------------------------------------
if [[ $JSON -eq 1 ]]; then
    printf '{\n  "inventory": "%s",\n  "checks": [\n' "$DOC_LABEL"
    first=1
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status id detail <<<"$line"
        [[ $first -eq 0 ]] && printf ',\n'
        first=0
        printf '    {"status": "%s", "pin": "%s", "detail": "%s"}' \
            "$status" "$(json_escape "$id")" "$(json_escape "$detail")"
    done
    printf '\n  ],\n  "passed": %d,\n  "drifted": %d,\n  "unevaluated": %d,\n  "pinDrift": %s\n}\n' \
        "$PASSED" "$DRIFTED" "$UNEVALUATED" \
        "$([[ $DRIFTED -gt 0 ]] && echo true || echo false)"
else
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status id detail <<<"$line"
        printf '%-11s %-26s %s\n' "$status" "$id" "$detail"
    done
    printf '\n%d mapped, %d not re-runnable here, %d drifted\n' "$PASSED" "$UNEVALUATED" "$DRIFTED"
    if [[ $DRIFTED -gt 0 ]]; then
        printf 'RESULT: a baked pin is unmapped, or a recorded pin has moved. Update %s.\n' "$DOC_LABEL"
    else
        printf 'RESULT: every baked pin is mapped and every recorded pin is intact.\n'
    fi
    if [[ $UNEVALUATED -gt 0 ]]; then
        printf 'NOTE:   %d pins carry verification this checkout cannot re-run; it was NOT re-run here.\n' \
            "$UNEVALUATED"
    fi
fi

[[ $DRIFTED -gt 0 ]] && exit 1
exit 0
