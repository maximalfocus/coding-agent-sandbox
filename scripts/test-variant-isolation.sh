#!/usr/bin/env bash
# Every variant must be able to run in isolation (issue #112).
#
# `docker compose -p <project>` scopes containers and networks, but NOT a volume given an explicit
# `name:`, and `container_name:` overrides the project prefix entirely. This project names both
# explicitly on purpose — "renaming the folder never orphans your login" — so without an override a
# validation run of the default or mitm variant must either mount the operator's real logins or
# collide with their running container. The sidecar gained these knobs in #93/#69; the other two did
# not, so the project's own isolation discipline stopped at its experimental variant.
#
# The rule: every `container_name:` and every volume `name:` in a shipped compose file is
# `${VAR:-<today's value>}`. Enumerated from the files rather than a list kept here, so a volume
# added tomorrow is covered the day it is added.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
FILES="docker-compose.yml docker-compose.mitm.yml docker-compose.sidecar.yml"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

# Lines that assign a name: `container_name:` anywhere, and `name:` inside the top-level volumes map.
name_lines() { # file
    awk '
      /^volumes:/ { inv = 1 }
      /^[a-z]/ && !/^volumes:/ { inv = 0 }
      /container_name:/ { print FILENAME ":" FNR ":" $0 }
      inv && /^[[:space:]]+name:/ { print FILENAME ":" FNR ":" $0 }
    ' "$1"
}

total=0; bare=""
for f in $FILES; do
    [ -f "$f" ] || fail "$f is missing"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        total=$((total + 1))
        value=${hit#*:*:}
        grep -q '\${[A-Za-z_][A-Za-z0-9_]*:-' <<<"$value" \
            || bare="$bare
    ${hit%%:*}:$(printf '%s' "$hit" | cut -d: -f2): $(printf '%s' "$value" | sed 's/^[[:space:]]*//')"
    done < <(name_lines "$f")
done
[ "$total" -gt 0 ] || fail "no name assignments found — the scan has stopped matching"
ok "$total container/volume name assignments examined across $(wc -w <<<"$FILES") compose files"
[ -z "$bare" ] || fail "these names are hardcoded, so the variant cannot be isolated:$bare
    Make each \${VAR:-<current value>} so a validation run can scope it."
ok "every container and volume name is overridable in every shipped variant"

# --- defaults must be unchanged --------------------------------------------
# The knob exists for validation runs; an operator who sets nothing must see exactly today's names.
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP: no Docker daemon for the render checks"; printf '\nAll %d checks passed.\n' "$PASSED"; exit 0; }

# Render with WORKSPACE_DIR/WORK_DIR/PERSONAL_DIR empty: that is the documented "inert fallback"
# case, and it is the only one in which every declared volume is actually in use. With a host bind
# configured the fallback volumes are unused and Compose omits them, which would let a wrong name
# pass unnoticed.
render() { # file [VAR=value ...]
    env WORKSPACE_DIR= WORK_DIR= PERSONAL_DIR= "${@:2}" \
        docker compose -p isotest --env-file .env.example -f "$1" config 2>/dev/null
}

# Inverted on purpose: assert that every name the render PRODUCES is one of the declared defaults,
# rather than that every declared default appears. The second form cannot tell "absent because
# unused" from "absent because wrong".
for f in $FILES; do
    out=$(render "$f")
    [ -n "$out" ] || fail "$f did not render"
    defaults=$(name_lines "$f" | sed -nE 's/.*\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}.*/\1/p')
    while IFS= read -r got; do
        [ -n "$got" ] || continue
        grep -qxF "$got" <<<"$defaults" || fail "$f rendered an unexpected name with nothing set: '$got'"
    done < <(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*(container_)?name:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\2/p' | grep -vE '^isotest')   # networks render as name: too, project-prefixed
done
ok "with nothing set, every rendered name is exactly today's value"

# --- and an override must actually reach the rendered config ---------------
for f in $FILES; do
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        var=$(sed -nE 's/.*\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}.*/\1/p' <<<"$hit")
        [ -n "$var" ] || continue
        probe="isoprobe-$(tr '[:upper:]_' '[:lower:]-' <<<"$var")"
        grep -qF "$probe" <<<"$(render "$f" "$var=$probe")" \
            || fail "$f: setting $var did not reach the rendered config"
    done < <(name_lines "$f")
done
ok "setting any of those variables reaches the rendered config"

# --- the check must be able to fail ----------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf 'services:\n  x:\n    container_name: hardcoded\nvolumes:\n  v:\n    name: also-hardcoded\n' > "$TMP/bad.yml"
bad=$(name_lines "$TMP/bad.yml" | grep -cv '\${[A-Za-z_][A-Za-z0-9_]*:-')
[ "$bad" -eq 2 ] || fail "a hardcoded container_name and volume name were not both detected (saw $bad)"
ok "hardcoded names are detected — the scan is not vacuous"

printf 'volumes:\n  v:\n    name: "${V_NAME:-fine}"\n' > "$TMP/good.yml"
[ "$(name_lines "$TMP/good.yml" | grep -cv '\${[A-Za-z_][A-Za-z0-9_]*:-')" -eq 0 ] \
    || fail "an overridable name was reported as hardcoded"
ok "an overridable name is accepted"

printf '\nAll %d checks passed.\n' "$PASSED"
