#!/usr/bin/env bash
# Secret-free compatibility probe for issue #61's Codex subscription-broker feasibility verdict.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CODEX_BIN=${CODEX_BIN:-codex}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ "$CODEX_BIN" == */* ]]; then
    [[ -x "$CODEX_BIN" ]] || fail "Codex executable is missing or not executable: $CODEX_BIN"
    codex_cmd=$CODEX_BIN
else
    codex_cmd=$(command -v -- "$CODEX_BIN" 2>/dev/null) \
        || fail "Codex executable is unavailable on PATH: $CODEX_BIN"
fi

pin_count=$(grep -Ec '^ARG CODEX_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$ROOT/Dockerfile")
[[ "$pin_count" -eq 1 ]] || fail "Dockerfile must contain exactly one numeric CODEX_VERSION pin"
expected_version=$(sed -n 's/^ARG CODEX_VERSION=//p' "$ROOT/Dockerfile")
actual_version=$("$codex_cmd" --version 2>&1) \
    || fail "could not execute Codex version check"
[[ "$actual_version" == "codex-cli $expected_version" ]] \
    || fail "Codex version mismatch: expected codex-cli $expected_version, got $actual_version"

root_help=$("$codex_cmd" --help 2>&1) || fail "pinned Codex does not expose top-level help"
for marker in 'login' 'logout' 'app-server' '[experimental]' '--remote <ADDR>'; do
    grep -Fq -- "$marker" <<<"$root_help" || fail "pinned Codex top-level help lacks: $marker"
done

login_help=$("$codex_cmd" login --help 2>&1) || fail "pinned Codex does not expose login help"
for marker in 'status' '--device-auth' '--with-api-key' '--with-access-token'; do
    grep -Fq -- "$marker" <<<"$login_help" || fail "pinned Codex login help lacks: $marker"
done

app_server_help=$("$codex_cmd" app-server --help 2>&1) \
    || fail "pinned Codex does not expose app-server help"
grep -Fq 'generate-json-schema' <<<"$app_server_help" \
    || fail "pinned Codex lacks app-server schema generation"

schema_dir="$TMP_DIR/schema"
mkdir "$schema_dir"
"$codex_cmd" app-server generate-json-schema --out "$schema_dir" >/dev/null \
    || fail "pinned Codex could not generate its app-server schema"

python3 - \
    "$schema_dir/v1/InitializeParams.json" \
    "$schema_dir/v2/LoginAccountParams.json" \
    "$schema_dir/v2/GetAccountParams.json" \
    "$schema_dir/ChatgptAuthTokensRefreshResponse.json" \
    "$schema_dir/ClientRequest.json" \
    "$schema_dir/ServerRequest.json" <<'PY'
import json
import sys


def fail(message):
    raise SystemExit(f"FAIL: incompatible Codex app-server auth contract: {message}")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


initialize, login, account, refresh_response, client, server = map(load, sys.argv[1:])

experimental = (
    initialize.get("definitions", {})
    .get("InitializeCapabilities", {})
    .get("properties", {})
    .get("experimentalApi", {})
)
if experimental.get("default") is not False or "experimental" not in experimental.get("description", "").lower():
    fail("initialize no longer marks experimentalApi as an explicit default-off capability")


def login_type(variant):
    values = variant.get("properties", {}).get("type", {}).get("enum", [])
    return values[0] if len(values) == 1 else None


variants = {login_type(item): item for item in login.get("oneOf", [])}
for required_mode in ("chatgpt", "chatgptDeviceCode", "chatgptAuthTokens"):
    if required_mode not in variants:
        fail(f"missing login mode {required_mode}")

external = variants["chatgptAuthTokens"]
external_description = external.get("description", "")
for marker in ("UNSTABLE", "OPENAI INTERNAL USE ONLY", "DO NOT USE"):
    if marker not in external_description:
        fail(f"external-token mode no longer carries marker: {marker}")
required_external = set(external.get("required", []))
if not {"accessToken", "chatgptAccountId", "type"}.issubset(required_external):
    fail("external-token login no longer requires client-supplied token and account id")
access_description = external.get("properties", {}).get("accessToken", {}).get("description", "")
if "supplied by the client" not in access_description:
    fail("schema no longer states that the client supplies the access token")

refresh_description = account.get("properties", {}).get("refreshToken", {}).get("description", "")
for marker in ("external auth mode this flag is ignored", "Clients should refresh tokens themselves"):
    if marker not in refresh_description:
        fail(f"external refresh ownership changed: missing {marker!r}")

refresh_required = set(refresh_response.get("required", []))
if not {"accessToken", "chatgptAccountId"}.issubset(refresh_required):
    fail("external refresh response no longer returns credential material through the client protocol")

server_text = json.dumps(server, separators=(",", ":"))
if "account/chatgptAuthTokens/refresh" not in server_text:
    fail("external-token refresh callback is absent")

methods = set()


def collect_methods(value):
    if isinstance(value, dict):
        title = value.get("title")
        enum = value.get("enum")
        if isinstance(title, str) and title.endswith("RequestMethod") and isinstance(enum, list):
            methods.update(item for item in enum if isinstance(item, str))
        for child in value.values():
            collect_methods(child)
    elif isinstance(value, list):
        for child in value:
            collect_methods(child)


collect_methods(client)
execution_methods = {"thread/shellCommand", "command/exec", "fs/readFile", "fs/writeFile"}
missing_execution = execution_methods - methods
if missing_execution:
    fail(f"app-server execution surface changed; missing {sorted(missing_execution)}")

print("managed_login_modes=chatgpt,chatgptDeviceCode")
print("external_mode=chatgptAuthTokens")
print("external_stability=unstable-openai-internal-only-do-not-use")
print("external_login_payload=accessToken,chatgptAccountId")
print("external_refresh_owner=client")
print("external_refresh_payload=accessToken,chatgptAccountId")
print("app_server_execution_surface=thread/shellCommand,command/exec,fs/readFile,fs/writeFile")
PY

printf 'codex_version=%s\n' "$expected_version"
echo 'cli_lifecycle=login,device-auth,status,logout'
echo 'remote_execution_transport=experimental-app-server'
echo 'verdict=NO-GO'
echo 'reason=no-supported-credential-only-subscription-broker'
