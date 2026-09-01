#!/usr/bin/env bash
# Build one ttyd client candidate from the recorded immutable inputs. This
# command never writes the tracked artifact.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest=${TTYD_REPRO_MANIFEST:-$repo_root/ttyd/reproducibility.env}
output=${1:-}

fail() {
    local stage=$1
    shift
    printf '[%s] %s\n' "$stage" "$*" >&2
    exit 1
}

if [[ -z "$output" ]]; then
    fail 'INPUT output' 'usage: scripts/ttyd-client-build.sh OUTPUT'
fi
command -v python3 >/dev/null || fail 'TOOL host' 'python3 is required'
output_real=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$output")
artifact_real=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$repo_root/ttyd/index.html")
if [[ "$output_real" == "$artifact_real" ]]; then
    fail 'INPUT output-boundary' 'the build command cannot overwrite ttyd/index.html; use rebuild-ttyd-client.sh --apply'
fi
if [[ ! -f "$manifest" ]]; then
    fail 'INPUT manifest' "missing $manifest"
fi

# shellcheck source=/dev/null
source "$manifest"
required=(
    TTYD_SOURCE_REPOSITORY TTYD_SOURCE_COMMIT TTYD_SOURCE_TREE
    TTYD_PACKAGE_JSON_SHA256 TTYD_YARN_LOCK_SHA256 TTYD_PATCH_PATH TTYD_PATCH_SHA256
    TTYD_TOOLCHAIN_IMAGE TTYD_TOOLCHAIN_PLATFORM TTYD_NODE_VERSION
    TTYD_COREPACK_VERSION TTYD_YARN_VERSION TTYD_BUILD_DIRECTORY TTYD_BUILD_COMMAND
    TTYD_BUILD_OUTPUT
)
for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        fail 'INPUT manifest' "missing value: $name"
    fi
done

patch_path=$repo_root/$TTYD_PATCH_PATH
if [[ ! -f "$patch_path" ]]; then
    fail 'INPUT local-patch' "missing $TTYD_PATCH_PATH"
fi
patch_sha=$(shasum -a 256 "$patch_path" | awk '{print $1}')
if [[ "$patch_sha" != "$TTYD_PATCH_SHA256" ]]; then
    fail 'INPUT local-patch' "checksum $patch_sha does not match $TTYD_PATCH_SHA256"
fi
command -v git >/dev/null || fail 'TOOL host' 'git is required'
command -v docker >/dev/null || fail 'TOOL host' 'docker is required'

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT

source_dir=$work/source
mkdir -p "$source_dir" "$(dirname "$output")"
git -C "$source_dir" init -q || fail 'SOURCE init' 'could not initialise source checkout'
git -C "$source_dir" remote add origin "$TTYD_SOURCE_REPOSITORY"
if ! git -C "$source_dir" fetch --quiet --depth=1 origin "$TTYD_SOURCE_COMMIT"; then
    fail 'SOURCE fetch' "could not fetch $TTYD_SOURCE_COMMIT"
fi
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
actual_commit=$(git -C "$source_dir" rev-parse HEAD)
actual_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}')
[[ "$actual_commit" == "$TTYD_SOURCE_COMMIT" ]] \
    || fail 'SOURCE commit-identity' "$actual_commit does not match $TTYD_SOURCE_COMMIT"
[[ "$actual_tree" == "$TTYD_SOURCE_TREE" ]] \
    || fail 'SOURCE tree-identity' "$actual_tree does not match $TTYD_SOURCE_TREE"

package_sha=$(shasum -a 256 "$source_dir/$TTYD_BUILD_DIRECTORY/package.json" | awk '{print $1}')
lock_sha=$(shasum -a 256 "$source_dir/$TTYD_BUILD_DIRECTORY/yarn.lock" | awk '{print $1}')
[[ "$package_sha" == "$TTYD_PACKAGE_JSON_SHA256" ]] \
    || fail 'DEPENDENCY package-json' "$package_sha does not match $TTYD_PACKAGE_JSON_SHA256"
[[ "$lock_sha" == "$TTYD_YARN_LOCK_SHA256" ]] \
    || fail 'DEPENDENCY yarn-lock' "$lock_sha does not match $TTYD_YARN_LOCK_SHA256"

docker_args=(
    run --rm --platform "$TTYD_TOOLCHAIN_PLATFORM"
    -v "$source_dir:/source"
    -v "$patch_path:/recipe/apply-clipboard-patch.mjs:ro"
    -w "/source/$TTYD_BUILD_DIRECTORY"
)
if [[ -f "$repo_root/certs/Cloudflare_CA.crt" ]]; then
    docker_args+=(
        -e NODE_EXTRA_CA_CERTS=/recipe/Cloudflare_CA.crt
        -v "$repo_root/certs/Cloudflare_CA.crt:/recipe/Cloudflare_CA.crt:ro"
    )
fi

if ! docker "${docker_args[@]}" "$TTYD_TOOLCHAIN_IMAGE" sh -euc '
    test "$(node --version)" = "$1" || { echo "[TOOLCHAIN node] expected $1, got $(node --version)" >&2; exit 1; }
    test "$(corepack --version)" = "$2" || { echo "[TOOLCHAIN corepack] expected $2, got $(corepack --version)" >&2; exit 1; }
    corepack enable
    test "$(yarn --version)" = "$3" || { echo "[TOOLCHAIN yarn] expected $3, got $(yarn --version)" >&2; exit 1; }
    if ! yarn install --immutable >/tmp/yarn-install.log 2>&1; then
        cat /tmp/yarn-install.log >&2
        echo "[DEPENDENCY install] immutable Yarn install failed" >&2
        exit 1
    fi
    node /recipe/apply-clipboard-patch.mjs node_modules/@xterm/addon-clipboard/lib/addon-clipboard.js
    test "$4" = "yarn inline" || { echo "[BUILD invocation] unrecognised command: $4" >&2; exit 1; }
    if ! yarn inline >/tmp/yarn-build.log 2>&1; then
        cat /tmp/yarn-build.log >&2
        echo "[BUILD invocation] yarn inline failed" >&2
        exit 1
    fi
    test -f dist/inline.html || { echo "[BUILD output] dist/inline.html was not produced" >&2; exit 1; }
    node /recipe/apply-clipboard-patch.mjs --normalize-bundle dist/inline.html
' ttyd-build "$TTYD_NODE_VERSION" "$TTYD_COREPACK_VERSION" "$TTYD_YARN_VERSION" "$TTYD_BUILD_COMMAND"; then
    fail 'BUILD container' 'toolchain, dependency installation, patch, or build failed'
fi

container_output=$source_dir/$TTYD_BUILD_OUTPUT
if [[ ! -f "$container_output" ]]; then
    fail 'BUILD output' "missing $TTYD_BUILD_OUTPUT"
fi
cp "$container_output" "$output"
printf '[BUILD complete] %s  %s\n' "$(shasum -a 256 "$output" | awk '{print $1}')" "$output"
