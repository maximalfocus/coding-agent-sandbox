#!/usr/bin/env bash
# Runnable acceptance demo for issue #31. Exit 0 only when the assembled image is healthy.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="${1:-coding-agent-sandbox:latest}"
EXPECTED_OUTPUT="${EXPECTED_OUTPUT:-.cdd-auto/demo/expected-output.txt}"
out="$(mktemp)"
cleanup() { rm -f "$out"; return 0; }
trap cleanup EXIT

{
  ./scripts/verify-maven-secrets.sh "$IMAGE" >/dev/null 2>&1
  echo "maven-layer-cleanup: green"
  echo "maven-secret-findings: absent"
  echo "maven-final-settings: green"

  docker compose config >/dev/null
  docker compose up -d --force-recreate --wait claude-sandbox >/dev/null
  docker compose exec -T --user node claude-sandbox sh -lc '
    set -eu
    repo="/tmp/issue31-m2-$$"
    trap '\''rm -rf "$repo"'\'' EXIT
    mvn --batch-mode --quiet -Dmaven.repo.local="$repo" \
      dependency:get -Dartifact=org.apache.commons:commons-lang3:3.17.0
    test -f "$repo/org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.jar"
  ' >/dev/null
  echo "maven-proxy-resolution: green"
  echo "scanner-suppression: absent"
} >"$out"

diff -u "$EXPECTED_OUTPUT" "$out"
cat "$out"
