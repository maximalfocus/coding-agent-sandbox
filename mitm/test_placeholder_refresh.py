"""Focused offline coverage for issue #86's locally-answered placeholder refresh.

The agent CLI refreshes its OAuth credential even though the placeholder carries a far-future expiry.
That refresh presents the placeholder, the provider refuses it, and the CLI zeroes its own credential
file — leaving the sidecar variant able to serve exactly one invocation per claim.

The addon now answers that specific request itself. This suite exists to hold the trigger narrow,
because a broad one would be a genuine problem: it must fire only for a POST to the pinned token
endpoint whose body presents *exactly* the placeholder, and must never intercept a request carrying a
real credential — otherwise contract drift would stop being diagnosable, which `CAS-R172` forbids.
"""

import asyncio
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types

REPO = pathlib.Path(__file__).resolve().parent.parent
ADDON = REPO / "mitm" / "filter_addon.py"
TEMP = pathlib.Path(tempfile.mkdtemp())
VAULT = TEMP / "credentials.json"
AUDIT = TEMP / "audit.log"
PLACEHOLDER = "sandbox-placeholder-do-not-use"
REAL_REFRESH = "test-real-refresh-token-never-log"

mitm = types.ModuleType("mitmproxy")
http = types.ModuleType("mitmproxy.http")


class _Response:
    @staticmethod
    def make(code, body=b"", headers=None):
        return ("RESP", code, body, dict(headers or {}))


class _HTTPFlow:
    pass


http.Response = _Response
http.HTTPFlow = _HTTPFlow
mitm.http = http
sys.modules["mitmproxy"] = mitm
sys.modules["mitmproxy.http"] = http

# A claimed vault, so TOKEN_ISOLATION is meaningfully on.
VAULT.write_text(json.dumps({"claudeAiOauth": {
    "accessToken": "vault-access-never-log", "refreshToken": "vault-refresh-never-log",
    "expiresAt": 99999999999999, "scopes": ["user:inference"], "subscriptionType": "max"}}))
VAULT.chmod(0o600)

os.environ.update({
    "ALLOWLIST": "anthropic.com,claude.com",
    "AUTH_HOSTS": "anthropic.com,claude.com",
    "ANTHROPIC_TOKEN_ISOLATION": "true",
    "TOKEN_SECRET_PATH": str(VAULT),
    "TOKEN_PLACEHOLDER": PLACEHOLDER,
    "OAUTH_TOKEN_URL": "https://platform.claude.com/v1/oauth/token",
    "AUDIT_LOG": str(AUDIT),
    "ALLOWED_CONNECT_PORTS": "443",
    "DEEPSEEK_ENABLED": "false",
})

spec = importlib.util.spec_from_file_location("filter_addon_refresh_test", ADDON)
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)


class Headers(dict):
    def get(self, key, default=""):
        for k, v in self.items():
            if k.lower() == key.lower():
                return v
        return default

    def __contains__(self, key):
        return any(k.lower() == key.lower() for k in self)

    def __delitem__(self, key):
        for k in list(self):
            if k.lower() == key.lower():
                return dict.__delitem__(self, k)
        raise KeyError(key)

    def __setitem__(self, key, value):
        for k in list(self):
            if k.lower() == key.lower():
                dict.__delitem__(self, k)
        dict.__setitem__(self, key, value)


class Request:
    def __init__(self, host, path, method, body):
        self.host = host
        self.host_header = host
        self.port = 443
        self.method = method
        self.path = path
        self._body = body
        self.headers = Headers({"host": host, "Content-Type": "application/json"})

    def get_text(self):
        if self._body is None:
            raise ValueError("no body")
        return self._body


class Connection:
    def __init__(self, sni):
        self.sni = sni


class Flow:
    def __init__(self, host="platform.claude.com", path="/v1/oauth/token", method="POST",
                 refresh=PLACEHOLDER, body=None):
        if body is None and refresh is not None:
            body = json.dumps({"grant_type": "refresh_token", "refresh_token": refresh,
                               "client_id": "cid", "scope": "user:inference"})
        self.request = Request(host, path, method, body)
        self.client_conn = Connection(host)
        self.response = None


results = []


def check(name, condition):
    results.append(bool(condition))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}")


def run(flow):
    asyncio.run(addon.request(flow))
    return flow


def stubbed(flow):
    r = flow.response
    return bool(r) and r[1] == 200 and r[3].get(addon.SANDBOX_FILTER_HEADER) == "stub"


print("== the placeholder refresh is answered locally ==")
f = run(Flow())
check("a placeholder refresh is answered with a 200", stubbed(f))
payload = json.loads(f.response[2].decode())
check("the answer returns the placeholder as the access token",
      payload["access_token"] == PLACEHOLDER)
check("the answer returns the placeholder as the refresh token",
      payload["refresh_token"] == PLACEHOLDER)
check("the answer carries no vault material",
      "vault-access-never-log" not in f.response[2].decode()
      and "vault-refresh-never-log" not in f.response[2].decode())
check("the answer pushes expiry far out", payload["expires_in"] > 60 * 60 * 24 * 365)
check("the answer is marked as sandbox-authored, not a provider reply",
      f.response[3].get(addon.SANDBOX_FILTER_HEADER) == "stub")

print("== the trigger is narrow: anything else passes through ==")
# The one that matters most. A real refresh token must reach the provider, or a retired client
# registration or moved endpoint would stop being diagnosable (CAS-R172).
check("a REAL refresh token is never intercepted",
      not stubbed(run(Flow(refresh=REAL_REFRESH))))
check("an empty refresh token is not intercepted",
      not stubbed(run(Flow(refresh=""))))
check("a different host is not intercepted",
      not stubbed(run(Flow(host="api.anthropic.com"))))
check("a different path on the token host is not intercepted",
      not stubbed(run(Flow(path="/v1/oauth/authorize"))))
check("a GET is not intercepted", not stubbed(run(Flow(method="GET"))))
check("an unparsable body is not intercepted", not stubbed(run(Flow(body="not json"))))
check("a body with no refresh_token is not intercepted",
      not stubbed(run(Flow(body=json.dumps({"grant_type": "authorization_code"})))))
check("a body that is JSON but not an object is not intercepted",
      not stubbed(run(Flow(body="[]"))))

print("== path normalisation cannot be used to dodge or to widen the trigger ==")
check("an encoded token path still matches the pinned endpoint",
      stubbed(run(Flow(path="/v1/%6fauth/token"))))
check("a traversal that resolves elsewhere does not match",
      not stubbed(run(Flow(path="/v1/oauth/token/../authorize"))))

print("== with token isolation off, nothing is intercepted ==")
os.environ["ANTHROPIC_TOKEN_ISOLATION"] = "false"
spec2 = importlib.util.spec_from_file_location("filter_addon_refresh_off", ADDON)
addon_off = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(addon_off)
flow_off = Flow()
asyncio.run(addon_off.request(flow_off))
check("isolation off means no interception at all",
      not (flow_off.response and flow_off.response[1] == 200
           and flow_off.response[3].get(addon_off.SANDBOX_FILTER_HEADER) == "stub"))

print("== the decision is visible in the audit trail ==")
audit = AUDIT.read_text() if AUDIT.exists() else ""
check("the local answer is logged with its own verdict", "STUB" in audit)
check("the audit records no credential material",
      REAL_REFRESH not in audit and "vault-refresh-never-log" not in audit)

passed = sum(results)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
