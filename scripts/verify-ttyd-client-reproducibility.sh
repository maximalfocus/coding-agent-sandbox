#!/usr/bin/env bash
# Prove two isolated ttyd web-client builds are byte-identical and match the
# recorded committed artifact. No tracked file is modified.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest=${TTYD_REPRO_MANIFEST:-$repo_root/ttyd/reproducibility.env}

fail() {
    local stage=$1
    shift
    printf '[%s] %s\n' "$stage" "$*" >&2
    exit 1
}

[[ -f "$manifest" ]] || fail 'INPUT manifest' "missing $manifest"
# shellcheck source=/dev/null
source "$manifest"
for name in TTYD_ARTIFACT_PATH TTYD_ARTIFACT_SHA256; do
    if [[ -z "${!name:-}" ]]; then
        fail 'INPUT manifest' "missing value: $name"
    fi
done
artifact=$repo_root/$TTYD_ARTIFACT_PATH
[[ -f "$artifact" ]] || fail 'ARTIFACT missing' "missing $TTYD_ARTIFACT_PATH"

recorded=$(shasum -a 256 "$artifact" | awk '{print $1}')
[[ "$recorded" == "$TTYD_ARTIFACT_SHA256" ]] \
    || fail 'ARTIFACT checksum' "$recorded does not match $TTYD_ARTIFACT_SHA256"
dockerfile_sha=$(awk -F'"' '/\/usr\/local\/share\/ttyd\/index.html/ && /echo/ {split($2, fields, " "); print fields[1]; exit}' "$repo_root/Dockerfile")
[[ "$dockerfile_sha" == "$TTYD_ARTIFACT_SHA256" ]] \
    || fail 'ARTIFACT Dockerfile-pin' "${dockerfile_sha:-missing} does not match $TTYD_ARTIFACT_SHA256"

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT

TTYD_REPRO_MANIFEST="$manifest" "$repo_root/scripts/ttyd-client-build.sh" "$work/first.html"
TTYD_REPRO_MANIFEST="$manifest" "$repo_root/scripts/ttyd-client-build.sh" "$work/second.html"
cmp -s "$work/first.html" "$work/second.html" \
    || fail 'REPRODUCIBILITY independent-builds' 'the two clean build outputs differ'
candidate=$(shasum -a 256 "$work/first.html" | awk '{print $1}')
[[ "$candidate" == "$TTYD_ARTIFACT_SHA256" ]] \
    || fail 'REPRODUCIBILITY recorded-checksum' "$candidate does not match $TTYD_ARTIFACT_SHA256"
cmp -s "$work/first.html" "$artifact" \
    || fail 'REPRODUCIBILITY committed-bytes' 'candidate differs from ttyd/index.html'

printf 'PASS: two independent builds match %s and %s\n' "$TTYD_ARTIFACT_PATH" "$TTYD_ARTIFACT_SHA256"
