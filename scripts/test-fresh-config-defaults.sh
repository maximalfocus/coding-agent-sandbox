#!/usr/bin/env bash
# Regression coverage for issue #53's fail-closed fresh configuration.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_contains() {
    local file="$1" text="$2"
    grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_example_default() {
    local key="$1" expected="$2" count value
    count=$(grep -Ec "^[[:space:]]*${key}=" "$ROOT/.env.example")
    [ "$count" -eq 1 ] || fail ".env.example must define $key exactly once (found $count)"
    value=$(sed -n "s/^[[:space:]]*${key}=//p" "$ROOT/.env.example")
    [ "$value" = "$expected" ] || fail ".env.example $key: expected $expected, got $value"
}

assert_compose_value() {
    local rendered="$1" service="$2" key="$3" expected="$4"
    python3 - "$rendered" "$service" "$key" "$expected" <<'PY'
import json
import sys

path, service, key, expected = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
actual = str(config["services"][service]["environment"][key]).lower()
if actual != expected:
    raise SystemExit(f"FAIL: {service} {key}: expected {expected}, got {actual}")
PY
}

assert_example_default ALLOW_TOOL_UPGRADES false
assert_example_default ALLOW_OPENAI false
assert_contains "$ROOT/.env.example" "This is a supply-chain capability grant, so it is off by default."
assert_contains "$ROOT/.env.example" "Off by default (another vendor your code can flow to); set true"

# Both setup paths must create .env only when it is absent, preserving existing user choices.
assert_contains "$ROOT/setup.sh" '[ -f .env ] || { [ -f .env.example ]'
assert_contains "$ROOT/setup.sh" 'cp .env.example .env'
if grep -Eq 'set_env[[:space:]]+.*ALLOW_(OPENAI|TOOL_UPGRADES)' "$ROOT/setup.sh"; then
    fail 'setup.sh rewrites an opt-in egress gate'
fi
assert_contains "$ROOT/setup-windows.ps1" 'if (-not (Test-Path -LiteralPath $envPath)) {'
assert_contains "$ROOT/setup-windows.ps1" 'Copy-Item -LiteralPath $envExamplePath -Destination $envPath'
if grep -Eq 'Set-DotEnvValue[^#]*(ALLOW_OPENAI|ALLOW_TOOL_UPGRADES)' "$ROOT/setup-windows.ps1"; then
    fail 'setup-windows.ps1 rewrites an opt-in egress gate'
fi

# Runtime parsers continue accepting each explicit opt-in, wiring its destinations, and rejecting
# unknown values. Keep these assertions gate-specific so one correct parser cannot mask another.
assert_contains "$ROOT/entrypoint.sh" '${ALLOW_OPENAI:-false}'
assert_contains "$ROOT/entrypoint.sh" 'true|1|yes|on) oai=1;'
assert_contains "$ROOT/entrypoint.sh" '*) oai=0;'
assert_contains "$ROOT/entrypoint.sh" '[ "$oai" = "1" ] && domains+=("${OPENAI_DOMAINS[@]}")'
assert_contains "$ROOT/entrypoint.sh" '${ALLOW_TOOL_UPGRADES:-false}'
assert_contains "$ROOT/entrypoint.sh" 'true|1|yes|on) upgrades=1;'
assert_contains "$ROOT/entrypoint.sh" '*) upgrades=0;'
assert_contains "$ROOT/entrypoint.sh" '[ "$upgrades" = "1" ] && domains+=("${TOOL_UPGRADE_DOMAINS[@]}")'
assert_contains "$ROOT/mitm/entrypoint.sh" '${ALLOW_TOOL_UPGRADES:-false}'
assert_contains "$ROOT/mitm/entrypoint.sh" 'true|1|yes|on) upgrades=1;'
assert_contains "$ROOT/mitm/entrypoint.sh" '*) upgrades=0;'
assert_contains "$ROOT/mitm/entrypoint.sh" '[ "$upgrades" = "1" ] && domains+=("${TOOL_UPGRADE_DOMAINS[@]}")'
assert_contains "$ROOT/mitm/sidecar-entrypoint.sh" '${ALLOW_TOOL_UPGRADES:-false}'
assert_contains "$ROOT/mitm/sidecar-entrypoint.sh" 'true|1|yes|on) domains+=("${TOOL_UPGRADE_DOMAINS[@]}") ;;'
assert_contains "$ROOT/mitm/sidecar-entrypoint.sh" '*) echo "  WARN: unrecognized ALLOW_TOOL_UPGRADES='

# Documentation and every relevant Compose stack must agree on fail-closed defaults.
grep -Eq '^\| `ALLOW_TOOL_UPGRADES` \| `false` \|' "$ROOT/README.md" \
    || fail 'README ALLOW_TOOL_UPGRADES default is not false'
grep -Eq '^\| `ALLOW_OPENAI` \| `false` \|' "$ROOT/README.md" \
    || fail 'README ALLOW_OPENAI default is not false'

docker compose --env-file "$ROOT/.env.example" -f "$ROOT/docker-compose.yml" \
    config --format json > "$TMP_DIR/default.json"
docker compose --env-file "$ROOT/.env.example" -f "$ROOT/docker-compose.mitm.yml" \
    config --format json > "$TMP_DIR/mitm.json"
docker compose --env-file "$ROOT/.env.example" -f "$ROOT/docker-compose.sidecar.yml" \
    config --format json > "$TMP_DIR/sidecar.json"

assert_compose_value "$TMP_DIR/default.json" claude-sandbox ALLOW_TOOL_UPGRADES false
assert_compose_value "$TMP_DIR/default.json" claude-sandbox ALLOW_OPENAI false
assert_compose_value "$TMP_DIR/mitm.json" claude-sandbox-mitm ALLOW_TOOL_UPGRADES false
assert_compose_value "$TMP_DIR/sidecar.json" claude-sandbox-egress ALLOW_TOOL_UPGRADES false

# Compose must fail closed even when no env file supplies the gates: the `:-false` fallbacks
# are the deep default a fresh `.env`-less render relies on (AC5). Render with an empty env
# file (and unset any runner-injected values) so only the Compose fallbacks can answer.
env -u ALLOW_TOOL_UPGRADES -u ALLOW_OPENAI \
    docker compose --env-file /dev/null -f "$ROOT/docker-compose.yml" \
    config --format json > "$TMP_DIR/fallback-default.json"
env -u ALLOW_TOOL_UPGRADES -u ALLOW_OPENAI \
    docker compose --env-file /dev/null -f "$ROOT/docker-compose.mitm.yml" \
    config --format json > "$TMP_DIR/fallback-mitm.json"
env -u ALLOW_TOOL_UPGRADES -u ALLOW_OPENAI \
    docker compose --env-file /dev/null -f "$ROOT/docker-compose.sidecar.yml" \
    config --format json > "$TMP_DIR/fallback-sidecar.json"

assert_compose_value "$TMP_DIR/fallback-default.json" claude-sandbox ALLOW_TOOL_UPGRADES false
assert_compose_value "$TMP_DIR/fallback-default.json" claude-sandbox ALLOW_OPENAI false
assert_compose_value "$TMP_DIR/fallback-mitm.json" claude-sandbox-mitm ALLOW_TOOL_UPGRADES false
assert_compose_value "$TMP_DIR/fallback-sidecar.json" claude-sandbox-egress ALLOW_TOOL_UPGRADES false

ALLOW_TOOL_UPGRADES=true ALLOW_OPENAI=true \
    docker compose --env-file "$ROOT/.env.example" -f "$ROOT/docker-compose.yml" \
    config --format json > "$TMP_DIR/opt-in.json"
assert_compose_value "$TMP_DIR/opt-in.json" claude-sandbox ALLOW_TOOL_UPGRADES true
assert_compose_value "$TMP_DIR/opt-in.json" claude-sandbox ALLOW_OPENAI true

echo 'PASS: fresh POSIX and Windows configuration keeps opt-in egress disabled by default'
