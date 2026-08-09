"""Standalone logic test for the token-isolation feature (run: `python3 mitm/test_token_isolation.py`
from anywhere). No Docker, no mitmproxy install needed: we stub the `mitmproxy` module, point the
vault/claim at temp files, and stub the OAuth refresh and the user/chown calls. Exercises the parts
most likely to hide bugs: vault expiry/refresh/rotation/persist, the placeholder->real injection,
and claim-token's move/idempotency. The container build + the firewall/CA wiring are out of scope
here — verify those by actually running the mitm stack (see README / SECURITY.md)."""
import asyncio, importlib.util, json, os, sys, time, types, tempfile, pwd as _pwd

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(REPO, "mitm", "filter_addon.py")
CLAIM = os.path.join(REPO, "mitm", "claim-token")
TMP = tempfile.mkdtemp()
SECRET = os.path.join(TMP, "vault.json")
NODE = os.path.join(TMP, "node.json")

# --- stub mitmproxy so filter_addon imports cleanly ---
mitm = types.ModuleType("mitmproxy")
http = types.ModuleType("mitmproxy.http")
class _Resp:
    @staticmethod
    def make(code, body=b"", headers=None): return ("RESP", code, body)
class _HTTPFlow: ...
http.Response = _Resp
http.HTTPFlow = _HTTPFlow
mitm.http = http
sys.modules["mitmproxy"] = mitm
sys.modules["mitmproxy.http"] = http

os.environ.update({
    "ANTHROPIC_TOKEN_ISOLATION": "true",
    "TOKEN_SECRET_PATH": SECRET,
    "TOKEN_PLACEHOLDER": "PLACEHOLDER",
    "TOKEN_REFRESH_SKEW": "600",
    "AUTH_HOSTS": "anthropic.com,claude.com",
    "ALLOWLIST": "anthropic.com,claude.com",
})

spec = importlib.util.spec_from_file_location("filter_addon", ADDON)
fa = importlib.util.module_from_spec(spec); spec.loader.exec_module(fa)

passed = []
def check(name, cond):
    passed.append(cond)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")

now_ms = lambda: int(time.time() * 1000)

print("== TokenVault ==")
v = fa.TokenVault(SECRET)

# 1. unclaimed -> None (lets initial /login pass through)
check("unclaimed vault returns None", asyncio.run(v.token()) is None)

# 2. claimed + valid (far-future expiry) -> returns access token, NO refresh
json.dump({"claudeAiOauth": {"accessToken": "REAL-A", "refreshToken": "REAL-R",
          "expiresAt": now_ms() + 3600_000, "scopes": ["user:inference"], "clientId": "cid"}},
          open(SECRET, "w"))
check("valid token returned as-is", asyncio.run(v.token()) == "REAL-A")

# 3. near-expiry -> triggers refresh; assert request shape + proxy bypass + rotation persisted
captured = {}
class FakeResp:
    def __init__(self, payload): self._p = json.dumps(payload).encode()
    def read(self): return self._p
    def __enter__(self): return self
    def __exit__(self, *a): return False
class FakeOpener:
    def open(self, req, timeout=None):
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data.decode())
        captured["ct"] = req.headers.get("Content-type")
        return FakeResp({"access_token": "NEW-A", "refresh_token": "NEW-R", "expires_in": 3600})
def fake_build_opener(handler):
    captured["proxies"] = handler.proxies   # ProxyHandler({}) -> {}
    return FakeOpener()
fa.urllib.request.build_opener = fake_build_opener

json.dump({"claudeAiOauth": {"accessToken": "OLD-A", "refreshToken": "OLD-R",
          "expiresAt": now_ms() + 60_000, "scopes": ["user:inference", "user:profile"],
          "clientId": "cid"}}, open(SECRET, "w"))
v2 = fa.TokenVault(SECRET)
tok = asyncio.run(v2.token())
check("refresh returns NEW access token", tok == "NEW-A")
check("refresh hit the OAuth token URL", captured["url"] == fa.OAUTH_TOKEN_URL)
check("grant_type=refresh_token", captured["body"]["grant_type"] == "refresh_token")
check("sent the OLD refresh token", captured["body"]["refresh_token"] == "OLD-R")
check("client_id forwarded", captured["body"]["client_id"] == "cid")
check("scope space-joined", captured["body"]["scope"] == "user:inference user:profile")
check("Content-Type json", captured["ct"] == "application/json")
check("proxy bypassed (empty ProxyHandler)", captured["proxies"] == {})
saved = json.load(open(SECRET))["claudeAiOauth"]
check("rotated refresh token PERSISTED to vault", saved["refreshToken"] == "NEW-R")
check("vault file is 0600", oct(os.stat(SECRET).st_mode)[-3:] == "600")
check("new expiry is in the future", saved["expiresAt"] > now_ms())

# 4. refresh failure -> keeps serving the existing token (fail-open on refresh, not on auth)
def boom(handler):
    class E:
        def open(self, *a, **k): raise RuntimeError("network down")
    return E()
fa.urllib.request.build_opener = boom
json.dump({"claudeAiOauth": {"accessToken": "STILL-A", "refreshToken": "R",
          "expiresAt": now_ms() + 60_000, "scopes": [], "clientId": "c"}}, open(SECRET, "w"))
v3 = fa.TokenVault(SECRET)
check("refresh failure still yields a token", asyncio.run(v3.token()) == "STILL-A")

print("== request() injection ==")
class FakeHeaders(dict):  # emulate mitmproxy's case-insensitive Headers (set replaces any case)
    def get(self, k, d=""):
        for kk, vv in self.items():
            if kk.lower() == k.lower(): return vv
        return d
    def __contains__(self, k): return any(kk.lower() == k.lower() for kk in self)
    def __delitem__(self, k):
        for kk in list(self):
            if kk.lower() == k.lower(): return dict.__delitem__(self, kk)
    def __setitem__(self, k, val):
        for kk in list(self):
            if kk.lower() == k.lower(): dict.__delitem__(self, kk)
        dict.__setitem__(self, k, val)
class FakeReq:
    def __init__(self, headers): self.host="api.anthropic.com"; self.method="POST"; self.path="/v1/messages"; self.headers=FakeHeaders(headers); self.host_header="api.anthropic.com"
class FakeConn: sni="api.anthropic.com"
class FakeFlow:
    def __init__(self, headers): self.request=FakeReq(headers); self.client_conn=FakeConn(); self.response=None

# vault populated with a known token
json.dump({"claudeAiOauth": {"accessToken": "INJECT-ME", "refreshToken": "R",
          "expiresAt": now_ms() + 3600_000, "scopes": [], "clientId": "c"}}, open(SECRET, "w"))
fa.VAULT = fa.TokenVault(SECRET)
f = FakeFlow({"Authorization": "Bearer PLACEHOLDER", "x-api-key": "sneaky", "host": "api.anthropic.com"})
asyncio.run(fa.request(f))
check("placeholder swapped for real vault token", f.request.headers.get("authorization") == "Bearer INJECT-ME")
check("x-api-key stripped on inject", "x-api-key" not in f.request.headers)
check("request not denied (no 403 response)", f.response is None)

print("== claim-token transform ==")
# stub user lookups / chown so it runs off-container
os.chown = lambda *a, **k: None
_fake = type("P", (), {"pw_uid": 0, "pw_gid": 0})()
import pwd; pwd.getpwnam = lambda n: _fake
os.environ["NODE_CRED_PATH"] = NODE
os.environ["TOKEN_SECRET_PATH"] = SECRET2 = os.path.join(TMP, "vault2.json")
import importlib.machinery
ct = importlib.machinery.SourceFileLoader("claim_token", CLAIM).load_module()
# claim-token now validates the login with the real OAuth server before vaulting (issue #44 C1b);
# tests stub that grant so the suite stays offline. The success stub echoes the login back (no
# rotation), matching the legacy "moved as-is" behavior; dedicated tests below exercise the
# refusal and rotation paths.
ct._validate_refresh = lambda oauth: dict(oauth)

# no node creds -> no-op
if os.path.exists(NODE): os.remove(NODE)
check("no creds -> no-op (rc 0)", ct.main() == 0)
check("no vault written on no-op", not os.path.exists(SECRET2))

# real login present -> moved to vault, placeholder installed
real = {"claudeAiOauth": {"accessToken": "REAL", "refreshToken": "REALR",
        "expiresAt": now_ms() + 1000, "scopes": ["user:inference"], "subscriptionType": "max", "clientId": "cid"}}
json.dump(real, open(NODE, "w"))
ct.main()
vault = json.load(open(SECRET2))["claudeAiOauth"]
node = json.load(open(NODE))["claudeAiOauth"]
check("real token moved to vault", vault["accessToken"] == "REAL" and vault["refreshToken"] == "REALR")
check("node accessToken is placeholder", node["accessToken"] == "PLACEHOLDER")
check("node refreshToken is placeholder", node["refreshToken"] == "PLACEHOLDER")
check("node expiry pushed far future", node["expiresAt"] > now_ms() + 5*365*24*3600*1000)
check("non-secret fields preserved (subscriptionType)", node["subscriptionType"] == "max")
check("vault file 0600", oct(os.stat(SECRET2).st_mode)[-3:] == "600")

# idempotent: re-run sees placeholder, does nothing
before = open(SECRET2).read()
ct.main()
check("re-run is idempotent (vault unchanged)", open(SECRET2).read() == before)

print("== claim-token provenance gate (issue #44 C1b) ==")
# fake login -> the refresh grant is refused -> nothing is vaulted, node login untouched
def _refuse(oauth):
    raise ValueError("invalid_grant")
ct._validate_refresh = _refuse
fake = {"claudeAiOauth": {"accessToken": "FAKE-A", "refreshToken": "FAKE-R",
        "expiresAt": now_ms() + 1000, "scopes": [], "clientId": "cid"}}
json.dump(fake, open(NODE, "w"))
if os.path.exists(SECRET2): os.remove(SECRET2)
check("fake login refused (rc 1)", ct.main() == 1)
check("no vault written for fake login", not os.path.exists(SECRET2))
check("node fake login untouched", json.load(open(NODE))["claudeAiOauth"]["accessToken"] == "FAKE-A")

# validated (rotated) tokens are what gets vaulted, not the raw node bytes
ct._validate_refresh = lambda oauth: dict(oauth, accessToken="ROTATED-A",
                                          refreshToken="ROTATED-R", expiresAt=now_ms() + 3600_000)
json.dump(fake, open(NODE, "w"))
if os.path.exists(SECRET2): os.remove(SECRET2)
check("valid login claimed (rc 0)", ct.main() == 0)
vault3 = json.load(open(SECRET2))["claudeAiOauth"]
check("vault holds the VALIDATED tokens", vault3["accessToken"] == "ROTATED-A" and vault3["refreshToken"] == "ROTATED-R")

print("== claim-token _write symlink hardening (issue #44 C1a) ==")
_wd = tempfile.mkdtemp()
victim = os.path.join(_wd, "victim")
with open(victim, "w") as fh: fh.write("ORIGINAL")
target = os.path.join(_wd, "creds.json")
# pre-placed .tmp symlink -> exclusive no-follow create must refuse (EEXIST)
os.symlink(victim, target + ".tmp")
try:
    ct._write(target, {"a": 1}, "node")
    check("pre-placed .tmp symlink refused", False)
except OSError:
    check("pre-placed .tmp symlink refused", True)
check("symlink victim untouched", open(victim).read() == "ORIGINAL")
check("target not created", not os.path.exists(target))
# symlinked parent directory -> O_NOFOLLOW dir open must refuse (ELOOP)
real_dir = os.path.join(_wd, "real")
os.makedirs(real_dir)
link_dir = os.path.join(_wd, "real-link")
os.symlink(real_dir, link_dir)
try:
    ct._write(os.path.join(link_dir, "creds.json"), {"a": 1}, "node")
    check("symlinked parent dir refused", False)
except OSError:
    check("symlinked parent dir refused", True)
check("nothing written through symlinked dir", os.listdir(real_dir) == [])
# normal write still works and lands mode 0600
ok_path = os.path.join(_wd, "ok.json")
ct._write(ok_path, {"k": "v"}, "node")
check("normal write persists", json.load(open(ok_path)) == {"k": "v"})
check("normal write mode 0600", oct(os.stat(ok_path).st_mode)[-3:] == "600")

print(f"\n{sum(passed)}/{len(passed)} checks passed")
sys.exit(0 if all(passed) else 1)
