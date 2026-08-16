#!/usr/bin/env bash
# Run a verification command on another machine, reached by stable identity (issue #80, CAS-R163).
#
# Some things cannot be verified on the machine they are developed on: an architecture-conditional
# build needs hardware of that architecture, and anything that depends on real kernel behaviour needs
# a host running Docker on its own kernel rather than inside a VM. See docs/verification-hosts.md.
#
# Reaching such a host by alias alone is not safe here. These machines hold DHCP leases on a network
# that resolves no names, so an address is the only handle and it moves. A stale alias either fails
# in a way that looks like the host being down, or — worse — connects to whatever machine inherited
# the lease, whose results would then be recorded as if they came from the intended host class.
#
# So resolution is delegated to the maintained fleet tool, which identifies a machine by its SSH host
# key and repairs the alias to match. **This script contains no discovery logic of its own** — no ARP
# lookup, no key scan, no MAC table. That is deliberate: a second implementation would drift from the
# maintained one and be exercised far less. If the fleet tool is unavailable, this stops rather than
# falling back to a plain `ssh <alias>`, because that fallback is exactly the failure being removed.
#
# Usage:
#   scripts/verify-on-host.sh --list
#   scripts/verify-on-host.sh <alias> -- <command>...
#
# Configuration:
#   FIND_HOST   path to the fleet tool. Defaults to the first of the documented candidates that
#               exists, then to `find-host` on PATH.
#
# Exit status: the command's own status on success,
#              2 when the host could not be resolved or the fleet tool is unavailable.
#              It never runs the command against an unverified host.
set -uo pipefail

CANDIDATES=(
    "$HOME/personal/laptop-upgrader/tools/find-host"
    "$HOME/laptop-upgrader/tools/find-host"
)

cannot_run() { printf 'COULD NOT RUN: %s\n' "$*" >&2; exit 2; }

resolve_tool() {
    if [ -n "${FIND_HOST:-}" ]; then
        [ -x "$FIND_HOST" ] || cannot_run "FIND_HOST is set but not executable: $FIND_HOST"
        printf '%s' "$FIND_HOST"
        return 0
    fi
    local candidate
    for candidate in "${CANDIDATES[@]}"; do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    candidate=$(command -v find-host 2>/dev/null) && [ -n "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    return 1
}

tool=$(resolve_tool) || cannot_run "the fleet host-discovery tool was not found.
       Set FIND_HOST to its path, or install it on PATH. This script deliberately has no
       discovery of its own and will not fall back to connecting by alias, because a stale
       alias can reach a different machine (CAS-R163)."

if [ "${1:-}" = "--list" ]; then
    exec "$tool" --list
fi

alias_name=${1:-}
[ -n "$alias_name" ] || cannot_run "usage: ${0##*/} <alias> -- <command>...   (or --list)"
shift
[ "${1:-}" = "--" ] || cannot_run "expected -- before the command; usage: ${0##*/} <alias> -- <command>..."
shift
[ "$#" -gt 0 ] || cannot_run "no command given; usage: ${0##*/} <alias> -- <command>..."

# Resolve by identity. The tool prints the address it settled on and explains itself on stderr; its
# exit status distinguishes "no such alias" from "that machine could not be located", and both are
# surfaced rather than retried as a plain connection.
address=$("$tool" "$alias_name" 2>/dev/null)
resolve_status=$?
case "$resolve_status" in
    0) ;;
    2) cannot_run "'$alias_name' is not a known host. Known: $("$tool" --list 2>/dev/null | tr '\n' ' ')" ;;
    *) cannot_run "the fleet tool could not locate '$alias_name'. Run it directly to see why:
       $tool $alias_name" ;;
esac
[ -n "$address" ] || cannot_run "the fleet tool reported success but no address for '$alias_name'"

# Name the host class the result actually came from, so a claim can state it rather than imply it.
# `kernel:bare` means Docker runs on this host's own kernel; macOS and Windows run it inside a Linux
# virtual machine and are reported as `kernel:vm`.
host_facts=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$alias_name" '
    arch=$(uname -m)
    kind=$(uname -s)
    case "$kind" in
        Linux)  kernel=bare ;;
        Darwin) kernel=vm ;;
        *)      kernel=unknown ;;
    esac
    printf "%s %s %s\n" "$arch" "$kernel" "$kind"
' 2>/dev/null)

if [ -z "$host_facts" ]; then
    cannot_run "resolved '$alias_name' to $address but could not read its host facts over SSH"
fi

set -- "$@"
read -r host_arch host_kernel host_kind <<<"$host_facts"
printf 'host: %s (%s) — arch:%s kernel:%s %s\n' "$alias_name" "$address" "$host_arch" "$host_kernel" "$host_kind" >&2

ssh -o BatchMode=yes -o ConnectTimeout=20 "$alias_name" "$@"
command_status=$?

printf 'host-class: arch:%s kernel:%s (%s)\n' "$host_arch" "$host_kernel" "$alias_name" >&2
exit "$command_status"
