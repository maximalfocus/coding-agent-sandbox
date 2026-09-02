#!/usr/bin/env bash
# Coverage and truthfulness check for the custody table in docs/credential-custody.md (issue #151).
#
# Two failures this exists to refuse:
#
#   1. An agent the image ships with no custody row, so nothing tells the operator which tier holds
#      its credential — or a sign-in command that exists in one host shell and not the other, so
#      half the operators have no host-side path at all.
#   2. A row that CLAIMS a tier the shipped Compose wiring does not implement. A credential volume
#      mounted into an agent service is agent-readable no matter what a table says, and a table that
#      can drift from the configuration is worse than no table: it is a reassurance with nothing
#      behind it.
#
# The second is the reason this reads the compose files rather than trusting the document. The roster
# check (scripts/check-agent-roster.sh) is the sibling that keeps the AGENT set honest; this one
# keeps the CUSTODY claim honest, and the two are joined by requiring a row for every rostered agent.
#
# It reports, per row, exactly one of:
#
#   PASS      the row agrees with the shipped configuration and its commands exist in both shells;
#   MISSING   a rostered agent has no row, or a command is absent from a supported shell;
#   MISMATCH  the stated tier, volume, or path contradicts the compose wiring.
#
# It makes no network connection, reads no credential, and starts no container.
#
# Usage:
#   scripts/check-credential-custody.sh            human-readable
#   scripts/check-credential-custody.sh --json     machine-readable
#
# Exit status: 0 when every row agrees, 1 when any row is missing or mismatched,
#              2 when the table itself is missing or malformed (fail closed).
set -uo pipefail

ROOT=${CREDENTIAL_CUSTODY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DOC=${CREDENTIAL_CUSTODY_DOC:-$ROOT/docs/credential-custody.md}
ROSTER=${CREDENTIAL_CUSTODY_ROSTER:-$ROOT/docs/agent-roster.md}
DOC_LABEL=docs/credential-custody.md

JSON=0
case "${1:-}" in
    --json) JSON=1 ;;
    "") ;;
    *) printf 'usage: %s [--json]\n' "${0##*/}" >&2; exit 2 ;;
esac

MISSING=0
MISMATCH=0
PASSED=0
RESULTS=()

die() { printf 'check-credential-custody: %s\n' "$*" >&2; exit 2; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

record() { # status subject detail
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3")
    case $1 in
        MISSING)  MISSING=$((MISSING + 1)) ;;
        MISMATCH) MISMATCH=$((MISMATCH + 1)) ;;
        PASS)     PASSED=$((PASSED + 1)) ;;
    esac
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

block() { # block FILE NAME
    awk -v name="$2" '
        $0 == "```" name { inblock = 1; next }
        inblock && /^```/ { inblock = 0; next }
        inblock { print }
    ' "$1"
}

# mounts_of FILE SERVICE -> "<volume>:<path>" for every named-volume mount that service declares.
# The compose files are parsed directly rather than through `docker compose config` so this needs no
# Docker, no .env, and no interpolation — the same choice scripts/test-variant-isolation.sh makes.
mounts_of() {
    awk -v want="$2" '
        /^services:/ { insvc = 1; next }
        /^[a-z]/ && !/^services:/ { insvc = 0; cur = ""; invol = 0; next }
        insvc && /^  [a-zA-Z0-9_-]+:/ {
            cur = $1; sub(/:$/, "", cur); invol = 0; next
        }
        insvc && cur == want && /^    volumes:/ { invol = 1; next }
        insvc && cur == want && invol && /^    [a-zA-Z]/ { invol = 0 }
        insvc && cur == want && invol && /^ *- / {
            line = $0
            sub(/^ *- */, "", line)
            gsub(/"/, "", line)
            n = split(line, a, ":")
            if (n >= 2 && a[1] !~ /^[.$\/]/) print a[1] ":" a[2]
        }
    ' "$1"
}

[[ -f "$DOC" ]] || die "custody table is missing: $DOC"
[[ -f "$ROSTER" ]] || die "agent roster is missing: $ROSTER"

# --- read the custody table -------------------------------------------------
rows_block=$(block "$DOC" credential-custody)
[[ -n "$rows_block" ]] || die "table has no credential-custody block: $DOC"

ROWS=()
IDS=""
while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue
    fields=${line//[^|]/}
    [[ ${#fields} -eq 8 ]] || die "row must have 9 |-separated fields, got $((${#fields} + 1)): $line"
    IFS='|' read -r id tool command gate volume path tier isolation note <<<"$line"
    id=$(trim "$id"); tool=$(trim "$tool"); command=$(trim "$command"); gate=$(trim "$gate")
    volume=$(trim "$volume"); path=$(trim "$path"); tier=$(trim "$tier")
    isolation=$(trim "$isolation"); note=$(trim "$note")
    [[ -n "$id" && -n "$tool" && -n "$command" && -n "$gate" && -n "$volume" && -n "$path" \
       && -n "$tier" && -n "$isolation" && -n "$note" ]] || die "row has an empty field: $line"
    in_list "$id" "$IDS" && die "duplicate custody id: $id"
    IDS="$IDS $id"
    case "$tier" in
        agent-readable|proxy-vault|sidecar-owned|none) ;;
        *) die "row '$id' has an unknown tier '$tier' (expected agent-readable, proxy-vault, sidecar-owned or none)" ;;
    esac
    case "$isolation" in
        applied|available|unavailable|na) ;;
        *) die "row '$id' has an unknown isolation '$isolation' (expected applied, available, unavailable or na)" ;;
    esac
    # "no isolation exists" and "nobody wrote it down" must not be indistinguishable.
    [[ "$note" != "-" ]] || die "row '$id' must carry a note; it is where an unavailable tier says why"
    if [[ "$tier" == none ]]; then
        [[ "$volume" == "-" && "$path" == "-" && "$command" == "-" && "$isolation" == na ]] \
            || die "row '$id' claims tier=none but declares a credential, command, or isolation state"
    else
        [[ "$volume" != "-" && "$path" != "-" ]] \
            || die "row '$id' holds a credential but names no volume or path"
        [[ "$isolation" != na ]] || die "row '$id' holds a credential but claims isolation=na"
    fi
    ROWS+=("$id"$'\t'"$tool"$'\t'"$command"$'\t'"$gate"$'\t'"$volume"$'\t'"$path"$'\t'"$tier")
done <<<"$rows_block"
[[ ${#ROWS[@]} -gt 0 ]] || die "custody table records no agent: $DOC"

# --- read the declared agent boundary --------------------------------------
AGENT_PAIRS=()
while IFS= read -r raw; do
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue
    fields=${line//[^|]/}
    [[ ${#fields} -eq 2 ]] || die "agent-service row must have 3 |-separated fields: $line"
    IFS='|' read -r file svc why <<<"$line"
    file=$(trim "$file"); svc=$(trim "$svc"); why=$(trim "$why")
    [[ -n "$file" && -n "$svc" && -n "$why" ]] || die "agent-service row has an empty field: $line"
    [[ -f "$ROOT/$file" ]] || die "agent-service row names a compose file that does not exist: $file"
    AGENT_PAIRS+=("$file"$'\t'"$svc")
done <<<"$(block "$DOC" credential-custody-agent-services)"
[[ ${#AGENT_PAIRS[@]} -gt 0 ]] || die "no agent services declared, so no tier could be checked"

# Every named-volume mount the agent boundary declares, as "<file>:<volume>:<path>".
AGENT_MOUNTS=""
for pair in "${AGENT_PAIRS[@]}"; do
    IFS=$'\t' read -r file svc <<<"$pair"
    found=0
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        found=1
        AGENT_MOUNTS="$AGENT_MOUNTS
$file:$m"
    done <<<"$(mounts_of "$ROOT/$file" "$svc")"
    [[ $found -eq 1 ]] || die "service '$svc' in $file declares no named-volume mount; the parse has stopped matching"
done

agent_mount_of() { # agent_mount_of VOLUME -> "<file>:<path>" of the first agent mount, or empty
    local v=$1 line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local rest=${line#*:}
        [[ "${rest%%:*}" == "$v" ]] || continue
        printf '%s:%s' "${line%%:*}" "${rest#*:}"
        return 0
    done <<<"$AGENT_MOUNTS"
    return 1
}

# --- 1. every rostered agent has a row -------------------------------------
roster_ids=$(awk '
    $0 == "```agent-roster" { inb = 1; next }
    inb && /^```/ { inb = 0; next }
    inb { print }
' "$ROSTER" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $7);
                           if ($1 == "" || substr($1,1,1) == "#") next; if ($7 == "shipped") print $1 }')
[[ -n "$roster_ids" ]] || die "no shipped agents found in $ROSTER; the roster parse has stopped matching"
for rid in $roster_ids; do
    if in_list "$rid" "$IDS"; then
        record PASS "roster:$rid" "rostered agent has a custody row"
    else
        record MISSING "$DOC_LABEL" "'$rid' is a shipped agent with no custody row, so its tier is unstated"
    fi
done

# --- 2. commands exist in both supported shells ----------------------------
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id tool command gate volume path tier <<<"$row"
    [[ "$command" != "-" ]] || { record PASS "command:$id" "needs no credential, so needs no sign-in"; continue; }
    absent=""
    for ext in sh ps1; do
        [[ -f "$ROOT/scripts/auth/$command.$ext" ]] || absent="${absent:+$absent, }$command.$ext"
    done
    if [[ -n "$absent" ]]; then
        record MISSING "scripts/auth" "'$id' has no host-side sign-in for every supported shell: $absent"
    else
        record PASS "command:$id" "scripts/auth/$command.{sh,ps1}"
    fi
done

# --- 3. each command reads its tier from the table rather than restating it -
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id tool command gate volume path tier <<<"$row"
    [[ "$command" != "-" ]] || continue
    sh_file=$ROOT/scripts/auth/$command.sh
    ps_file=$ROOT/scripts/auth/$command.ps1
    [[ -f "$sh_file" && -f "$ps_file" ]] || continue
    bad=""
    grep -q "auth_row $id" "$sh_file" || bad="${bad:+$bad, }$command.sh"
    grep -q "Get-AuthRow '$id'" "$ps_file" || bad="${bad:+$bad, }$command.ps1"
    if [[ -n "$bad" ]]; then
        record MISMATCH "scripts/auth" "'$id' does not read its custody row, so its disclosure can drift from this table: $bad"
    else
        record PASS "discloses:$id" "reads row '$id' in both shells"
    fi
done

# --- 4. the stated tier is the tier the compose wiring implements ----------
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id tool command gate volume path tier <<<"$row"
    if [[ "$tier" == none ]]; then
        if agent_mount_of "$volume" >/dev/null 2>&1; then
            record MISMATCH "$DOC_LABEL:$id" "claims no credential, but a volume of that name is mounted into the agent"
        else
            record PASS "tier:$id" "no credential, and none mounted"
        fi
        continue
    fi
    if mount=$(agent_mount_of "$volume"); then
        mfile=${mount%%:*}
        mpath=${mount#*:}
        if [[ "$tier" != agent-readable ]]; then
            record MISMATCH "$DOC_LABEL:$id" \
                "claims tier=$tier, but $mfile mounts '$volume' into the agent, so the agent user can read it"
        elif [[ "$mpath" != "$path" && "$path" != "$mpath"/* ]]; then
            record MISMATCH "$DOC_LABEL:$id" \
                "says the credential is at '$path', but '$volume' is mounted at '$mpath' in $mfile"
        else
            record PASS "tier:$id" "agent-readable, and '$volume' is mounted at '$mpath'"
        fi
    else
        if [[ "$tier" == agent-readable ]]; then
            record MISMATCH "$DOC_LABEL:$id" \
                "claims tier=agent-readable, but no agent service mounts '$volume'; the disclosure would overstate the exposure"
        else
            record PASS "tier:$id" "$tier, and no agent service mounts '$volume'"
        fi
    fi
done

# --- report ----------------------------------------------------------------
if [[ $JSON -eq 1 ]]; then
    printf '{\n  "table": "%s",\n  "checks": [\n' "$DOC_LABEL"
    first=1
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status subject detail <<<"$line"
        [[ $first -eq 0 ]] && printf ',\n'
        first=0
        printf '    {"status": "%s", "subject": "%s", "detail": "%s"}' \
            "$status" "$(json_escape "$subject")" "$(json_escape "$detail")"
    done
    printf '\n  ],\n  "passed": %d,\n  "missing": %d,\n  "mismatched": %d,\n  "custodyDrift": %s\n}\n' \
        "$PASSED" "$MISSING" "$MISMATCH" \
        "$([[ $((MISSING + MISMATCH)) -gt 0 ]] && echo true || echo false)"
else
    for line in ${RESULTS+"${RESULTS[@]}"}; do
        IFS=$'\t' read -r status subject detail <<<"$line"
        printf '%-9s %-24s %s\n' "$status" "$subject" "$detail"
    done
    printf '\n%d agreed, %d missing, %d mismatched\n' "$PASSED" "$MISSING" "$MISMATCH"
    if [[ $MISMATCH -gt 0 ]]; then
        printf 'RESULT: a stated custody tier contradicts the shipped configuration. Fix %s or the wiring.\n' "$DOC_LABEL"
    elif [[ $MISSING -gt 0 ]]; then
        printf 'RESULT: an agent has no row, or a sign-in command is missing from a supported shell.\n'
    else
        printf 'RESULT: every custody claim matches the shipped configuration.\n'
    fi
fi

[[ $((MISSING + MISMATCH)) -gt 0 ]] && exit 1
exit 0
