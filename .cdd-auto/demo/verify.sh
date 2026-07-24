#!/usr/bin/env bash
# Runnable acceptance demo for issue #30. Exit 0 only when the assembled boundary is healthy.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="${1:-coding-agent-sandbox:latest}"
EXPECTED_OUTPUT="${EXPECTED_OUTPUT:-.cdd-auto/demo/expected-output.txt}"
out="$(mktemp)"
smoke="cdd30-$RANDOM-$$"
cleanup() {
  docker rm -f "$smoke" >/dev/null 2>&1 || true
  docker image rm "${smoke}:test" >/dev/null 2>&1 || true
  rm -f "$out"
}
trap cleanup EXIT

{
  ./scripts/verify-cli-security.sh "$IMAGE" >/dev/null
  echo "issue-30-findings: absent"

  docker run --rm --user node --entrypoint sh "$IMAGE" -lc '
    set -eu
    gh --version >/dev/null
    docker --version >/dev/null
    docker buildx version >/dev/null
    docker compose version >/dev/null
  '
  echo "source-built-clis: green"

  docker run --rm --user node --entrypoint sh "$IMAGE" -lc '
    set +e
    docker info >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
  '
  echo "default-daemon-access: disabled"

  docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
    -e ENABLE_DOCKER_HOST=true -v /var/run/docker.sock:/var/run/docker.sock \
    -e SMOKE_NAME="$smoke" "$IMAGE" sh -lc '
      set -eu
      tmp="$(mktemp -d)"; trap '\''rm -rf "$tmp"'\'' EXIT
      cp /usr/local/bin/ttyd "$tmp/ttyd"
      printf "FROM scratch\nCOPY ttyd /ttyd\nHEALTHCHECK --interval=1s --retries=3 CMD [\"/ttyd\",\"--version\"]\nENTRYPOINT [\"/ttyd\"]\nCMD [\"-p\",\"7681\",\"/ttyd\",\"--version\"]\n" >"$tmp/Dockerfile"
      docker build -q -t "${SMOKE_NAME}:test" "$tmp" >/dev/null
      docker run -d --name "$SMOKE_NAME" "${SMOKE_NAME}:test" >/dev/null
      i=0
      while [ "$(docker inspect --format='\''{{.State.Health.Status}}'\'' "$SMOKE_NAME")" != healthy ]; do
        i=$((i + 1)); [ "$i" -lt 15 ] || exit 1; sleep 1
      done
      docker rm -f "$SMOKE_NAME" >/dev/null
      docker image rm "${SMOKE_NAME}:test" >/dev/null
    ' >/dev/null
  echo "host-docker-lifecycle: green"
} >"$out"

diff -u "$EXPECTED_OUTPUT" "$out"
cat "$out"
