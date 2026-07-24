#!/usr/bin/env bash
# Runnable acceptance demo for issue #29. Exit 0 only when the assembled image is healthy.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="${1:-coding-agent-sandbox:latest}"
EXPECTED_OUTPUT="${EXPECTED_OUTPUT:-.cdd-auto/demo/expected-output.txt}"
out="$(mktemp)"
cleanup() { rm -f "$out"; }
trap cleanup EXIT

{
  ./scripts/verify-debian-security.sh "$IMAGE" >/dev/null
  echo "debian-package-floors: green"
  echo "issue-29-cves: absent"

  ./scripts/verify-npm-bundle.sh "$IMAGE" >/dev/null
  echo "bundled-agent-clis: green"

  docker compose config >/dev/null
  docker compose up -d --force-recreate --wait claude-sandbox >/dev/null
  docker compose exec -T --user node claude-sandbox sh -lc '
    set -eu
    java -version >/dev/null 2>&1
    mvn -version >/dev/null 2>&1
    playwright --version >/dev/null
  '
  echo "java-maven-playwright: green"

  health="$(docker inspect --format='{{.State.Health.Status}}' claude-sandbox)"
  [ "$health" = healthy ]
  proxy_code="$(docker compose exec -T --user node claude-sandbox \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://example.com/)"
  [ "$proxy_code" = 403 ]

  set +e
  docker compose exec -T --user node claude-sandbox \
    curl --noproxy '*' -fsS --max-time 5 http://example.com/ >/dev/null 2>&1
  direct_rc=$?
  set -e
  [ "$direct_rc" -ne 0 ]
  echo "proxy-health-firewall: green"
} >"$out"

diff -u "$EXPECTED_OUTPUT" "$out"
cat "$out"
