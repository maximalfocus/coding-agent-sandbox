#!/usr/bin/env bash
# Shared refusal for helpers that mutate a credential store (issue #97). Sourced, not executed.
#
# `-p` scopes Compose containers and networks but not this project's volumes, which are named
# explicitly so a renamed checkout never orphans a login. A helper can therefore be addressing an
# isolated stack and still be writing to the operator's real credentials. #93 established that this
# must be refused rather than performed silently; #95 applied it to `claim-token`; this exists so the
# third copy is not a third slightly-different copy. That drift is the failure mode #93 *was*.
#
# Two ways to learn which volumes are in play, because the helpers differ:
#
#   stack_guard_volumes_of_container <name>   what a RUNNING container has mounted — the stronger
#                                             reading, since it observes rather than predicts
#   stack_guard_volumes_of_compose  <args...> what a compose invocation WOULD use — the only option
#                                             for a `run --rm` service that has no container yet
#
# Then `stack_guard_refuse_if_shared` decides. It is a no-op unless SIDECAR_COMPOSE_PROJECT is set:
# an operator working on their own single stack has declared nothing and must see no new friction.

STACK_GUARD_COMPOSE_FILE="${STACK_GUARD_COMPOSE_FILE:-docker-compose.sidecar.yml}"

stack_guard_volumes_of_container() {
    docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' \
        "$1" 2>/dev/null | sort -u
}

# Reads the names Compose resolves after substitution, so it reports what would really be mounted
# rather than re-implementing the `${VAR:-default}` expansion.
#
# Takes the arguments that follow `docker compose`, not a whole command line — passing the caller's
# full array here once produced `docker compose docker compose …`, which failed, and under the
# caller's `set -e` and `pipefail` aborted the script with no message at all. A guard that cannot
# resolve must say so rather than vanish, so the failure is reported here explicitly.
stack_guard_volumes_of_compose() {
    local rendered
    if ! rendered=$(docker compose "$@" config 2>&1); then
        echo "stack-guard: could not resolve volumes via 'docker compose $* config'" >&2
        printf '%s\n' "$rendered" | head -3 | sed 's/^/  /' >&2
        exit 1
    fi
    printf '%s\n' "$rendered" \
        | awk '/^volumes:/{f=1;next} /^[a-z]/{f=0} f' \
        | sed -nE 's/^[[:space:]]+name:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' | sort -u
}

# stack_guard_refuse_if_shared <what-would-happen> <volume names on stdin>
# Exits 1 with a named refusal when a declared project would touch an operator volume.
stack_guard_refuse_if_shared() {
    local consequence="$1" shared
    [ -n "${SIDECAR_COMPOSE_PROJECT:-}" ] || return 0

    # `|| true`: the check exits 1 precisely when it finds something, and under `set -e` the
    # assignment would abort here — failing closed by accident, with no message saying why.
    shared=$(cat | "$(dirname "${BASH_SOURCE[0]}")/check-stack-isolation.sh" "$STACK_GUARD_COMPOSE_FILE" \
             | tr '\n' ' ' | sed 's/ *$//' || true)
    [ -n "$shared" ] || return 0

    if [ "${SIDECAR_ALLOW_SHARED_VOLUMES:-}" = true ]; then
        echo "WARNING: project '$SIDECAR_COMPOSE_PROJECT' shares operator volumes ($shared), allowed explicitly" >&2
        return 0
    fi

    echo "REFUSING: project '$SIDECAR_COMPOSE_PROJECT' mounts the operator's own volumes: $shared" >&2
    echo "  $consequence" >&2
    echo "  Set the volume variables documented at the top of sidecar-smoketest.sh, or" >&2
    echo "  SIDECAR_ALLOW_SHARED_VOLUMES=true if you mean it." >&2
    exit 1
}
