"""
mitmproxy addon — content-aware egress mediation for the Claude Code sandbox.

This is the opt-in "defensive proxy" the SECURITY.md hardening notes describe and the Anthropic
containment write-up recommends: because it terminates TLS, it can mediate on request *content*,
not just the destination hostname (which is all the default tinyproxy can see). For each request,
in order:

  1. Hostname allowlist (parity with the tinyproxy name filter), from $ALLOWLIST. Also closes
     domain-fronting: the decrypted Host is checked, not just the CONNECT target.
  2. GitHub read-only (when $GITHUB_READONLY is on): allow clone/fetch (git-upload-pack, GET/HEAD)
     but deny push (git-receive-pack) and other write methods — so GitHub can't be an exfil channel
     even while it's allowlisted.
  3. Credential containment: strip Authorization / Cookie headers to any host NOT in $AUTH_HOSTS,
     so a sanctioned-but-untrusted extra domain can't harvest tokens the agent holds.

Every decision is logged (verdict, method, host, path-prefix) to stdout for the audit trail
(`docker logs`). Deliberately small and readable — it's a prototype meant to be extended.
"""
import os
from mitmproxy import http


def _domains(env):
    return [d.strip().lower() for d in os.environ.get(env, "").split(",") if d.strip()]


ALLOW = _domains("ALLOWLIST")
AUTH_HOSTS = _domains("AUTH_HOSTS")
GITHUB_HOSTS = ("github.com", "githubusercontent.com")
GITHUB_READONLY = os.environ.get("GITHUB_READONLY", "true").lower() not in ("false", "0", "no", "off")


def _matches(host, domain):
    host = host.lower()
    return host == domain or host.endswith("." + domain)


def _any(host, domains):
    return any(_matches(host, d) for d in domains)


def _log(verdict, method, host, path, reason=""):
    print(f"[mitm] {verdict:5} {method:7} {host}{path[:60]} {reason}".rstrip(), flush=True)


def _deny(flow, msg):
    flow.response = http.Response.make(403, (msg + "\n").encode(), {"Content-Type": "text/plain"})


def request(flow: http.HTTPFlow):
    host = flow.request.pretty_host
    method = flow.request.method
    path = flow.request.path

    # 1. allowlist (on the decrypted Host — defeats domain-fronting)
    if not _any(host, ALLOW):
        _log("DENY", method, host, path, "not-allowlisted")
        return _deny(flow, "Filtered: host not on allowlist")

    # 2. GitHub read-only: permit clone/fetch, block push + write methods
    if GITHUB_READONLY and _any(host, GITHUB_HOSTS):
        if "git-receive-pack" in path or method not in ("GET", "HEAD", "OPTIONS"):
            _log("DENY", method, host, path, "github-readonly")
            return _deny(flow, "Filtered: GitHub is read-only in this sandbox (push blocked)")

    # 3. credential containment: don't leak auth to hosts outside the trusted set
    if not _any(host, AUTH_HOSTS):
        for h in ("authorization", "cookie", "proxy-authorization"):
            if h in flow.request.headers:
                del flow.request.headers[h]
                _log("STRIP", method, host, path, f"removed {h} header")

    _log("ALLOW", method, host, path)
