#!/usr/bin/env bash
# Roster coverage and residue check for docs/agent-roster.md (issue #149).
#
# The set of bundled agent CLIs used to be implicit — whatever the Dockerfile happened to install —
# while each agent's OTHER entries lived in eight further files. A removal that edits the build and
# stops there leaves an always-on egress host for a tool that is no longer installed, and nothing
# would notice. This check makes the roster explicit and derives it from the image build, so a
# withdrawal that leaves one grant standing is a failure rather than silent residue.
#
# It reports, per surface, exactly one of:
#
#   PASS     the surface names exactly the agents the roster does;
#   MISSING  a shipped agent has no entry on a surface it must appear on;
#   RESIDUE  a surface names an agent the roster does not ship.
#
# It makes no network connection, reads no credential, and starts no container.
#
# Usage:
#   scripts/check-agent-roster.sh            human-readable
#   scripts/check-agent-roster.sh --json     machine-readable
#
# Exit status: 0 when every surface agrees with the roster,
#              1 when a shipped agent is missing from a surface or a retired one has residue,
#              2 when the roster itself is missing or malformed (fail closed).
set -uo pipefail

ROOT=${AGENT_ROSTER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOC=${AGENT_ROSTER_DOC:-$ROOT/docs/agent-roster.md}
DOCKERFILE=$ROOT/Dockerfile
DOC_LABEL=docs/agent-roster.md

# Every stack's always-on allowlist. All three must agree with the roster; a grant that survives in
# only the mitm or sidecar variant is still a grant.
ALLOWLIST_FILES="entrypoint.sh mitm/entrypoint.sh mitm/sidecar-entrypoint.sh"
UPDATER_SH=scripts/update-agent-clis.sh
UPDATER_PS1=scripts/update-agent-clis.ps1
README=README.md

JSON=0
case "${1:-}" in
    --json) JSON=1 ;;
    "") ;;
    *) printf 'usage: %s [--json]\n' "${0##*/}" >&2; exit 2 ;;
esac

MISSING=0
RESIDUE=0
PASSED=0
RESULTS=()

die() { printf 'check-agent-roster: %s\n' "$*" >&2; exit 2; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

record() { # status surface detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    case $1 in
        MISSING) MISSING=$((MISSING + 1)) ;;
        RESIDUE) RESIDUE=$((RESIDUE + 1)) ;;
        PASS)    PASSED=$((PASSED + 1)) ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

in_list() { # in_list NEEDLE "space separated haystack"
    case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

block() { # block NAME -> the body of the named fenced block, comments and blanks stripped
    awk -v name="$1" '
        $0 == "```" name { inblock = 1; next }
        inblock && /^```/ { inblock = 0; next }
        inblock { print }
    ' "$DOC"
}

# The residue scan governs the SHIPPED product, so it reads what the repository would ship: tracked
# files AND untracked ones that are not ignored. Ignored files - the operator's .env, a scratch
# directory - are not grants and must not fail this check.
#
# The untracked half is not a nicety. Reading only `ls-files` meant the scan could not see the file
# being written right now, which is precisely when residue is introduced, so a regression could only
# be caught one commit after it was made. That is not hypothetical: it is how this check came to
# refuse its own negative-control fixtures on main (issue #152). Outside a git checkout (a fixture
# tree) every file below the root is in scope instead.
shipped_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files --cached --others --exclude-standard
    else
        (cd "$ROOT" && find . -type f -not -path './.git/*' | sed 's|^\./||')
    fi
}

scan_for() { # scan_for TOKEN -> repository-relative paths whose contents name it, case-insensitively
    printf '%s\n' "$FILES" | tr '\n' '\0' \
        | (cd "$ROOT" && xargs -0 grep -Fil -- "$1" 2>/dev/null)
    return 0
}

# --- read the roster -------------------------------------------------------
[[ -f "$DOC" ]] || die "roster is missing: $DOC"
[[ -f "$DOCKERFILE" ]] || die "Dockerfile is missing: $DOCKERFILE"

roster_block=$(block agent-roster)
[[ -n "$roster_block" ]] || die "roster has no agent-roster block: $DOC"

SHIPPED_IDS=""
RETIRED_IDS=""
ROWS=()
seen_ids=""

while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue

    fields=${line//[^|]/}
    [[ ${#fields} -eq 7 ]] || die "row must have 8 |-separated fields, got $((${#fields} + 1)): $line"

    IFS='|' read -r id name command arg domains bundle status note <<<"$line"
    id=$(trim "$id"); name=$(trim "$name"); command=$(trim "$command"); arg=$(trim "$arg")
    domains=$(trim "$domains"); bundle=$(trim "$bundle"); status=$(trim "$status"); note=$(trim "$note")

    [[ -n "$id" && -n "$name" && -n "$command" && -n "$arg" && -n "$domains" \
       && -n "$bundle" && -n "$status" && -n "$note" ]] || die "row has an empty field: $line"
    in_list "$id" "$seen_ids" && die "duplicate agent id: $id"
    seen_ids="$seen_ids $id"

    case "$status" in
        shipped) SHIPPED_IDS="$SHIPPED_IDS $id" ;;
        retired)
            [[ "$note" != "-" ]] || die "retired agent '$id' must state in its note when and how it was withdrawn"
            RETIRED_IDS="$RETIRED_IDS $id" ;;
        *) die "row '$id' has an invalid status '$status' (expected shipped or retired)" ;;
    esac

    ROWS+=("$id"$'\t'"$name"$'\t'"$command"$'\t'"$arg"$'\t'"$domains"$'\t'"$bundle"$'\t'"$status")
done <<<"$roster_block"

[[ -n "$SHIPPED_IDS" ]] || die "roster ships no agent: $DOC"

INFRA_DOMAINS=""
while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue
    fields=${line//[^|]/}
    [[ ${#fields} -eq 1 ]] || die "infrastructure row must have 2 |-separated fields: $line"
    IFS='|' read -r domain why <<<"$line"
    domain=$(trim "$domain"); why=$(trim "$why")
    [[ -n "$domain" && -n "$why" ]] || die "infrastructure row has an empty field: $line"
    INFRA_DOMAINS="$INFRA_DOMAINS $domain"
done <<<"$(block agent-roster-infrastructure)"

EXEMPT_PATHS=""
while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue
    fields=${line//[^|]/}
    [[ ${#fields} -eq 1 ]] || die "exempt row must have 2 |-separated fields: $line"
    IFS='|' read -r path why <<<"$line"
    path=$(trim "$path"); why=$(trim "$why")
    [[ -n "$path" && -n "$why" ]] || die "exempt row has an empty field: $line"
    EXEMPT_PATHS="$EXEMPT_PATHS $path"
done <<<"$(block agent-roster-exempt)"

# --- 1. the roster is the image build's, not this file's -------------------
# `# agent-cli: <id>` markers sit on the install each agent gets in the Dockerfile. Requiring the
# markers and the shipped rows to name the same set is what makes the roster derived rather than
# merely asserted: adding an install without a row, or a row without an install, fails here.
marker_ids=$(sed -n 's/^# agent-cli:[[:space:]]*\([a-z0-9-]*\)[[:space:]]*$/\1/p' "$DOCKERFILE")
markers=""
for m in $marker_ids; do
    in_list "$m" "$markers" && die "Dockerfile marks agent '$m' twice"
    markers="$markers $m"
done
[[ -n "$markers" ]] || die "Dockerfile carries no '# agent-cli:' marker; the roster cannot be derived"

for id in $SHIPPED_IDS; do
    in_list "$id" "$markers" \
        || record MISSING "Dockerfile" "roster ships '$id' but no '# agent-cli: $id' marker installs it"
done
for m in $markers; do
    in_list "$m" "$SHIPPED_IDS" \
        || record RESIDUE "Dockerfile" "'# agent-cli: $m' installs an agent the roster does not ship"
done
[[ $MISSING -eq 0 && $RESIDUE -eq 0 ]] && record PASS "Dockerfile" "roster derived from the build: ${markers# }"

# --- 2. every shipped agent's pin, bundled-CLI check, and pin-acceptance row
for row in ${ROWS+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id name command arg domains bundle status <<<"$row"
    [[ "$status" == shipped ]] || continue

    count=$(grep -c "^ARG $arg=" "$DOCKERFILE" 2>/dev/null || true)
    if [[ "$count" != "1" ]]; then
        record MISSING "Dockerfile" "'$id' declares ARG $arg but the Dockerfile has $count such lines"
    else
        record PASS "Dockerfile:$arg" "pinned once"
    fi

    if [[ "$bundle" != "-" ]]; then
        if [[ ! -f "$ROOT/scripts/$bundle" ]]; then
            record MISSING "scripts/$bundle" "'$id' names a bundled-CLI check that does not exist"
        elif grep -q "^[[:space:]]*$command --version" "$ROOT/scripts/$bundle"; then
            record PASS "scripts/$bundle:$id" "runs '$command --version' from the built image"
        else
            record MISSING "scripts/$bundle" "'$id' is shipped but '$command --version' is not run there"
        fi
    fi

    if PIN_ACCEPTANCE_ROOT="$ROOT" bash "$SCRIPT_DIR/check-pin-acceptance.sh" --arg "$arg" >/dev/null 2>&1; then
        record PASS "docs/pin-acceptance.md:$arg" "mapped"
    else
        record MISSING "docs/pin-acceptance.md" "'$id' pins $arg with no row, so its bump carries no recorded acceptance"
    fi
done

# --- 3. always-on hosts in every stack --------------------------------------
claimed=""
for row in ${ROWS+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id name command arg domains bundle status <<<"$row"
    [[ "$status" == shipped && "$domains" != "-" ]] || continue
    IFS=',' read -r -a ds <<<"$domains"
    for d in "${ds[@]}"; do claimed="$claimed $(trim "$d")"; done
done
for rel in $ALLOWLIST_FILES; do
    file=$ROOT/$rel
    [[ -f "$file" ]] || { record MISSING "$rel" "stack allowlist is missing"; continue; }
    entries=$(awk '
        BEGIN { inarr = 0 }
        {
            line = $0
            if (inarr == 0) {
                if (line !~ /BASE_DOMAINS=\(/) next
                sub(/^[^(]*\(/, "", line)
                inarr = 1
            }
            sub(/#.*/, "", line)
            if (index(line, ")") > 0) { sub(/\).*/, "", line); done = 1 } else { done = 0 }
            gsub(/"/, "", line)
            n = split(line, a, /[ \t]+/)
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            if (done) inarr = 0
        }
    ' "$file")
    [[ -n "$entries" ]] || { record MISSING "$rel" "no BASE_DOMAINS allowlist found"; continue; }
    bad=""
    for d in $entries; do
        in_list "$d" "$claimed" && continue
        in_list "$d" "$INFRA_DOMAINS" && continue
        bad="${bad:+$bad, }$d"
    done
    if [[ -n "$bad" ]]; then
        record RESIDUE "$rel" "always-on host claimed by no rostered agent: $bad"
    else
        record PASS "$rel" "every always-on host is claimed"
    fi
done

# --- 4. the host pin updaters, both shells ----------------------------------
sh_keys=$(sed -n 's/^KEYS="\(.*\)"$/\1/p' "$ROOT/$UPDATER_SH" | head -1)
ps_keys=$(sed -n 's/^[[:space:]]*@{ Name = "\([a-z0-9-]*\)".*/\1/p' "$ROOT/$UPDATER_PS1" | tr '\n' ' ')
for label in "$UPDATER_SH:$sh_keys" "$UPDATER_PS1:$ps_keys"; do
    rel=${label%%:*}
    keys=${label#*:}
    if [[ -z "$(trim "$keys")" ]]; then
        record MISSING "$rel" "no agent list found, so the roster cannot be compared against it"
        continue
    fi
    problem=""
    for id in $SHIPPED_IDS; do
        in_list "$id" "$keys" || problem="${problem:+$problem; }missing '$id'"
    done
    for k in $keys; do
        in_list "$k" "$SHIPPED_IDS" || problem="${problem:+$problem; }offers '$k', which the roster does not ship"
    done
    if [[ -z "$problem" ]]; then
        record PASS "$rel" "offers exactly the shipped roster"
    elif [[ "$problem" == *"does not ship"* ]]; then
        record RESIDUE "$rel" "$problem"
    else
        record MISSING "$rel" "$problem"
    fi
done

# --- 5. operator documentation ----------------------------------------------
for row in ${ROWS+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id name command arg domains bundle status <<<"$row"
    [[ "$status" == shipped ]] || continue
    if grep -Fq -- "$name" "$ROOT/$README"; then
        record PASS "$README:$id" "documented"
    else
        record MISSING "$README" "'$name' is shipped but never named, so an operator cannot know it is there"
    fi
done

# --- 6. residue: nothing may still name a retired agent ---------------------
# The forward checks above catch a surface that ENUMERATES its agents. Prose does not enumerate, so
# a retired agent's own tokens are what the scan looks for — which is why a retired row keeps them.
FILES=$(shipped_files)
[[ -n "$FILES" ]] || die "no files to scan below $ROOT"

for row in ${ROWS+"${ROWS[@]}"}; do
    IFS=$'\t' read -r id name command arg domains bundle status <<<"$row"
    [[ "$status" == retired ]] || continue

    tokens="$id"
    for extra in "$name" "$command" "$arg"; do
        [[ "$extra" == "-" ]] && continue
        low=$(lower "$extra")
        in_list "$low" "$(lower "$tokens")" || tokens="$tokens $extra"
    done
    if [[ "$domains" != "-" ]]; then
        IFS=',' read -r -a ds <<<"$domains"
        for d in "${ds[@]}"; do tokens="$tokens $(trim "$d")"; done
    fi

    hits=""
    for token in $tokens; do
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            in_list "$rel" "$EXEMPT_PATHS" && continue
            in_list "$rel" "$hits" && continue
            hits="$hits $rel"
        done <<<"$(scan_for "$token")"
    done

    if [[ -n "$hits" ]]; then
        record RESIDUE "$DOC_LABEL:$id" "retired agent still named in:${hits}"
    else
        record PASS "$DOC_LABEL:$id" "retired, and no shipped surface still names it"
    fi
done

# --- report ----------------------------------------------------------------
if [[ $JSON -eq 1 ]]; then
    printf '{\n  "roster": "%s",\n  "checks": [\n' "$DOC_LABEL"
    first=1
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status surface detail <<<"$line"
        [[ $first -eq 0 ]] && printf ',\n'
        first=0
        printf '    {"status": "%s", "surface": "%s", "detail": "%s"}' \
            "$status" "$(json_escape "$surface")" "$(json_escape "$detail")"
    done
    printf '\n  ],\n  "passed": %d,\n  "missing": %d,\n  "residue": %d,\n  "rosterDrift": %s\n}\n' \
        "$PASSED" "$MISSING" "$RESIDUE" \
        "$([[ $((MISSING + RESIDUE)) -gt 0 ]] && echo true || echo false)"
else
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status surface detail <<<"$line"
        printf '%-8s %-34s %s\n' "$status" "$surface" "$detail"
    done
    printf '\n%d agreed, %d missing, %d residue\n' "$PASSED" "$MISSING" "$RESIDUE"
    if [[ $RESIDUE -gt 0 ]]; then
        printf 'RESULT: a surface still names an agent the roster does not ship. Withdraw it, or add it to %s.\n' "$DOC_LABEL"
    elif [[ $MISSING -gt 0 ]]; then
        printf 'RESULT: a shipped agent is absent from a surface it must appear on. Update %s or that surface.\n' "$DOC_LABEL"
    else
        printf 'RESULT: every surface names exactly the agents the roster ships.\n'
    fi
fi

[[ $((MISSING + RESIDUE)) -gt 0 ]] && exit 1
exit 0
