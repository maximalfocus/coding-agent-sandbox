#!/usr/bin/env bash
# Explicitly replace ttyd/index.html, but only with two matching clean builds
# and an operator-supplied expected checksum.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
expected=${2:-}

fail() {
    printf '[%s] %s\n' "$1" "$2" >&2
    exit 1
}

if [[ "${1:-}" != '--apply' || ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    fail 'INPUT explicit-apply' 'usage: scripts/rebuild-ttyd-client.sh --apply EXPECTED_SHA256'
fi

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT

"$repo_root/scripts/ttyd-client-build.sh" "$work/first.html"
"$repo_root/scripts/ttyd-client-build.sh" "$work/second.html"
cmp -s "$work/first.html" "$work/second.html" \
    || fail 'REBUILD independent-builds' 'the two clean build outputs differ; artifact not replaced'
actual=$(shasum -a 256 "$work/first.html" | awk '{print $1}')
[[ "$actual" == "$expected" ]] \
    || fail 'REBUILD expected-checksum' "$actual does not match operator-supplied $expected; artifact not replaced"

install -m 0644 "$work/first.html" "$repo_root/ttyd/index.html"
printf 'Applied reproducible ttyd client %s.\n' "$actual"
printf 'Review the artifact, then update reproducibility.env and the Dockerfile pin if this is a new checksum.\n'
