"""Regression tests for the mitmproxy destination-port gate (issue #47).

Run with ``python3 mitm/test_port_gate.py``. The mitmproxy API is stubbed so the policy can be
tested without Docker or a mitmproxy installation.
"""
import asyncio
import importlib.util
import os
import sys
import types


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(REPO, "mitm", "filter_addon.py")

# Stub mitmproxy before importing the addon.
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

os.environ.update({
    "ALLOWLIST": "example.com",
    "AUTH_HOSTS": "example.com",
    "ALLOWED_CONNECT_PORTS": "443,8443",
    "ANTHROPIC_TOKEN_ISOLATION": "false",
})

spec = importlib.util.spec_from_file_location("filter_addon_port_test", ADDON)
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)


class FakeRequest:
    def __init__(self, port, method="GET", path="/"):
        self.host = "example.com"
        self.host_header = "example.com"
        self.port = port
        self.method = method
        self.path = path
        self.headers = {"host": "example.com"}


class FakeConnection:
    sni = ""


class FakeFlow:
    def __init__(self, port, method="GET", path="/"):
        self.request = FakeRequest(port, method, path)
        self.client_conn = FakeConnection()
        self.response = None


passed = []


def check(name, condition):
    passed.append(condition)
    print(f"  {'PASS' if condition else 'FAIL'}  {name}")


print("== shared CONNECT and request port gate ==")

flow = FakeFlow(8443)
addon.http_connect(flow)
check("CONNECT allows a configured explicit port", flow.response is None)

flow = FakeFlow(8080)
addon.http_connect(flow)
check("CONNECT denies an unconfigured explicit port", flow.response[1] == 403)

flow = FakeFlow(8443, path="/allowed")
asyncio.run(addon.request(flow))
check("plain HTTP allows a configured explicit port", flow.response is None)

flow = FakeFlow(8080, path="/blocked")
asyncio.run(addon.request(flow))
check("plain HTTP denies an unconfigured explicit port", flow.response[1] == 403)
check("plain HTTP denial names the destination-port policy",
      b"destination port not allowed" in flow.response[2])

print(f"\n{sum(passed)}/{len(passed)} checks passed")
sys.exit(0 if all(passed) else 1)
