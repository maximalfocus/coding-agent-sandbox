"""Coverage for issue #102: the vault's refresh POST must identify itself.

Unidentified, it never reached the OAuth endpoint. Cloudflare fingerprinted the client and answered
`403` with `error code: 1010` as `text/plain` — a client ban, not a provider auth error, and not
about the credential at all. `TokenVault` caught it, logged `ERROR`, and kept serving the still-valid
access token, which is the right failure mode and is exactly why nothing surfaced: the sidecar Claude
path kept working until the token expired ~8 hours after the claim, and then stopped.

So the assertion that matters is small and specific — the request carries a `User-Agent` — and the
ones around it exist to keep the fix from drifting into something worse: impersonating a browser, or
losing the fail-closed behaviour that kept this from being an outage instead of a delay.

Runs offline. It intercepts the request rather than sending one, so no provider is contacted and no
credential is used.
"""

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
ADDON = REPO / "mitm" / "filter_addon.py"
PINS = REPO / "docs" / "provider-contracts.md"
TEMP = pathlib.Path(tempfile.mkdtemp())
VAULT = TEMP / "credentials.json"
AUDIT = TEMP / "audit.log"

mitm = types.ModuleType("mitmproxy")
http = types.ModuleType("mitmproxy.http")


class _Response:
    @staticmethod
    def make(code, body=b"", headers=None):
        return ("RESP", code, body, dict(headers or {}))


http.Response = _Response
http.HTTPFlow = type("HTTPFlow", (), {})
mitm.http = http
sys.modules["mitmproxy"] = mitm
sys.modules["mitmproxy.http"] = http

VAULT.write_text(json.dumps({"claudeAiOauth": {
    "accessToken": "vault-access-never-log", "refreshToken": "vault-refresh-never-log",
    "expiresAt": 1, "scopes": ["user:inference"], "clientId": "test-client-id",
    "subscriptionType": "max"}}))
VAULT.chmod(0o600)

os.environ.update({
    "ALLOWLIST": "anthropic.com", "AUTH_HOSTS": "anthropic.com",
    "ANTHROPIC_TOKEN_ISOLATION": "true", "TOKEN_SECRET_PATH": str(VAULT),
    "TOKEN_PLACEHOLDER": "sandbox-placeholder-do-not-use",
    "OAUTH_TOKEN_URL": "https://platform.claude.com/v1/oauth/token",
    "AUDIT_LOG": str(AUDIT), "ALLOWED_CONNECT_PORTS": "443", "DEEPSEEK_ENABLED": "false",
})

spec = importlib.util.spec_from_file_location("filter_addon_ua_test", ADDON)
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)

results = []


def check(name, condition, detail=""):
    results.append(bool(condition))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else '  <- ' + str(detail)}")


# --- capture the request the vault would send -------------------------------
captured = {}


class _FakeOpener:
    def open(self, req, timeout=None):
        captured["url"] = req.full_url
        captured["headers"] = {k.lower(): v for k, v in req.headers.items()}
        captured["body"] = json.loads(req.data.decode())
        raise urllib.error.HTTPError(req.full_url, 503, "stop here", {}, None)


addon.urllib.request.build_opener = lambda *a, **k: _FakeOpener()

vault = addon.TokenVault(str(VAULT))
vault._load()
try:
    vault._refresh_blocking()
except Exception:
    pass  # the fake opener always stops; we only wanted the request it built

print("== the refresh identifies itself ==")
check("the refresh request was built at all", bool(captured), captured)
ua = captured.get("headers", {}).get("user-agent", "")
check("it carries a User-Agent", bool(ua), captured.get("headers"))
check("the User-Agent is not urllib's default", "python-urllib" not in ua.lower(), ua)
check("it still declares JSON", captured.get("headers", {}).get("content-type") == "application/json")
check("it still POSTs to the pinned endpoint",
      captured.get("url") == "https://platform.claude.com/v1/oauth/token", captured.get("url"))

print("== it identifies this software, rather than impersonating a browser ==")
# A browser string also cleared the block when probed. Claiming to be Chrome from a proxy would be
# the wrong answer, so the fix must not quietly become that.
for browser in ("mozilla", "chrome", "safari", "applewebkit", "gecko"):
    check(f"the User-Agent does not claim to be a browser ({browser})", browser not in ua.lower(), ua)

print("== the grant is unchanged ==")
body = captured.get("body", {})
check("grant_type is still refresh_token", body.get("grant_type") == "refresh_token", body.get("grant_type"))
check("the refresh token is still sent", body.get("refresh_token") == "vault-refresh-never-log")
check("the client id is still sent", body.get("client_id") == "test-client-id")
check("the User-Agent did not leak into the body", "user" not in json.dumps(body).lower().replace("user:inference", ""))

print("== no credential material rides in the headers ==")
joined = " ".join(captured.get("headers", {}).values())
check("no access token in the headers", "vault-access-never-log" not in joined)
check("no refresh token in the headers", "vault-refresh-never-log" not in joined)

print("== it is overridable, so a provider change needs no code edit ==")
check("the value comes from the environment when set",
      "TOKEN_REFRESH_USER_AGENT" in ADDON.read_text())
check("a default is compiled in, so an unset environment still identifies itself",
      bool(addon.REFRESH_USER_AGENT))

print("== the dependency is pinned and drift-checked ==")
pins = PINS.read_text()
check("the User-Agent is recorded as a provider contract",
      "claude.oauth-refresh-user-agent" in pins)
check("the pinned value matches what the addon sends",
      addon.REFRESH_USER_AGENT in pins, addon.REFRESH_USER_AGENT)
check("the record says what breaks, naming the observed failure",
      "1010" in pins and "text/plain" in pins)

print("== a refresh failure still fails closed ==")
# This is what kept the defect from being an outage: on failure the proxy keeps serving the token it
# has and never falls back to anything the agent supplied. Losing that would be worse than the bug.
source = ADDON.read_text()
refresh_fn = source[source.index("async def token"):]
check("a failed refresh is logged rather than raised", "refresh failed" in refresh_fn)
check("the existing token is still returned after a failure",
      refresh_fn.index("return self._data.get(\"accessToken\")") > refresh_fn.index("refresh failed"))
check("the audit line for a refresh carries no credential",
      "accessToken" not in refresh_fn[:refresh_fn.index("return self._data")].replace(
          'self._data.get("accessToken")', ""))

passed = sum(results)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
