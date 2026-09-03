#!/usr/bin/env bash
# Keep the shipped surface free of references to private companion material (issue #165).
#
# This repository has a private companion holding its requirements and delivery record. Naming it
# means a public reader meets a pointer to something they cannot open - a dangling reference on its
# own terms, before any question of what it discloses.
#
# It scans TRACKED FILES ONLY, and that limit is the point rather than an omission: the references
# this cannot reach are commit messages and pull-request text, which the provider retains
# permanently. Nothing in a repository check can purge those. This stops the file half from
# regressing; it is not a publication clearance and must not be reported as one.
#
# WHY THE TERMS ARE ENCODED. A guard that writes a forbidden term in order to forbid it becomes an
# instance of the thing it forbids the moment it is merged, and then sits in a retained pull-request
# ref permanently. So the terms live here as hex and are decoded at run time. The publication
# scanner does the same to its own denylist. scripts/test-check-public-surface.sh asserts this file
# carries none of them in the clear, so the property is proved rather than intended.
#
# Usage:
#   scripts/check-public-surface.sh            human-readable
#   scripts/check-public-surface.sh --json     machine-readable
#
# Exit status: 0 when no tracked file names private companion material,
#              1 when at least one does,
#              2 when the scan could not run (fail closed).
set -uo pipefail

ROOT=${PUBLIC_SURFACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

JSON=0
case "${1:-}" in
    --json) JSON=1 ;;
    "") ;;
    *) printf 'usage: %s [--json]\n' "${0##*/}" >&2; exit 2 ;;
esac

# label:hex - decoded at run time, never written in the clear.
ENCODED=(
    "companion-repo:636f64696e672d6167656e742d73616e64626f782d707264"
    "companion-doc:505244"
    "companion-tracker:50524f47524553532e6d64"
)

decode() {
    local hex=$1 out=""
    while [ -n "$hex" ]; do
        out+="\x${hex:0:2}"
        hex=${hex:2}
    done
    printf '%b' "$out"
}

# This file is its own exemption: it necessarily carries the encoded forms, and its test proves it
# carries nothing in the clear. The test is exempt for the same reason.
SELF=scripts/check-public-surface.sh
SELF_TEST=scripts/test-check-public-surface.sh

files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files --cached --others --exclude-standard
    else
        (cd "$ROOT" && find . -type f -not -path './.git/*' | sed 's|^\./||')
    fi
}

FILES=$(files)
[ -n "$FILES" ] || { printf 'check-public-surface: nothing to scan below %s\n' "$ROOT" >&2; exit 2; }

hits=0
results=()
for entry in "${ENCODED[@]}"; do
    label=${entry%%:*}
    term=$(decode "${entry#*:}")
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ "$rel" = "$SELF" ] && continue
        [ "$rel" = "$SELF_TEST" ] && continue
        line=$(cd "$ROOT" && grep -n -m1 -F -- "$term" "$rel" 2>/dev/null | cut -d: -f1)
        results+=("$rel"$'\t'"$label"$'\t'"${line:-0}")
        hits=$((hits + 1))
    done <<<"$(cd "$ROOT" && printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -lF -- "$term" 2>/dev/null)"
done

if [ "$JSON" -eq 1 ]; then
    printf '{\n  "scope": "tracked files only; commit and pull-request text are out of reach",\n  "hits": [\n'
    first=1
    for line in ${results+"${results[@]}"}; do
        IFS=$'\t' read -r rel label num <<<"$line"
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        printf '    {"file": "%s", "term": "%s", "line": %s}' "$rel" "$label" "$num"
    done
    printf '\n  ],\n  "clean": %s\n}\n' "$([ "$hits" -eq 0 ] && echo true || echo false)"
else
    for line in ${results+"${results[@]}"}; do
        IFS=$'\t' read -r rel label num <<<"$line"
        printf 'NAMES-PRIVATE  %s:%s  (%s)\n' "$rel" "$num" "$label"
    done
    if [ "$hits" -eq 0 ]; then
        printf 'RESULT: no tracked file names private companion material.\n'
        printf 'NOTE:   commit and pull-request text are NOT covered and cannot be; the provider retains them.\n'
    else
        printf '\n%d tracked file reference(s). Name the property, not the private document.\n' "$hits"
    fi
fi

[ "$hits" -gt 0 ] && exit 1
exit 0
