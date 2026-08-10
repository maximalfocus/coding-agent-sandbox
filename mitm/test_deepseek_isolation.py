"""Focused offline coverage for issue #59's exact-host DeepSeek key isolation."""

import asyncio
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import types


REPO = pathlib.Path(__file__).resolve().parent.parent
ADDON = REPO / "mitm" / "filter_addon.py"
MANAGER = REPO / "mitm" / "deepseek-key"
TEMP = pathlib.Path(tempfile.mkdtemp())
SECRET_DIR = TEMP / "deepseek"
SECRET = SECRET_DIR / "api-key"
AUDIT = TEMP / "audit.log"
REAL_KEY = "test-deepseek-secret-never-log"
PLACEHOLDER = "sandbox-placeholder-do-not-use"


mitm = types.ModuleType("mitmproxy")
http = types.ModuleType("mitmproxy.http")


class _Response:
    @staticmethod
    def make(code, body=b"", headers=None):
        return ("RESP", code, body)


class _HTTPFlow:
    pass


http.Response = _Response
http.HTTPFlow = _HTTPFlow
mitm.http = http
sys.modules["mitmproxy"] = mitm
sys.modules["mitmproxy.http"] = http

SECRET_DIR.mkdir(mode=0o700)
SECRET.write_text(REAL_KEY, encoding="utf-8")
SECRET.chmod(0o600)
os.environ.update({
    "ALLOWLIST": "anthropic.com,example.org",
    "AUTH_HOSTS": "anthropic.com",
    "EXACT_ALLOW_HOSTS": "api.deepseek.com",
    "EXACT_AUTH_HOSTS": "api.deepseek.com",
    "DEEPSEEK_ENABLED": "true",
    "DEEPSEEK_KEY_PATH": str(SECRET),
    "TOKEN_PLACEHOLDER": PLACEHOLDER,
    "ANTHROPIC_TOKEN_ISOLATION": "false",
    "AUDIT_LOG": str(AUDIT),
    "ALLOWED_CONNECT_PORTS": "443",
})

spec = importlib.util.spec_from_file_location("filter_addon_deepseek_test", ADDON)
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)


class Headers(dict):
    def get(self, key, default=""):
        for current, value in self.items():
            if current.lower() == key.lower():
                return value
        return default

    def __contains__(self, key):
        return any(current.lower() == key.lower() for current in self)

    def __delitem__(self, key):
        for current in list(self):
            if current.lower() == key.lower():
                return dict.__delitem__(self, current)
        raise KeyError(key)

    def __setitem__(self, key, value):
        for current in list(self):
            if current.lower() == key.lower():
                dict.__delitem__(self, current)
        dict.__setitem__(self, key, value)


class Request:
    def __init__(self, host, port=443, header_host=None):
        self.host = host
        self.host_header = header_host if header_host is not None else host
        self.port = port
        self.method = "POST"
        self.path = "/chat/completions"
        self.headers = Headers({
            "host": self.host_header,
            "Authorization": "Bearer agent-controlled",
            "x-api-key": "agent-api-key",
            "api-key": "agent-generic-api-key",
            "Cookie": "agent-cookie",
            "Proxy-Authorization": "agent-proxy-key",
        })


class Connection:
    def __init__(self, sni):
        self.sni = sni


class Flow:
    def __init__(self, host, port=443, header_host=None, sni=None):
        self.request = Request(host, port, header_host)
        self.client_conn = Connection(host if sni is None else sni)
        self.response = None


results = []


def check(name, condition):
    results.append(bool(condition))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}")


def run(flow):
    asyncio.run(addon.request(flow))
    return flow


print("== exact-host routing and overwrite ==")
flow = run(Flow("API.DEEPSEEK.COM.", header_host="api.deepseek.com.", sni="Api.DeepSeek.Com."))
check("DNS case and trailing dot normalize to the exact host", flow.response is None)
check("agent bearer is overwritten from sidecar storage",
      flow.request.headers.get("authorization") == f"Bearer {REAL_KEY}")
check("conflicting API key is removed", "x-api-key" not in flow.request.headers)
check("alternate API key header is removed", "api-key" not in flow.request.headers)
check("cookie and proxy credentials are removed",
      "cookie" not in flow.request.headers and "proxy-authorization" not in flow.request.headers)

for near_miss in ("deepseek.com", "evil.api.deepseek.com", "api.deepseek.com.evil"):
    denied = run(Flow(near_miss))
    check(f"near-miss {near_miss} denied", denied.response is not None and denied.response[1] == 403)

wrong_header = run(Flow("api.deepseek.com", header_host="evil.api.deepseek.com"))
check("near-miss Host header denied", wrong_header.response is not None and wrong_header.response[1] == 403)
wrong_sni = run(Flow("api.deepseek.com", sni="evil.api.deepseek.com"))
check("near-miss SNI denied", wrong_sni.response is not None and wrong_sni.response[1] == 403)
wrong_port = Flow("api.deepseek.com", port=8443)
addon.http_connect(wrong_port)
check("DeepSeek on a non-443 port denied at CONNECT", wrong_port.response is not None and wrong_port.response[1] == 403)

print("== cross-provider and failure containment ==")
other = run(Flow("example.org", sni="example.org"))
check("another allowed provider receives no DeepSeek key",
      other.request.headers.get("authorization") == "" and REAL_KEY not in repr(other.request.headers))

SECRET.unlink()
missing = run(Flow("api.deepseek.com"))
check("missing key denies the request", missing.response is not None and missing.response[1] == 403)
SECRET.write_text(REAL_KEY, encoding="utf-8")
SECRET.chmod(0o644)
unsafe = run(Flow("api.deepseek.com"))
check("unsafe key permissions deny the request", unsafe.response is not None and unsafe.response[1] == 403)
SECRET.unlink()
symlink_target = TEMP / "symlink-target"
symlink_target.write_text(REAL_KEY, encoding="utf-8")
symlink_target.chmod(0o600)
SECRET.symlink_to(symlink_target)
symlinked = run(Flow("api.deepseek.com"))
check("symlinked key path denies the request", symlinked.response is not None and symlinked.response[1] == 403)
SECRET.unlink()
SECRET_DIR.rmdir()
directory_target = TEMP / "directory-target"
directory_target.mkdir(mode=0o700)
(directory_target / "api-key").write_text(REAL_KEY, encoding="utf-8")
(directory_target / "api-key").chmod(0o600)
SECRET_DIR.symlink_to(directory_target, target_is_directory=True)
symlinked_directory = run(Flow("api.deepseek.com"))
check("symlinked secret directory denies the request",
      symlinked_directory.response is not None and symlinked_directory.response[1] == 403)
SECRET_DIR.unlink()
SECRET_DIR.mkdir(mode=0o700)
SECRET.write_text(REAL_KEY, encoding="utf-8")
SECRET.chmod(0o600)

audit_text = AUDIT.read_text(encoding="utf-8")
check("audit records injection without the key", "INJECT" in audit_text and REAL_KEY not in audit_text)
check("audit records a redacted secret failure", "deepseek-key-unavailable-or-unsafe" in audit_text)

os.environ["DEEPSEEK_ENABLED"] = "unexpected"
os.environ["EXACT_ALLOW_HOSTS"] = "api.deepseek.com"
os.environ["EXACT_AUTH_HOSTS"] = "api.deepseek.com"
disabled_spec = importlib.util.spec_from_file_location("filter_addon_deepseek_disabled_test", ADDON)
disabled_addon = importlib.util.module_from_spec(disabled_spec)
disabled_spec.loader.exec_module(disabled_addon)
disabled = Flow("api.deepseek.com")
asyncio.run(disabled_addon.request(disabled))
check("invalid runtime gate remains off even if exact-host env is present",
      disabled.response is not None and disabled.response[1] == 403)

print("== provision, rotation, validation, and revocation helper ==")
managed = TEMP / "managed" / "api-key"


def manager(command, supplied=None, path=managed):
    return subprocess.run(
        [sys.executable, str(MANAGER), command, "--path", str(path)],
        input=supplied,
        text=True,
        capture_output=True,
        check=False,
    )


first = manager("store", "first-key")
check("provision succeeds without echoing the key",
      first.returncode == 0 and "first-key" not in first.stdout + first.stderr)
check("provision writes 0600 key in 0700 directory",
      managed.stat().st_mode & 0o777 == 0o600 and managed.parent.stat().st_mode & 0o777 == 0o700)
rotated = manager("store", "rotated-key")
check("rotation atomically replaces the value", rotated.returncode == 0 and managed.read_text() == "rotated-key")
status = manager("status")
check("status validates without revealing the key",
      status.returncode == 0 and "ready" in status.stdout and "rotated-key" not in status.stdout)
managed.chmod(0o644)
check("manager rejects unsafe permissions", manager("validate").returncode == 1)
managed.chmod(0o600)
revoked = manager("delete")
check("revocation removes only the key file", revoked.returncode == 0 and not managed.exists() and managed.parent.is_dir())
managed_victim = TEMP / "managed-victim"
managed_victim.write_text("victim-contents", encoding="utf-8")
managed.symlink_to(managed_victim)
check("manager rejects a symlink without deleting its target",
      manager("validate").returncode == 1 and manager("delete").returncode == 1
      and managed_victim.read_text(encoding="utf-8") == "victim-contents")
managed.unlink()
check("empty and placeholder values are rejected",
      manager("store", "").returncode == 1 and manager("store", PLACEHOLDER).returncode == 1)
check("multiple lines are rejected", manager("store", "first\nsecond\n").returncode == 1)
linked_target = TEMP / "linked-directory-target"
linked_target.mkdir(mode=0o700)
linked_directory = TEMP / "linked-directory"
linked_directory.symlink_to(linked_target, target_is_directory=True)
check("manager rejects a symlinked secret directory before writing",
      manager("store", "should-not-write", linked_directory / "api-key").returncode == 1
      and not (linked_target / "api-key").exists())

print(f"\n{sum(results)}/{len(results)} checks passed")
raise SystemExit(0 if all(results) else 1)
