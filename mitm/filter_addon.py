"""
mitmproxy addon — content-aware egress mediation for the Claude Code sandbox.

This is the opt-in "defensive proxy" the SECURITY.md hardening notes describe and the Anthropic
containment write-up recommends: because it terminates TLS, it can mediate on request *content*,
not just the destination hostname (which is all the default tinyproxy can see).

Authorization is keyed on `request.host` — the actual routing target (CONNECT authority or
absolute-URI host) — NOT `request.pretty_host`, which prefers the spoofable `Host` header. CONNECT
itself is gated in `http_connect()` so tunnels (incl. raw-TCP, which is also disabled in the
entrypoint) can't reach a non-allowlisted host:port before `request()` would ever run.

For each request, in order:
  1. Hostname allowlist (parity with the tinyproxy name filter), from $ALLOWLIST.
  2. Anthropic API hardening (the write-up's strongest pattern — an allowlisted API is attack
     surface, so restrict which functions and which credential are reachable on anthropic hosts):
       - deny upload/exfil sinks ($ANTHROPIC_BLOCK_PATHS, default the Files API) on the *normalized,
         percent-decoded* path, so encoded variants can't slip through
       - single-credential: strip any `x-api-key` on anthropic hosts ($ANTHROPIC_SINGLE_CRED) — the
         subscription/`setup-token` path authenticates with an OAuth bearer, so an injected api key
         is never legitimate and would route data to a different account. (API-key users: set false.)
       - optional strict pin: with $ANTHROPIC_PIN_TOKEN set (sha256 of your provisioned token),
         reject any anthropic call whose credential doesn't match.
  3. GitHub read-only (when $GITHUB_READONLY is on): allow clone/fetch (GET/HEAD and the
     `git-upload-pack` POST negotiation) but deny push (`git-receive-pack`) and other writes.
  4. Credential containment: strip Authorization / Cookie / x-api-key headers to any host NOT in
     $AUTH_HOSTS, so a sanctioned-but-untrusted extra domain can't harvest tokens.

Every decision is logged to stdout and, if $AUDIT_LOG is set, appended to that file (the persisted
audit trail; see audit.sh --mitm). A prototype — deliberately small and readable.
"""
import hashlib
import os
import sys
from urllib.parse import unquote
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
ANTHROPIC_BLOCK_PATHS = [p.lower() for p in _csv("ANTHROPIC_BLOCK_PATHS", "/v1/files")]
ANTHROPIC_SINGLE_CRED = _flag("ANTHROPIC_SINGLE_CRED")
ANTHROPIC_PIN_TOKEN = os.environ.get("ANTHROPIC_PIN_TOKEN", "").strip().lower()
ALLOWED_CONNECT_PORTS = {int(p) for p in _csv("ALLOWED_CONNECT_PORTS", "443")}
AUDIT_LOG = os.environ.get("AUDIT_LOG", "").strip()

_audit_warned = False


def _matches(host, domain):
    host = (host or "").lower().rstrip(".")
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


def _norm_path(raw):
    """Percent-decode + normalize a request path so encoded/traversal variants can't dodge a
    prefix check: /%76%31/files, /v1%2ffiles, //v1/files, /v1/./files, /v1/files;x, backslashes,
    double-encoding. NOTE: we do NOT use urlsplit here — for an origin-form path like '//v1/files'
    it would parse 'v1' as the authority and drop it."""
    p = raw.split("?", 1)[0].split("#", 1)[0].replace("\\", "/")
    for _ in range(3):                      # collapse double/triple percent-encoding to a fixed point
        dec = unquote(p)
        if dec == p:
            break
        p = dec
    parts = []
    for seg in p.split("/"):
        seg = seg.split(";", 1)[0]          # drop path parameters (/seg;params)
        if seg in ("", "."):
            continue
        if seg == "..":
            if parts:
                parts.pop()
            continue
        parts.append(seg)
    return ("/" + "/".join(parts)).lower()


def _host_only(authority):
    """Bare host from an authority/Host value, dropping any port (handles [v6]:port)."""
    a = (authority or "").strip()
    if a.startswith("["):
        return a[1:a.index("]")].lower() if "]" in a else a.strip("[]").lower()
    return a.split(":", 1)[0].lower().rstrip(".")


def _log(verdict, method, host, path, reason=""):
    global _audit_warned
    line = f"[mitm] {verdict:5} {method:7} {host}{path[:60]} {reason}".rstrip()
    print(line, flush=True)
    if AUDIT_LOG:
        try:
            with open(AUDIT_LOG, "a") as fh:
                fh.write(line + "\n")
        except OSError as e:
            if not _audit_warned:
                print(f"[mitm] WARN audit log unwritable ({AUDIT_LOG}): {e}", file=sys.stderr, flush=True)
                _audit_warned = True


def _deny(flow, msg):
    flow.response = http.Response.make(403, (msg + "\n").encode(), {"Content-Type": "text/plain"})


def http_connect(flow: http.HTTPFlow):
    """Gate the CONNECT itself: a tunnel to a non-allowlisted host, or to a non-standard port, is
    refused before any bytes flow — closing raw-TCP/non-HTTP tunnels regardless of the inner data."""
    host = flow.request.host  # CONNECT authority — the real upstream, not a header
    port = flow.request.port
    if not _any(host, ALLOW):
        _log("DENY", "CONNECT", host, f":{port}", "not-allowlisted")
        return _deny(flow, "Filtered: host not on allowlist")
    if port not in ALLOWED_CONNECT_PORTS:
        _log("DENY", "CONNECT", host, f":{port}", "port-not-allowed")
        return _deny(flow, "Filtered: CONNECT port not allowed")


def request(flow: http.HTTPFlow):
    host = flow.request.host  # routing target — NOT pretty_host (which trusts the Host header)
    method = flow.request.method
    path = flow.request.path

    # 1. allowlist — BOTH the routing target AND the claimed vhost (Host header / :authority) must be
    # allowlisted. Checking host alone leaves plain-HTTP domain-fronting open (route to an allowed
    # host, set Host: blocked); checking the header alone is the round-1 spoof. Require both.
    if not _any(host, ALLOW):
        _log("DENY", method, host, path, "not-allowlisted")
        return _deny(flow, "Filtered: host not on allowlist")
    hdr_host = _host_only(getattr(flow.request, "host_header", "") or flow.request.headers.get("host", ""))
    if hdr_host and not _any(hdr_host, ALLOW):
        _log("DENY", method, hdr_host, path, "host-header-not-allowlisted")
        return _deny(flow, "Filtered: Host header not on allowlist")

    # 2. Anthropic API hardening
    if _any(host, ANTHROPIC_HOSTS):
        norm = _norm_path(path)
        for blocked in ANTHROPIC_BLOCK_PATHS:
            if norm == blocked or norm.startswith(blocked.rstrip("/") + "/"):
                _log("DENY", method, host, path, f"anthropic-blocked-path {blocked}")
                return _deny(flow, "Filtered: this Anthropic API endpoint is blocked in this sandbox")
        if ANTHROPIC_PIN_TOKEN:
            cred = _cred(flow.request)
            if not cred or _fp(cred) != ANTHROPIC_PIN_TOKEN:
                _log("DENY", method, host, path, "anthropic-token-mismatch")
                return _deny(flow, "Filtered: request credential does not match the pinned token")
        if ANTHROPIC_SINGLE_CRED and "x-api-key" in flow.request.headers:
            # Subscription/setup-token auth is an OAuth bearer; an api key here is never legit.
            del flow.request.headers["x-api-key"]
            _log("STRIP", method, host, path, "removed x-api-key on anthropic host (single-cred)")

    # 3. GitHub read-only: permit clone/fetch, block push + writes. Match the smart-HTTP endpoints on
    # the PATH COMPONENT (query stripped) so `POST /anything?git-upload-pack` can't sneak a write past
    # a loose substring check. WebSocket upgrades are denied (bidirectional, not content-inspected).
    if GITHUB_READONLY and _any(host, GITHUB_HOSTS):
        ppath = path.split("?", 1)[0]
        query = path[len(ppath):]
        if flow.request.headers.get("upgrade", "").lower() == "websocket":
            _log("DENY", method, host, path, "github-readonly (websocket)")
            return _deny(flow, "Filtered: WebSocket to GitHub blocked in this sandbox")
        if ppath.endswith("/git-receive-pack") or "service=git-receive-pack" in query:
            _log("DENY", method, host, path, "github-readonly (push)")
            return _deny(flow, "Filtered: GitHub is read-only in this sandbox (push blocked)")
        if method not in ("GET", "HEAD", "OPTIONS") and not (method == "POST" and ppath.endswith("/git-upload-pack")):
            _log("DENY", method, host, path, "github-readonly (write)")
            return _deny(flow, "Filtered: GitHub is read-only in this sandbox (writes blocked)")

    # 4. credential containment: don't leak auth to hosts outside the trusted set
    if not _any(host, AUTH_HOSTS):
        for h in ("authorization", "cookie", "proxy-authorization", "x-api-key"):
            if h in flow.request.headers:
                del flow.request.headers[h]
                _log("STRIP", method, host, path, f"removed {h} header")

    _log("ALLOW", method, host, path)


def websocket_start(flow: http.HTTPFlow):
    """Backstop: refuse any websocket to a GitHub host however it was negotiated. The HTTP/1.1
    Upgrade handshake is already denied in request(); this also covers HTTP/2 extended CONNECT,
    where the upgrade isn't a normal header."""
    if GITHUB_READONLY and _any(flow.request.host, GITHUB_HOSTS):
        _log("DENY", "WS", flow.request.host, flow.request.path, "github-readonly (websocket backstop)")
        try:
            flow.kill()
        except Exception:
            pass
