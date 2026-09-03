#!/usr/bin/env bash
# Deterministic negative and repository-boundary coverage for issue #61.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$ROOT/scripts/probe-codex-subscription-broker.sh"
DOC="$ROOT/docs/codex-subscription-broker-feasibility.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

expect_fail() {
    local fixture=$1 expected=$2
    if CODEX_BIN="$fixture" "$PROBE" >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
        fail "$fixture unexpectedly passed"
    fi
    [[ ! -s "$TMP_DIR/out" ]] || fail "$fixture emitted success-shaped stdout"
    grep -Fq "$expected" "$TMP_DIR/err" || fail "$fixture did not report: $expected"
}

[[ -x "$PROBE" ]] || fail "probe is missing or not executable"
[[ -f "$DOC" ]] || fail "feasibility decision is missing"

cat >"$TMP_DIR/wrong-version" <<'FIXTURE'
#!/usr/bin/env bash
echo 'codex-cli 0.0.0'
FIXTURE
chmod +x "$TMP_DIR/wrong-version"
expect_fail "$TMP_DIR/wrong-version" 'Codex version mismatch'

# This fixture must clear the probe's version gate in order to reach the assertion it is actually
# about, so it has to report whatever the Dockerfile currently pins. Hardcoding the version worked
# only for as long as the pin did not move: adopting 0.153.0 made this negative case fail on
# "Codex version mismatch" instead of "lacks app-server schema generation" - the right refusal for
# the wrong reason, which is a green-looking test proving something else. Derive it instead.
pinned_codex=$(sed -n 's/^ARG CODEX_VERSION=//p' "$ROOT/Dockerfile")
[[ -n "$pinned_codex" ]] || fail "no CODEX_VERSION pin in the Dockerfile to build the fixture from"

cat >"$TMP_DIR/missing-schema" <<FIXTURE
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    echo 'codex-cli $pinned_codex'
elif [[ "\${1:-}" == "--help" ]]; then
    printf '%s\n' 'login' 'logout' 'app-server [experimental]' '--remote <ADDR>'
elif [[ "\${1:-}" == "login" && "\${2:-}" == "--help" ]]; then
    printf '%s\n' 'status' '--device-auth' '--with-api-key' '--with-access-token'
elif [[ "\${1:-}" == "app-server" && "\${2:-}" == "--help" ]]; then
    echo '[experimental] Run the app server'
else
    exit 64
fi
FIXTURE
chmod +x "$TMP_DIR/missing-schema"
expect_fail "$TMP_DIR/missing-schema" 'lacks app-server schema generation'

grep -Fq '# Verdict: NO-GO' "$DOC" || fail "document does not record the NO-GO verdict"
grep -Fq '0.140.0' "$DOC" || fail "document does not pin the assessed Codex version"
grep -Fq '6506579001c322927a3e4bd440563267a7ac6c1f' "$DOC" \
    || fail "document does not pin the assessed upstream commit"
grep -Fq 'OPENAI INTERNAL USE ONLY' "$DOC" \
    || fail "document omits the decisive upstream stability marker"
grep -Fq 'No subscription login, model inference, or token refresh was attempted' "$DOC" \
    || fail "document does not explain the safe live-test stop"

if grep -Eq 'ALLOW_OPENAI|/home/node/\.codex|auth\.openai\.com|api\.openai\.com|chatgpt\.com' \
    "$ROOT/docker-compose.sidecar.yml"; then
    fail "feasibility branch accidentally enabled or routed OpenAI in the sidecar"
fi

echo 'PASS: Codex subscription broker feasibility fails closed (2 negative cases; sidecar remains unchanged)'
