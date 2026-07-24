#!/usr/bin/env bash
# Issue #32 acceptance: deterministic verifier checks plus one real live Codex command path.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EXPECTED="${EXPECTED_OUTPUT:-$ROOT/.cdd-auto/demo/expected-output.txt}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

"$ROOT/scripts/test-codex-sandbox-verifier.sh" >>"$TMP"
"$ROOT/scripts/verify-codex-sandbox.sh" \
  --variant "${CODEX_VARIANT:-default}" \
  --container "${CODEX_CONTAINER:-claude-sandbox}" >>"$TMP"

diff -u "$EXPECTED" "$TMP"
cat "$TMP"
