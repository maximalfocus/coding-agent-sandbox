"""
mitmproxy addon — content-aware egress mediation for the Claude Code sandbox.

This is the opt-in "defensive proxy" the SECURITY.md hardening notes describe and the Anthropic
containment write-up recommends: because it terminates TLS, it can mediate on request *content*,
not just the destination hostname (which is all the default tinyproxy can see).

Authorization is keyed on `request.host` — the actual routing target (CONNECT authority or
absolute-URI host) — NOT `request.pretty_host`, which prefers the spoofable `Host` header. CONNECT
itself is gated in `http_connect()` so tunnels (incl. raw-TCP, which is also disabled in the
entrypoint) can't reach a non-allowlisted host:port before `request()` would ever run. The same
destination-port set is enforced again in `request()` for ordinary HTTP forwarding.

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
import asyncio
import hashlib
import json
import os
import stat
import sys
import time
import urllib.request
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
EXACT_ALLOW_HOSTS = _domains("EXACT_ALLOW_HOSTS")
EXACT_AUTH_HOSTS = _domains("EXACT_AUTH_HOSTS")
GITHUB_HOSTS = ("github.com", "githubusercontent.com")
ANTHROPIC_HOSTS = ("anthropic.com",)
GITHUB_READONLY = _flag("GITHUB_READONLY")
ANTHROPIC_BLOCK_PATHS = [p.lower() for p in _csv("ANTHROPIC_BLOCK_PATHS", "/v1/files")]
ANTHROPIC_SINGLE_CRED = _flag("ANTHROPIC_SINGLE_CRED")
ANTHROPIC_PIN_TOKEN = os.environ.get("ANTHROPIC_PIN_TOKEN", "").strip().lower()
ALLOWED_CONNECT_PORTS = {int(p) for p in _csv("ALLOWED_CONNECT_PORTS", "443")}
AUDIT_LOG = os.environ.get("AUDIT_LOG", "").strip()
DEEPSEEK_ENABLED = os.environ.get("DEEPSEEK_ENABLED", "false").lower() in ("true", "1", "yes", "on")
DEEPSEEK_KEY_PATH = os.environ.get("DEEPSEEK_KEY_PATH", "/var/lib/sandbox/deepseek/api-key").strip()
if not DEEPSEEK_ENABLED:
    # Defense in depth: an exact-host list cannot accidentally grant DeepSeek unless the dedicated
    # runtime gate independently parsed as an explicit true value.
    EXACT_ALLOW_HOSTS = []
    EXACT_AUTH_HOSTS = []

# Subscription-token isolation (opt-in). When on, the REAL OAuth login lives only in tinyproxy-only
# storage; the addon injects it into api.anthropic.com requests and owns the OAuth refresh, so the
# agent (running as `node`) never holds a usable token. See mitm/entrypoint.sh + mitm/claim-token.
TOKEN_ISOLATION = _flag("ANTHROPIC_TOKEN_ISOLATION", "false")
SECRET_PATH = os.environ.get("TOKEN_SECRET_PATH", "/var/lib/sandbox/secret/credentials.json").strip()
TOKEN_PLACEHOLDER = os.environ.get("TOKEN_PLACEHOLDER", "sandbox-placeholder-do-not-use").strip()
OAUTH_TOKEN_URL = os.environ.get("OAUTH_TOKEN_URL", "https://platform.claude.com/v1/oauth/token").strip()
OAUTH_CLIENT_ID = os.environ.get("OAUTH_CLIENT_ID", "22422756-60c9-4084-8eb7-27705fd5cf9a").strip()
REFRESH_SKEW = int(os.environ.get("TOKEN_REFRESH_SKEW", "600"))  # refresh when <10 min remaining

_audit_warned = False


def _matches(host, domain):
    host = (host or "").lower().rstrip(".")
    domain = (domain or "").lower().rstrip(".")
    return host == domain or host.endswith("." + domain)


def _any(host, domains):
    return any(_matches(host, d) for d in domains)


def _exact(host, domains):
    host = (host or "").lower().rstrip(".")
    return host in {domain.lower().rstrip(".") for domain in domains}


def _allowed(host):
    return _any(host, ALLOW) or _exact(host, EXACT_ALLOW_HOSTS)


def _auth_host(host):
    return _any(host, AUTH_HOSTS) or _exact(host, EXACT_AUTH_HOSTS)


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
    p = raw.split("?", 1)[0].split("#", 1)[0]
    for _ in range(5):                      # percent-decode to a fixed point (handles nested encoding)
        dec = unquote(p)
        if dec == p:
            break
        p = dec
    p = p.replace("\\", "/")                # AFTER decoding, so %5c (\) is also treated as a separator
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


class TokenVault:
    """Holds the REAL subscription credentials in tinyproxy-only storage and injects a live access
    token into outbound api.anthropic.com requests — so the agent (running as `node`) never needs,
    and never sees, a usable token.

    It also OWNS the OAuth refresh. The agent's own copy of the login carries a far-future placeholder
    expiry, so the Claude Code CLI believes it is logged in and never refreshes locally (the CLI's
    only expiry test is arithmetic on the stored timestamp — it never parses the token). This vault
    refreshes the real token here, behind the agent's back, and persists the rotated refresh_token
    atomically.

    The refresh POST must NOT traverse the mitm proxy (it would loop back into us), so it goes out
    directly with an empty ProxyHandler; the kernel firewall still permits it because this process
    runs as the tinyproxy egress UID. Until a login has been claimed into the vault, token() returns
    None and the caller passes the request through unchanged — so the initial /login still works."""

    def __init__(self, path):
        self.path = path
        self._lock = None          # created lazily, inside the running loop
        self._data = None          # parsed claudeAiOauth dict, or None if not yet claimed
        self._mtime = None

    def _load(self):
        try:
            st = os.stat(self.path)
        except OSError:
            self._data = None
            return
        if self._mtime == st.st_mtime and self._data is not None:
            return                 # unchanged since last read — use cache
        try:
            with open(self.path) as fh:
                raw = json.load(fh)
            self._data = raw.get("claudeAiOauth", raw)
            self._mtime = st.st_mtime
        except (OSError, ValueError) as e:
            _log("ERROR", "-", "vault", "", f"load failed: {e}")

    def _expired(self):
        exp = self._data.get("expiresAt")            # epoch milliseconds (same unit the CLI stores)
        if not exp:
            return True
        return time.time() + REFRESH_SKEW >= exp / 1000.0

    def _refresh_blocking(self):
        d = dict(self._data)
        body = json.dumps({
            "grant_type": "refresh_token",
            "refresh_token": d["refreshToken"],
            "client_id": d.get("clientId") or OAUTH_CLIENT_ID,
            "scope": " ".join(d.get("scopes") or []),
        }).encode()
        req = urllib.request.Request(
            OAUTH_TOKEN_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        # ProxyHandler({}) == no proxy: bypass the inherited HTTPS_PROXY so we don't tunnel the
        # refresh through ourselves. The firewall still allows it — we are the tinyproxy UID.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=30) as resp:
            r = json.loads(resp.read().decode())
        d["accessToken"] = r["access_token"]
        d["refreshToken"] = r.get("refresh_token", d["refreshToken"])   # honor rotation
        d["expiresAt"] = int((time.time() + r.get("expires_in", 3600)) * 1000)
        self._persist(d)
        self._data = d

    def _persist(self, d):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump({"claudeAiOauth": d}, fh)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)           # atomic — never a torn rotated-refresh-token write
        try:
            self._mtime = os.stat(self.path).st_mtime
        except OSError:
            self._mtime = None

    async def token(self):
        if self._lock is None:
            self._lock = asyncio.Lock()
        async with self._lock:               # single-flight: one refresh on expiry, not a stampede
            self._load()
            if not (self._data and self._data.get("accessToken")):
                return None                  # not claimed yet — caller passes the request through
            if self._data.get("refreshToken") and self._expired():
                try:
                    await asyncio.get_running_loop().run_in_executor(None, self._refresh_blocking)
                    _log("REFRESH", "POST", "platform.claude.com", "/v1/oauth/token", "rotated ok")
                except Exception as e:       # keep serving the (possibly still-valid) token on failure
                    _log("ERROR", "POST", "platform.claude.com", "/v1/oauth/token", f"refresh failed: {e}")
            return self._data.get("accessToken")


VAULT = TokenVault(SECRET_PATH) if TOKEN_ISOLATION else None


class DeepSeekKey:
    """Read the static key from sidecar-only storage for every request.

    No value is cached, so an atomic replacement is the rotation boundary. Ownership, mode,
    file type, size, and contents are checked before each injection; any unsafe state is a denial.
    """

    MAX_BYTES = 16 * 1024

    def __init__(self, path):
        self.path = path

    def read(self):
        directory = os.path.dirname(self.path)
        try:
            directory_info = os.lstat(directory)
        except OSError as exc:
            raise ValueError("secret directory unavailable") from exc
        if (not stat.S_ISDIR(directory_info.st_mode) or stat.S_ISLNK(directory_info.st_mode)
                or directory_info.st_uid != os.geteuid()
                or stat.S_IMODE(directory_info.st_mode) != 0o700):
            raise ValueError("unsafe secret directory")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.path, flags)
        except OSError as exc:
            raise ValueError("key unavailable") from exc
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600):
                raise ValueError("unsafe key file")
            raw = os.read(descriptor, self.MAX_BYTES + 1)
        finally:
            os.close(descriptor)
        if len(raw) > self.MAX_BYTES:
            raise ValueError("key too large")
        try:
            value = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("key is not text") from exc
        if (not value or value == TOKEN_PLACEHOLDER or value != value.strip()
                or any(ord(char) < 0x20 or ord(char) == 0x7F for char in value)):
            raise ValueError("invalid key contents")
        return value


DEEPSEEK_KEY = DeepSeekKey(DEEPSEEK_KEY_PATH) if DEEPSEEK_ENABLED else None


def http_connect(flow: http.HTTPFlow):
    """Gate the CONNECT itself: a tunnel to a non-allowlisted host, or to a non-standard port, is
    refused before any bytes flow — closing raw-TCP/non-HTTP tunnels regardless of the inner data."""
    host = flow.request.host  # CONNECT authority — the real upstream, not a header
    port = flow.request.port
    if not _allowed(host):
        _log("DENY", "CONNECT", host, f":{port}", "not-allowlisted")
        return _deny(flow, "Filtered: host not on allowlist")
    if port not in ALLOWED_CONNECT_PORTS:
        _log("DENY", "CONNECT", host, f":{port}", "port-not-allowed")
        return _deny(flow, "Filtered: CONNECT port not allowed")


async def request(flow: http.HTTPFlow):
    host = flow.request.host  # routing target — NOT pretty_host (which trusts the Host header)
    method = flow.request.method
    path = flow.request.path

    # 1. allowlist — BOTH the routing target AND the claimed vhost (Host header / :authority) must be
    # allowlisted. Checking host alone leaves plain-HTTP domain-fronting open (route to an allowed
    # host, set Host: blocked); checking the header alone is the round-1 spoof. Require both.
    if not _allowed(host):
        _log("DENY", method, host, path, "not-allowlisted")
        return _deny(flow, "Filtered: host not on allowlist")
    hdr_host = _host_only(getattr(flow.request, "host_header", "") or flow.request.headers.get("host", ""))
    if hdr_host and not _allowed(hdr_host):
        _log("DENY", method, hdr_host, path, "host-header-not-allowlisted")
        return _deny(flow, "Filtered: Host header not on allowlist")
    # TLS SNI must also be allowlisted: mitmproxy re-uses the client's ClientHello SNI for the
    # upstream handshake, so a CONNECT to an allowed shared-CDN host with an attacker SNI (and an
    # allowed Host) could otherwise front to a non-allowlisted vhost. connection_strategy=lazy means
    # this denial runs before the upstream connection is opened.
    sni = _host_only(getattr(flow.client_conn, "sni", "") or "")
    if sni and not _allowed(sni):
        _log("DENY", method, sni, path, "sni-not-allowlisted")
        return _deny(flow, "Filtered: TLS SNI not on allowlist")
    port = flow.request.port
    if port not in ALLOWED_CONNECT_PORTS:
        _log("DENY", method, host, f":{port}", "port-not-allowed")
        return _deny(flow, "Filtered: destination port not allowed")

    # 2. DeepSeek static-key isolation. This branch is exact-host only: unlike the suffix-based
    # general allowlist, no subdomain inherits access or credential trust. Always overwrite any
    # agent-supplied credential, and deny when sidecar-only storage is unavailable or unsafe.
    if DEEPSEEK_KEY is not None and _exact(host, ("api.deepseek.com",)):
        try:
            key = DEEPSEEK_KEY.read()
        except ValueError:
            _log("DENY", method, host, path, "deepseek-key-unavailable-or-unsafe")
            return _deny(flow, "Filtered: DeepSeek credential is unavailable or unsafe")
        for header in ("authorization", "x-api-key", "api-key", "cookie", "proxy-authorization"):
            if header in flow.request.headers:
                del flow.request.headers[header]
        flow.request.headers["authorization"] = f"Bearer {key}"
        _log("INJECT", method, host, path, "DeepSeek key injected from sidecar storage")

    # 3. Anthropic API hardening
    if _any(host, ANTHROPIC_HOSTS):
        norm = _norm_path(path)
        for blocked in ANTHROPIC_BLOCK_PATHS:
            if norm == blocked or norm.startswith(blocked.rstrip("/") + "/"):
                _log("DENY", method, host, path, f"anthropic-blocked-path {blocked}")
                return _deny(flow, "Filtered: this Anthropic API endpoint is blocked in this sandbox")
        # Token isolation: swap the agent's placeholder bearer for the real one held in the vault.
        # The agent never holds a usable token, and can't influence which token is sent (we always
        # overwrite). PIN/single-cred below are alternative modes — skipped once we inject our own.
        injected = False
        if VAULT is not None and _matches(host, "api.anthropic.com"):
            tok = await VAULT.token()
            if tok:                                  # vault populated (claimed) — enforce
                incoming = _cred(flow.request)
                if incoming and incoming != TOKEN_PLACEHOLDER:
                    _log("WARN", method, host, path, "non-placeholder credential — re-run ./scripts/auth/claim-token.sh")
                flow.request.headers["authorization"] = f"Bearer {tok}"
                if "x-api-key" in flow.request.headers:
                    del flow.request.headers["x-api-key"]
                injected = True
                _log("INJECT", method, host, path, "subscription token injected from vault")
            # vault empty (not claimed yet) → fall through unchanged so the initial /login works
        if not injected and ANTHROPIC_PIN_TOKEN:
            cred = _cred(flow.request)
            if not cred or _fp(cred) != ANTHROPIC_PIN_TOKEN:
                _log("DENY", method, host, path, "anthropic-token-mismatch")
                return _deny(flow, "Filtered: request credential does not match the pinned token")
        if not injected and ANTHROPIC_SINGLE_CRED and "x-api-key" in flow.request.headers:
            # Subscription/setup-token auth is an OAuth bearer; an api key here is never legit.
            del flow.request.headers["x-api-key"]
            _log("STRIP", method, host, path, "removed x-api-key on anthropic host (single-cred)")

    # 4. GitHub read-only: permit clone/fetch, block push + writes. Match the smart-HTTP endpoints on
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

    # 5. credential containment: don't leak auth to hosts outside the trusted set
    if not _auth_host(host):
        for h in ("authorization", "cookie", "proxy-authorization", "x-api-key", "api-key"):
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
