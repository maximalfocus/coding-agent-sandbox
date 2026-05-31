"""
mitmproxy addon — content-aware egress mediation for the Claude Code sandbox.

This is the opt-in "defensive proxy" the SECURITY.md hardening notes describe and the Anthropic
containment write-up recommends: because it terminates TLS, it can mediate on request *content*,
not just the destination hostname (which is all the default tinyproxy can see). For each request,
in order:

  1. Hostname allowlist (parity with the tinyproxy name filter), from $ALLOWLIST. Also closes
     domain-fronting: the decrypted Host is checked, not just the CONNECT target.
  2. Anthropic API hardening (the write-up's strongest pattern — an allowlisted API is attack
     surface, so restrict which functions are reachable and which credential may be used):
       - deny upload/exfil sinks on anthropic hosts ($ANTHROPIC_BLOCK_PATHS, default the Files API)
       - single-credential: strip an injected `x-api-key` when an OAuth bearer is present, so
         malicious code can't route data to a *different* Anthropic account ($ANTHROPIC_SINGLE_CRED)
       - optional strict pin: with $ANTHROPIC_PIN_TOKEN set (sha256 of your provisioned token,
         e.g. a `claude setup-token` value), reject any anthropic call whose credential doesn't match
  3. GitHub read-only (when $GITHUB_READONLY is on): allow clone/fetch (git-upload-pack, GET/HEAD)
     but deny push (git-receive-pack) and other write methods.
  4. Credential containment: strip Authorization / Cookie headers to any host NOT in $AUTH_HOSTS,
     so a sanctioned-but-untrusted extra domain can't harvest tokens.

Every decision is logged (verdict, method, host, path-prefix) to stdout and, if $AUDIT_LOG is set,
appended to that file (the persisted audit trail; see audit.sh --mitm). A prototype — deliberately
small and readable, meant to be extended.
"""
import hashlib
import os
from mitmproxy import http


def _domains(env):
    return [d.strip().lower() for d in os.environ.get(env, "").split(",") if d.strip()]


def _csv(env, default=""):
    return [p.strip() for p in os.environ.get(env, default).split(",") if p.strip()]


def _flag(env, default="true"):
    return os.environ.get(env, default).lower() not in ("false", "0", "no", "off")


ALLOW = _domains("ALLOWLIST")
AUTH_HOSTS = _domains("AUTH_HOSTS")
GITHUB_HOSTS = ("github.com", "githubusercontent.com")
ANTHROPIC_HOSTS = ("anthropic.com",)
GITHUB_READONLY = _flag("GITHUB_READONLY")
ANTHROPIC_BLOCK_PATHS = _csv("ANTHROPIC_BLOCK_PATHS", "/v1/files")
ANTHROPIC_SINGLE_CRED = _flag("ANTHROPIC_SINGLE_CRED")
ANTHROPIC_PIN_TOKEN = os.environ.get("ANTHROPIC_PIN_TOKEN", "").strip().lower()
AUDIT_LOG = os.environ.get("AUDIT_LOG", "").strip()


def _matches(host, domain):
    host = host.lower()
    return host == domain or host.endswith("." + domain)


def _any(host, domains):
    return any(_matches(host, d) for d in domains)


def _fp(secret):
    """Stable, non-reversible fingerprint of a credential (for pinning/logging — never the value)."""
    return hashlib.sha256(secret.encode()).hexdigest()


def _cred(req):
    """The bearer token or api key identifying the caller, if any."""
    auth = req.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return req.headers.get("x-api-key", "").strip()


def _log(verdict, method, host, path, reason=""):
    line = f"[mitm] {verdict:5} {method:7} {host}{path[:60]} {reason}".rstrip()
    print(line, flush=True)
    if AUDIT_LOG:
        try:
            with open(AUDIT_LOG, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


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

    # 2. Anthropic API hardening
    if _any(host, ANTHROPIC_HOSTS):
        # 2a. block upload/exfil sinks (e.g. the Files API)
        for blocked in ANTHROPIC_BLOCK_PATHS:
            if path.startswith(blocked):
                _log("DENY", method, host, path, f"anthropic-blocked-path {blocked}")
                return _deny(flow, "Filtered: this Anthropic API endpoint is blocked in this sandbox")
        # 2b. strict pin — credential must match the provisioned one
        if ANTHROPIC_PIN_TOKEN:
            cred = _cred(flow.request)
            if not cred or _fp(cred) != ANTHROPIC_PIN_TOKEN:
                _log("DENY", method, host, path, "anthropic-token-mismatch")
                return _deny(flow, "Filtered: request credential does not match the pinned token")
        # 2c. single-credential — drop an injected api key when an OAuth bearer is in use
        if ANTHROPIC_SINGLE_CRED:
            auth = flow.request.headers.get("authorization", "")
            if auth.lower().startswith("bearer ") and "x-api-key" in flow.request.headers:
                del flow.request.headers["x-api-key"]
                _log("STRIP", method, host, path, "removed injected x-api-key (oauth in use)")

    # 3. GitHub read-only: permit clone/fetch, block push + write methods
    if GITHUB_READONLY and _any(host, GITHUB_HOSTS):
        if "git-receive-pack" in path or method not in ("GET", "HEAD", "OPTIONS"):
            _log("DENY", method, host, path, "github-readonly")
            return _deny(flow, "Filtered: GitHub is read-only in this sandbox (push blocked)")

    # 4. credential containment: don't leak auth to hosts outside the trusted set
    if not _any(host, AUTH_HOSTS):
        for h in ("authorization", "cookie", "proxy-authorization"):
            if h in flow.request.headers:
                del flow.request.headers[h]
                _log("STRIP", method, host, path, f"removed {h} header")

    _log("ALLOW", method, host, path)
