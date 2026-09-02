#!/usr/bin/env bash
# Ordered, resumable configuration for the sandbox — from the HOST (issue #155, CAS-R056).
#
# Every configuration verb already existed; nothing ordered them or reported their state. An
# operator had to know to run setup.sh, hand-edit .env for the gates and SKILL_REPOS, run
# update-agent-clis.sh, run each scripts/auth/* command, run scripts/skills/skills-setup.sh, and
# run.sh to rebuild — in that order, from memory. Getting the order wrong mostly produces a later
# failure that does not name the step that was skipped.
#
# This is an ORDERING, STATUS, and RESUMABILITY layer. It reimplements nothing: every step invokes
# the supported path for its concern, and a step that drifts from that path is a defect here rather
# than a second implementation to maintain. It is not a second copy of CAS-R055's in-sandbox
# checklist either — that one stays narrow and inside the sandbox, and both are recomputed from the
# same observed state so they cannot disagree.
#
#   ./configure.sh                 # report every step's OBSERVED state; changes nothing
#   ./configure.sh --run           # walk in order, performing each unmet step
#   ./configure.sh --step stack    # one step alone (report)
#   ./configure.sh --step gh --run # ...or perform it
#   ./configure.sh --list          # the step ids, in order
#
# What it will NEVER do without you: enable a capability gate, adopt a pin, or create a credential.
# Those are operator decisions; the flow states the decision and stops.
#
# Report-only by default, the same contract scripts/update-agent-clis.sh has: nothing is written
# without --run.
set -uo pipefail
cd "$(dirname "$0")"

ROOT=$(pwd -P)
ENV_FILE=${SANDBOX_ENV_FILE:-$ROOT/.env}
CUSTODY_DOC=${SANDBOX_CUSTODY_DOC:-$ROOT/docs/credential-custody.md}
SVC=${SANDBOX_SERVICE:-claude-sandbox}

RUN=0
ONLY=
case_usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --run)   RUN=1 ;;
        --step)  shift; [ "$#" -gt 0 ] || { echo "--step needs an id (see --list)" >&2; exit 2; }; ONLY=$1 ;;
        --list)  LIST=1 ;;
        -h|--help) case_usage; exit 0 ;;
        *) echo "unknown option '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

UNMET=0
DECISION=0
SATISFIED=0
NA=0

# --- reporting -------------------------------------------------------------
# Three states, and the fourth is a flavour of `unmet` that must never be resolved silently.
say_state() { # say_state ID STATE DETAIL
    case "$2" in
        satisfied) SATISFIED=$((SATISFIED + 1)) ;;
        unmet)     UNMET=$((UNMET + 1)) ;;
        decision)  UNMET=$((UNMET + 1)); DECISION=$((DECISION + 1)) ;;
        n/a)       NA=$((NA + 1)) ;;
    esac
    printf '%-11s %-14s %s\n' "$2" "$1" "$3"
}

# --- .env, the control plane ------------------------------------------------
env_value() { # env_value NAME -> the value in .env, or empty
    [ -f "$ENV_FILE" ] || return 0
    sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | head -1 | sed 's/^"//; s/"$//'
}
gate_on() { # gate_on NAME DEFAULT -> 0 when the gate resolves on
    local v
    v=$(env_value "$1"); [ -n "$v" ] || v=$2
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# --- probes: OBSERVED state, never a claim ---------------------------------
stack_up() { docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; }
in_agent() { docker compose exec -T -u node "$SVC" sh -lc "$1" >/dev/null 2>&1; }

# The GitHub credential is observed EXACTLY the way entrypoint.sh derives GIT_CREDS_OK, so this
# flow and CAS-R055's in-sandbox checklist cannot disagree about it: a stored gh login, probed with
# the env tokens cleared (gh would otherwise report "logged in" merely because GITHUB_TOKEN is set),
# or a GITHUB_TOKEN in the environment.
gh_credential_ok() {
    in_agent 'env -u GITHUB_TOKEN -u GH_TOKEN gh auth status --hostname github.com' && return 0
    in_agent 'test -n "${GITHUB_TOKEN:-}"'
}

# --- the sign-in steps, derived from the custody table ---------------------
# Not a list kept here: docs/credential-custody.md already states which tools hold a credential,
# which command signs each one in, and which gate it needs. A tool added there is covered the day it
# is added.
custody_rows() {
    awk '
        $0 == "```credential-custody" { inb = 1; next }
        inb && /^```/ { inb = 0; next }
        inb { print }
    ' "$CUSTODY_DOC" 2>/dev/null | awk -F'|' '
        { for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
          if ($1 == "" || substr($1, 1, 1) == "#" || $3 == "-") next
          print $1 "\t" $2 "\t" $3 "\t" $4 }'
}

signin_probe() { # signin_probe ID -> 0 when a credential is observed
    case "$1" in
        claude) in_agent 'claude auth status 2>&1 | grep -q "\"loggedIn\": true"' ;;
        # 2>&1, not 2>/dev/null: codex reports its login status on STDERR, so discarding stderr
        # left grep with nothing and a signed-in Codex read as unmet.
        codex)  in_agent 'codex login status 2>&1 | grep -qi "logged in"' ;;
        gh)     gh_credential_ok ;;
        pi)     bash "$ROOT/scripts/auth/deepseek-key.sh" status >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# --- the ordered step list -------------------------------------------------
# Order is dependency order, and each step names the supported path it delegates to.
STEP_IDS="env stack pins"
for row in $(custody_rows | tr '\t' '\037' | tr ' ' '\036'); do
    id=$(printf '%s' "$row" | cut -d$'\037' -f1)
    STEP_IDS="$STEP_IDS $id"
done
STEP_IDS="$STEP_IDS skills"

if [ -n "${LIST:-}" ]; then
    printf '%s\n' $STEP_IDS
    exit 0
fi
if [ -n "$ONLY" ]; then
    case " $STEP_IDS " in
        *" $ONLY "*) ;;
        *) echo "unknown step '$ONLY' (see --list)" >&2; exit 2 ;;
    esac
fi

# --- steps ------------------------------------------------------------------
step_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ "$RUN" = 1 ] && [ -f "$ROOT/.env.example" ]; then
            cp "$ROOT/.env.example" "$ENV_FILE"
            say_state env decision ".env created from .env.example — set TTYD_PASS to something of your own, then re-run"
            return 1
        fi
        say_state env unmet "no .env — run ./setup.sh, or ./configure.sh --step env --run to copy .env.example"
        return 1
    fi
    local pass
    pass=$(env_value TTYD_PASS)
    case "$pass" in
        ""|changeme|please-change-me|password|coder|admin)
            say_state env decision "TTYD_PASS is unset or a shipped placeholder; only you can choose it. Edit $ENV_FILE"
            return 1 ;;
    esac
    say_state env satisfied ".env present, TTYD_PASS set"
}

step_stack() {
    if stack_up; then
        say_state stack satisfied "the sandbox is running"
        return 0
    fi
    if [ "$RUN" = 1 ]; then
        printf '  -> ./run.sh\n'
        "$ROOT/run.sh" || { say_state stack unmet "./run.sh failed — read its output above"; return 1; }
        stack_up && { say_state stack satisfied "started by ./run.sh"; return 0; }
        say_state stack unmet "./run.sh finished but no container is running"
        return 1
    fi
    say_state stack unmet "not running — ./run.sh (this flow can do it: --step stack --run)"
    return 1
}

step_pins() {
    local out
    out=$(bash "$ROOT/scripts/update-agent-clis.sh" 2>&1)
    if [ $? -ne 0 ]; then
        say_state pins unmet "the pin report could not complete: $(printf '%s' "$out" | tail -1)"
        return 1
    fi
    # The tool's own definitive line, not a guess assembled from its table: a per-row "up to date"
    # is true of that row alone, and reading it as the verdict reported every pin current while
    # Codex was two minor versions behind.
    if printf '%s\n' "$out" | grep -q 'Every selected pin is already current'; then
        say_state pins satisfied "every agent-CLI pin matches its published version"
        return 0
    fi
    # Adopting a pin is a rebuild AND a revalidation, and CAS-R066/CAS-R067 make it an explicit,
    # reviewed step. The flow shows the gap; it never writes one.
    say_state pins decision "a pin differs from its published version; adopting one is your call — ./scripts/update-agent-clis.sh"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
}

step_signin() { # step_signin ID TOOL COMMAND GATE
    local id=$1 tool=$2 command=$3 gate=$4 gate_name
    if ! stack_up; then
        say_state "$id" unmet "the sandbox is not running, so $tool's credential cannot be observed"
        return 1
    fi
    if [ "$gate" != "-" ]; then
        gate_name=${gate%%:*}
        if ! gate_on "$gate_name" false; then
            # A capability grant is an operator decision. The flow states it and stops; it never
            # turns a gate on, because that is egress the operator did not ask for.
            say_state "$id" decision "$gate_name is off in .env, so $tool cannot sign in; enabling it is a capability grant only you can make"
            return 1
        fi
    fi
    if signin_probe "$id"; then
        say_state "$id" satisfied "$tool is signed in"
        return 0
    fi
    if [ "$RUN" = 1 ]; then
        # A credential is an operator decision too, but an interactive one the supported command
        # already owns — so the flow hands over to it rather than deciding anything itself.
        printf '  -> ./scripts/auth/%s.sh\n' "$command"
        bash "$ROOT/scripts/auth/$command.sh" || true
        if signin_probe "$id"; then
            say_state "$id" satisfied "$tool signed in by ./scripts/auth/$command.sh"
            return 0
        fi
        say_state "$id" unmet "$tool is still not signed in — ./scripts/auth/$command.sh"
        return 1
    fi
    say_state "$id" unmet "$tool is not signed in — ./scripts/auth/$command.sh"
    return 1
}

step_skills() {
    local repos
    repos=$(env_value SKILL_REPOS)
    if [ -z "$repos" ]; then
        # Driven by the operator's configured list. The product ships no roster of skill
        # repositories, so "none configured" is not unfinished setup.
        say_state skills n/a "SKILL_REPOS is empty in .env; skill repositories are optional"
        return 0
    fi
    if ! stack_up; then
        say_state skills unmet "the sandbox is not running, so the skill clones cannot be observed"
        return 1
    fi
    local missing=""
    for url in $repos; do
        name=${url##*/}; name=${name%.git}
        in_agent "test -d /workspace/personal/$name/.git" || missing="${missing:+$missing }$name"
    done
    if [ -z "$missing" ]; then
        say_state skills satisfied "every configured skill repository is cloned"
        return 0
    fi
    if [ "$RUN" = 1 ]; then
        printf '  -> ./scripts/skills/skills-setup.sh\n'
        bash "$ROOT/scripts/skills/skills-setup.sh" || true
        missing=""
        for url in $repos; do
            name=${url##*/}; name=${name%.git}
            in_agent "test -d /workspace/personal/$name/.git" || missing="${missing:+$missing }$name"
        done
        [ -z "$missing" ] && { say_state skills satisfied "cloned by ./scripts/skills/skills-setup.sh"; return 0; }
    fi
    say_state skills unmet "not cloned: $missing — ./scripts/skills/skills-setup.sh"
    return 1
}

# --- walk -------------------------------------------------------------------
wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

printf 'Configuration steps, in order. State is OBSERVED, not assumed.\n\n'

stop=0
for id in $STEP_IDS; do
    [ "$stop" = 1 ] && break
    wanted "$id" || continue
    case "$id" in
        env)    step_env    || { [ "$RUN" = 1 ] && [ -z "$ONLY" ] && stop=1; } ;;
        stack)  step_stack  || { [ "$RUN" = 1 ] && [ -z "$ONLY" ] && stop=1; } ;;
        pins)   step_pins   || true ;;
        skills) step_skills || true ;;
        *)
            row=$(custody_rows | awk -F'\t' -v want="$id" '$1 == want')
            [ -n "$row" ] || continue
            tool=$(printf '%s' "$row" | cut -f2)
            command=$(printf '%s' "$row" | cut -f3)
            gate=$(printf '%s' "$row" | cut -f4)
            step_signin "$id" "$tool" "$command" "$gate" || true ;;
    esac
done

printf '\n%d satisfied, %d unmet, %d not applicable\n' "$SATISFIED" "$UNMET" "$NA"
if [ "$stop" = 1 ]; then
    printf 'STOPPED: a step this flow cannot complete on its own. Nothing after it was attempted.\n'
elif [ "$DECISION" -gt 0 ]; then
    printf 'DECISIONS: %d step(s) need a choice only you can make — a capability grant, a credential, or a pin.\n' "$DECISION"
fi
if [ "$RUN" != 1 ] && [ "$UNMET" -gt 0 ]; then
    printf 'This was a report; nothing was changed. Add --run to perform the steps that do not need a decision.\n'
fi

[ "$UNMET" -gt 0 ] && exit 1
exit 0
