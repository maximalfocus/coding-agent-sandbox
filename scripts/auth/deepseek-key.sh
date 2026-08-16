#!/usr/bin/env bash
# Manage the real DeepSeek API key in the dedicated egress-sidecar volume. The key is sent only on
# stdin to a one-off sidecar container; it is never a Compose environment value or command argument.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
    echo "Usage: $0 {provision|rotate|status|revoke}" >&2
    exit 2
}

action="${1:-}"
[ "$#" -eq 1 ] || usage
case "$action" in
    provision|rotate) manager_action=store ;;
    status) manager_action=status ;;
    revoke) manager_action=delete ;;
    *) usage ;;
esac

# Scope to the selected project, the same way sidecar-smoketest.sh and claim-token.sh do. Without
# `-p` this cannot address a stack started with one, so an isolated validation run had to invoke
# Compose directly to work around it (issue #95).
compose_args=()
if [ -n "${SIDECAR_COMPOSE_PROJECT:-}" ]; then compose_args+=(-p "$SIDECAR_COMPOSE_PROJECT"); fi
compose_args+=(-f docker-compose.sidecar.yml)
compose=(docker compose "${compose_args[@]}")
manager=("${compose[@]}" run --rm --no-deps deepseek-key-manager "$manager_action")

# `-p` does not scope the volumes, so a run that declares isolation can still be writing to the
# operator's real key — and `store` is an unconditional write while `delete` removes it. There is no
# validation step here to fail closed against, the way claim-token's provider check does, so the
# refusal has to come first (issue #97).
#
# The volumes are resolved from `compose config` rather than from a container, because this service
# runs via `run --rm` and has no container to inspect until it is already too late.
# NOT a pipeline: the guard exits, and `exit` inside a pipeline leaves only the subshell.
# shellcheck source=../stack-guard.sh
. "$(dirname "$0")/../stack-guard.sh"
stack_volumes=$(stack_guard_volumes_of_compose "${compose_args[@]}")
stack_guard_refuse_if_shared \
    "A '$action' here would act on the operator's real DeepSeek key, not this stack's." \
    <<<"$stack_volumes"

if [ "$manager_action" != store ]; then
    exec "${manager[@]}"
fi

if [ -t 0 ]; then
    printf 'DeepSeek API key (input hidden): ' >&2
    IFS= read -r -s key
    printf '\n' >&2
else
    IFS= read -r key
fi
[ -n "${key:-}" ] || { echo "ERROR: no key supplied" >&2; exit 1; }
printf '%s' "$key" | "${manager[@]}"
result=$?
unset key
exit "$result"
