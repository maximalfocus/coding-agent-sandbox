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

compose=(docker compose -f docker-compose.sidecar.yml)
manager=("${compose[@]}" run --rm --no-deps deepseek-key-manager "$manager_action")

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
