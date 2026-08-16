#!/usr/bin/env bash
# Credential-free drift check for the provider contracts recorded in docs/provider-contracts.md
# (issue #68, SL-18 / CAS-R170, CAS-R171).
#
# Every credential path in this repository depends on an endpoint, grant shape, identifier, injection
# destination, header contract, or credential-file schema that somebody else controls. This check
# reports, per recorded dependency, exactly one of:
#
#   PASS         the pinned literal is still where the inventory says it lives, and nothing outside
#                this repository is needed to confirm it;
#   DRIFTED      the literal is gone, or the value is recorded as one the provider stopped accepting;
#   UNEVALUATED  the in-repository half is intact but provider-side agreement needs a live call that
#                this check deliberately does not make.
#
# It makes no network connection, reads no credential, needs no provider subscription, and prints no
# credential material. It never reports PASS for something it did not evaluate.
#
# Usage:
#   scripts/check-provider-contracts.sh          human-readable
#   scripts/check-provider-contracts.sh --json   machine-readable
#
# Exit status: 0 when nothing recorded is contradicted (UNEVALUATED rows included),
#              1 when at least one dependency has drifted,
#              2 when the inventory itself is missing or malformed (fail closed).
set -uo pipefail

ROOT=${PROVIDER_CONTRACTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DOC=${PROVIDER_CONTRACTS_DOC:-$ROOT/docs/provider-contracts.md}
DOC_LABEL=docs/provider-contracts.md

JSON=0
case "${1:-}" in
    --json) JSON=1 ;;
    "") ;;
    *) printf 'usage: %s [--json]\n' "${0##*/}" >&2; exit 2 ;;
esac

DRIFTED=0
UNEVALUATED=0
PASSED=0
RESULTS=()

die() { printf 'check-provider-contracts: %s\n' "$*" >&2; exit 2; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

record() { # status id detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    case $1 in
        DRIFTED) DRIFTED=$((DRIFTED + 1)) ;;
        UNEVALUATED) UNEVALUATED=$((UNEVALUATED + 1)) ;;
        PASS) PASSED=$((PASSED + 1)) ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

emit() {
    if [[ $JSON -eq 1 ]]; then
        printf '{\n  "inventory": "%s",\n  "checks": [\n' "$DOC_LABEL"
        local first=1 line status id detail
        for line in ${RESULTS+"${RESULTS[@]}"}; do
            IFS=$'\t' read -r status id detail <<<"$line"
            [[ $first -eq 0 ]] && printf ',\n'
            first=0
            printf '    {"status": "%s", "dependency": "%s", "detail": "%s"}' \
                "$status" "$(json_escape "$id")" "$(json_escape "$detail")"
        done
        printf '\n  ],\n  "passed": %d,\n  "drifted": %d,\n  "unevaluated": %d,\n  "contractDrift": %s\n}\n' \
            "$PASSED" "$DRIFTED" "$UNEVALUATED" \
            "$([[ $DRIFTED -gt 0 ]] && echo true || echo false)"
    else
        local line status id detail
        for line in ${RESULTS+"${RESULTS[@]}"}; do
            IFS=$'\t' read -r status id detail <<<"$line"
            printf '%-11s %-30s %s\n' "$status" "$id" "$detail"
        done
        printf '\n%d pinned, %d unevaluated, %d drifted\n' "$PASSED" "$UNEVALUATED" "$DRIFTED"
        if [[ $DRIFTED -gt 0 ]]; then
            printf 'RESULT: a recorded provider contract has DRIFTED — the dependent capability is unavailable.\n'
            printf '        See %s; re-pinning is a CAS-R174 decision.\n' "$DOC_LABEL"
        else
            printf 'RESULT: no recorded provider contract is contradicted.\n'
        fi
        if [[ $UNEVALUATED -gt 0 ]]; then
            printf 'NOTE:   %d dependencies need a live provider call to confirm and were NOT confirmed here.\n' \
                "$UNEVALUATED"
        fi
    fi
}

# --- read the inventory ----------------------------------------------------
[[ -f "$DOC" ]] || die "inventory is missing: $DOC"

block=$(awk '
    /^```contract-pins$/ { inblock = 1; next }
    inblock && /^```/    { inblock = 0; next }
    inblock              { print }
' "$DOC")

[[ -n "$block" ]] || die "inventory has no contract-pins block: $DOC"

seen_ids=""
records=0

while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue

    # Count the separators before splitting: a record with the wrong shape must fail closed rather
    # than silently losing its trailing fields to the last variable.
    fields=${line//[^|]/}
    [[ ${#fields} -eq 6 ]] || die "record must have 7 |-separated fields, got $((${#fields} + 1)): $line"

    IFS='|' read -r id provider surface files pin live observed <<<"$line"
    id=$(trim "$id"); provider=$(trim "$provider"); surface=$(trim "$surface")
    files=$(trim "$files"); pin=$(trim "$pin"); live=$(trim "$live"); observed=$(trim "$observed")

    [[ -n "$id" && -n "$provider" && -n "$surface" && -n "$files" && -n "$pin" ]] \
        || die "record has an empty required field: $line"
    case " $seen_ids " in
        *" $id "*) die "duplicate dependency id: $id" ;;
    esac
    seen_ids="$seen_ids $id"
    records=$((records + 1))

    case "$live" in
        na|required) ;;
        *) die "record '$id' has an invalid live value '$live' (expected na or required)" ;;
    esac
    case "$observed" in
        -|drifted:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) die "record '$id' has an invalid observed value '$observed' (expected - or drifted:YYYY-MM-DD)" ;;
    esac
    # A dependency with no in-tree literal cannot be confirmed by this repository alone, so it must
    # not be able to claim the offline-sufficient status that would report it as PASS.
    if [[ "$files" == "-" && "$live" == "na" ]]; then
        die "record '$id' has no files to check but claims live=na; it could never be evaluated"
    fi

    # --- repository half: is the pinned literal still where the inventory says it lives? ---
    structural_detail=""
    if [[ "$files" != "-" ]]; then
        IFS=',' read -r -a paths <<<"$files"
        for rel in "${paths[@]}"; do
            rel=$(trim "$rel")
            [[ -n "$rel" ]] || continue
            if [[ ! -f "$ROOT/$rel" ]]; then
                structural_detail="recorded file is missing: $rel"
                break
            fi
            if ! grep -Fq -- "$pin" "$ROOT/$rel"; then
                structural_detail="pinned value is absent from $rel"
                break
            fi
        done
    fi

    if [[ -n "$structural_detail" ]]; then
        record DRIFTED "$id" "$structural_detail"
        continue
    fi

    # --- provider half ---
    if [[ "$observed" == drifted:* ]]; then
        record DRIFTED "$id" "provider rejected this value on ${observed#drifted:} (source unchanged)"
    elif [[ "$live" == "required" ]]; then
        if [[ "$files" == "-" ]]; then
            record UNEVALUATED "$id" "asserted contract with no in-tree literal; needs a live $provider run"
        else
            record UNEVALUATED "$id" "pin intact in ${files//,/, }; provider agreement needs a live call"
        fi
    else
        record PASS "$id" "pin intact in ${files//,/, }"
    fi
done <<<"$block"

[[ $records -gt 0 ]] || die "inventory records no dependencies: $DOC"

emit
[[ $DRIFTED -gt 0 ]] && exit 1
exit 0
