#!/usr/bin/env bash
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest=$root/ttyd/reproducibility.env
patcher=$root/ttyd/apply-clipboard-patch.mjs
builder=$root/scripts/ttyd-client-build.sh
verifier=$root/scripts/verify-ttyd-client-reproducibility.sh
drift=$root/scripts/check-ttyd-client-drift.sh
pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'PASS: %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

expect() {
    local label=$1
    shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=/dev/null
source "$manifest"
expect 'local patch checksum is pinned' test \
    "$(shasum -a 256 "$patcher" | awk '{print $1}')" = "$TTYD_PATCH_SHA256"
expect 'committed artifact matches its build record' test \
    "$(shasum -a 256 "$root/$TTYD_ARTIFACT_PATH" | awk '{print $1}')" = "$TTYD_ARTIFACT_SHA256"
expect 'published-advisory baseline has a pinned fingerprint' test \
    "${#TTYD_NPM_ADVISORY_BASELINE_SHA256}" -eq 64
expect 'Dockerfile uses the same artifact checksum' grep -Fq \
    "$TTYD_ARTIFACT_SHA256  /usr/local/share/ttyd/index.html" "$root/Dockerfile"

printf '%s\n' \
    'prefix async readText(t){return"c"!==t?Promise.resolve(""):navigator.clipboard.readText()}async writeText(t,e){return"c"!==t?Promise.resolve():navigator.clipboard.writeText(e)} suffix' \
    >"$work/addon.js"
expect 'local patch accepts the recorded addon input' node "$patcher" "$work/addon.js"
expect 'empty OSC 52 selector is accepted' grep -Fq '""!==e&&"c"!==e' "$work/addon.js"
expect 'denied Clipboard API write has a textarea fallback' grep -Fq \
    'document.createElement("textarea")' "$work/addon.js"
if node "$patcher" "$work/addon.js" >"$work/repatch.log" 2>&1; then
    bad 'reapplying the local patch fails closed'
elif grep -Fq '[PATCH source-shape]' "$work/repatch.log"; then
    ok 'reapplying the local patch fails closed'
else
    bad 'reapplying the local patch names its stage'
fi

printf '%s\n' \
    'async writeText(e,t){if(""===e||"c"===e)try{x()} //# sourceMappingURL=app.bb77e35ca2408451e636.js.map' \
    >"$work/bundle.html"
expect 'bundle normalization accepts exactly the recorded shape' \
    node "$patcher" --normalize-bundle "$work/bundle.html"
expect 'bundle normalization records the reproducible guard' grep -Fq \
    'if(""!==e&&"c"!==e)return;try{' "$work/bundle.html"
expect 'bundle normalization records the reproducible map name' grep -Fq \
    'sourceMappingURL=app.9e0d4a1df46caf31b896.js.map' "$work/bundle.html"

sed 's/^TTYD_PATCH_SHA256=.*/TTYD_PATCH_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$manifest" >"$work/bad-hash.env"
if TTYD_REPRO_MANIFEST="$work/bad-hash.env" "$builder" "$work/no-output" \
    >"$work/bad-hash.log" 2>&1; then
    bad 'changed local patch checksum is rejected'
elif grep -Fq '[INPUT local-patch]' "$work/bad-hash.log"; then
    ok 'changed local patch checksum is rejected with its stage'
else
    bad 'changed local patch checksum names its stage'
fi

manifest_fields=(
    TTYD_SOURCE_REPOSITORY TTYD_SOURCE_COMMIT TTYD_SOURCE_TREE
    TTYD_PACKAGE_JSON_SHA256 TTYD_YARN_LOCK_SHA256 TTYD_PATCH_PATH TTYD_PATCH_SHA256
    TTYD_TOOLCHAIN_IMAGE TTYD_TOOLCHAIN_PLATFORM TTYD_NODE_VERSION
    TTYD_COREPACK_VERSION TTYD_YARN_VERSION TTYD_BUILD_DIRECTORY TTYD_BUILD_COMMAND
    TTYD_BUILD_OUTPUT
)
all_missing_named=true
for name in "${manifest_fields[@]}"; do
    grep -v "^${name}=" "$manifest" >"$work/missing-${name}.env"
    if TTYD_REPRO_MANIFEST="$work/missing-${name}.env" \
        "$builder" "$work/missing-${name}.html" >"$work/missing-${name}.log" 2>&1; then
        all_missing_named=false
        break
    fi
    grep -Fq "[INPUT manifest] missing value: $name" "$work/missing-${name}.log" \
        || { all_missing_named=false; break; }
done
expect 'every missing build-record field fails at the manifest stage' test "$all_missing_named" = true

grep -v '^TTYD_ARTIFACT_SHA256=' "$manifest" >"$work/missing-artifact.env"
if TTYD_REPRO_MANIFEST="$work/missing-artifact.env" "$verifier" \
    >"$work/missing-artifact.log" 2>&1; then
    bad 'missing artifact checksum is rejected before building'
elif grep -Fq '[INPUT manifest] missing value: TTYD_ARTIFACT_SHA256' "$work/missing-artifact.log"; then
    ok 'missing artifact checksum is rejected before building'
else
    bad 'missing artifact checksum names its stage'
fi

grep -v '^TTYD_NPM_ADVISORY_BASELINE_SHA256=' "$manifest" >"$work/missing-advisory.env"
set +e
"$drift" --manifest "$work/missing-advisory.env" >"$work/missing-advisory.log" 2>&1
missing_advisory_status=$?
set -e
if [[ "$missing_advisory_status" -eq 2 ]] \
    && grep -Fq 'UNEVALUATED manifest: missing TTYD_NPM_ADVISORY_BASELINE_SHA256' \
        "$work/missing-advisory.log"; then
    ok 'missing drift baseline is UNEVALUATED before network access'
else
    bad 'missing drift baseline is classified and named'
fi

expect 'verifier launches two independent builds' test \
    "$(grep -c 'ttyd-client-build.sh' "$verifier")" -eq 2
expect 'verifier compares independent bytes' grep -Fq \
    "cmp -s \"\$work/first.html\" \"\$work/second.html\"" "$verifier"
expect 'verifier checks the Dockerfile pin' grep -Fq 'ARTIFACT Dockerfile-pin' "$verifier"
if "$builder" "$root/ttyd/index.html" >"$work/build-boundary.log" 2>&1; then
    bad 'raw builder refuses to overwrite the tracked artifact'
elif grep -Fq '[INPUT output-boundary]' "$work/build-boundary.log"; then
    ok 'raw builder refuses to overwrite the tracked artifact'
else
    bad 'raw builder overwrite refusal names its stage'
fi
if "$root/scripts/rebuild-ttyd-client.sh" >"$work/rebuild.log" 2>&1; then
    bad 'rebuild refuses an implicit write'
elif grep -Fq '[INPUT explicit-apply]' "$work/rebuild.log"; then
    ok 'rebuild refuses an implicit write'
else
    bad 'rebuild refusal names its stage'
fi

set +e
TTYD_GITHUB_API_BASE=http://127.0.0.1:9 TTYD_HTTP_TIMEOUT=0.2 \
    "$drift" >"$work/unreachable.log" 2>&1
unreachable_status=$?
set -e
expect 'unreachable drift source returns UNEVALUATED status' test "$unreachable_status" -eq 2
expect 'unreachable drift source is never classified as current' grep -Fq \
    'RESULT UNEVALUATED:' "$work/unreachable.log"
expect 'drift report names the GitHub source' grep -Fq 'GitHub REST API:' "$work/unreachable.log"
expect 'drift report names the npm advisory source' grep -Fq 'npm advisory bulk API:' "$work/unreachable.log"
expect 'operator documentation exposes the two-build verifier' grep -Fq \
    './scripts/verify-ttyd-client-reproducibility.sh' "$root/ttyd/README.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
