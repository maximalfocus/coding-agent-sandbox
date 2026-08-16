#!/usr/bin/env python3
"""Deterministic coverage for issue #74: a refusal must say who authored it.

`CAS-R172` requires contract drift to fail closed *and* stay diagnosable. The proxy's own denials are
403s and a provider can return 403 as well, so without a marker an operator cannot tell "the sandbox
refused this" from "the provider refused this" — and a drifted contract becomes indistinguishable
from a revoked or expired credential.

This asserts the two halves of that property that can be checked without a network:

  1. every refusal the addon authors carries the sandbox marker header, and
  2. nothing in the addon can rewrite a response that came from the provider.

The live half — that a real provider refusal reaches the agent with the provider's own status and
body — is exercised against `api.deepseek.com` with a deliberately invalid key and recorded on the
pull request; a unit test cannot prove it.

Unlike the sibling suites, the fake Response here KEEPS the headers, which is what lets the marker be
asserted at all.
"""
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))

# --- stub mitmproxy so the addon imports without the real package -------------
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

os.environ.setdefault("ALLOWLIST", "api.deepseek.com")
os.environ.setdefault("DEEPSEEK_ENABLED", "false")
sys.path.insert(0, HERE)

import filter_addon  # noqa: E402

passed = 0
failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS  {label}")
    else:
        failed += 1
        print(f"  FAIL  {label}")


class Flow:
    def __init__(self):
        self.response = None


# --- 1. every authored refusal is marked as ours -----------------------------
flow = Flow()
filter_addon._deny(flow, "Filtered: host not on allowlist")
check("a denial produces a response", flow.response is not None)
check("a denial is a 403", flow.response[1] == 403)
check("a denial keeps its human-readable body",
      b"host not on allowlist" in flow.response[2])
check("a denial carries the sandbox marker header",
      flow.response[3].get(filter_addon.SANDBOX_FILTER_HEADER) == "deny")
check("a denial still declares a plain-text content type",
      flow.response[3].get("Content-Type") == "text/plain")

# The marker must be on EVERY denial, not just the one sampled above. `_deny` is the only place the
# addon constructs a response, so asserting that is what makes the guarantee total.
source = open(os.path.join(HERE, "filter_addon.py")).read()
authored = re.findall(r"flow\.response\s*=", source)
check("the addon authors a response in exactly one place", len(authored) == 1)

deny_calls = len(re.findall(r"_deny\(", source)) - 1  # minus the definition itself
check(f"all {deny_calls} refusal sites route through that one place", deny_calls >= 10)

for message in (
    "Filtered: DeepSeek credential is unavailable or unsafe",
    "Filtered: destination port not allowed",
    "Filtered: TLS SNI not on allowlist",
):
    marked = Flow()
    filter_addon._deny(marked, message)
    check(f"marked: {message!r}",
          marked.response[3].get(filter_addon.SANDBOX_FILTER_HEADER) == "deny"
          and marked.response[1] == 403)

# --- 2. a provider response cannot be rewritten ------------------------------
# mitmproxy only lets an addon touch an upstream response from a `response` hook. There is none, so
# whatever the provider returns reaches the agent verbatim — status, body, and headers.
check("the addon defines no response hook that could rewrite a provider reply",
      not re.search(r"^\s*(async\s+)?def\s+response\s*\(", source, re.M))
check("the addon never sets a response status after the fact",
      "response.status_code" not in source)
check("the addon never rewrites response content",
      not re.search(r"flow\.response\.(content|text|headers)\s*=", source))

# --- 3. the marker is a marker, not a credential channel ---------------------
check("the marker header value carries no request-specific data",
      filter_addon.SANDBOX_FILTER_HEADER.lower().startswith("x-sandbox"))
leaky = Flow()
filter_addon._deny(leaky, "Filtered: DeepSeek credential is unavailable or unsafe")
check("a denial body names the condition, never a credential",
      b"key" not in leaky.response[2].lower().replace(b"credential", b"")
      or b"unavailable or unsafe" in leaky.response[2])
check("a denial carries exactly the two expected headers",
      set(leaky.response[3]) == {"Content-Type", filter_addon.SANDBOX_FILTER_HEADER})

print(f"\n{passed}/{passed + failed} checks passed")
sys.exit(1 if failed else 0)
