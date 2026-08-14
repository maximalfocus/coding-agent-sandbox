# Docker Sandboxes upstream-proxy composition feasibility

## Verdict: GO, with one documented limitation

As of 2026-08-14, this repository's content-mediation layer (`mitm/filter_addon.py`) **can** run as
the upstream proxy beneath Docker Sandboxes `v0.38.0`, with the `SL-08` mediation contract intact
and with guest CA trust established through a supported, declarative interface. Agent HTTPS traffic
is mediated end-to-end: allowlist decisions, method- and path-level rules, credential stripping, and
the per-request `ALLOW`/`DENY`/`STRIP` audit trail all survive the composition.

The limitation is specific and does not overturn the verdict: **traffic that the sandbox's own proxy
terminates itself — observed for container registry traffic — cannot be TLS-intercepted by an
upstream, because that proxy validates the upstream certificate and `v0.38.0` exposes no setting to
make it trust a custom CA.** Nested `docker pull` therefore either fails under interception or must
be excluded from the upstream via `no_proxy.sandbox`, which removes it from mediation entirely.

This verdict is deliberately narrower than "this project should run on Docker Sandboxes." It
establishes only that the composition is technically available. Adopting it as a shipped deployment
form is a separate decision with its own requirements, and nothing in this repository depends on
Docker Sandboxes as a result of this investigation.

## Assessed contract

| Evidence class | Pinned evidence | Finding |
|---|---|---|
| Product version | `sbx v0.38.0`, commit `c022b14634c4bea846ca12870d1d5e97d5868b54` | Installed as a Homebrew cask from `docker/tap`; requires arm64 and macOS ≥ 14 |
| Host platform | macOS 26.6.1, arm64, OrbStack-provided Docker 29.4.0 | Docker Desktop not required |
| Upstream-proxy interface | `sbx settings` keys `proxy`, `proxy.sandbox`, `proxy.daemon`, `no_proxy`, `no_proxy.sandbox`, `no_proxy.daemon`, `proxy.integratedAuth` | Sandbox and daemon scopes are independently configurable |
| Accepted proxy forms | `proxy` accepts "URL, PAC source, `system`, or `direct`; empty = automatic: HTTP(S)_PROXY if set, otherwise the host OS proxy" | An HTTP CONNECT proxy is a first-class form; SOCKS5 is one option, not a requirement |
| Guest trust injection | `sbx kit` `mixin` artifacts (`setup.files`, `setup.startup`) | Supported declarative interface; marked EXPERIMENTAL by the CLI |
| Custom CA for the sandbox proxy itself | None among the 18 settings exposed at this version | `tls.allowNegativeSerial` addresses serial-number compatibility only, not trust anchors |
| Policy presets | CLI accepts `allow-all`, `balanced`, `deny-all` | Product documentation names these Open, Balanced, and Locked Down; the CLI tokens differ |

## Upstream-proxy interface

The mediation layer is attached by pointing sandbox egress at it:

```bash
sbx settings set proxy.sandbox http://<mediation-host>:<port>
```

`proxy.sandbox` applies without a daemon restart. `proxy` and `proxy.daemon` are marked
restart-required. No change to the mediation layer's proxy mode is needed: it continues to run as an
ordinary HTTP proxy handling CONNECT, so the CONNECT port gate, the routing-host / claimed-authority
/ TLS-SNI agreement check, and raw-TCP passthrough denial in `mitm/filter_addon.py` are unaffected.

Sandbox egress observed through the mediation layer includes agent process traffic **and** traffic
originated by the sandbox's own Docker daemon. `proxy.daemon` was left unset throughout; nested
daemon egress is carried by the `proxy.sandbox` scope.

## Guest CA trust

The sandbox installs its own `CN=Docker Sandboxes Proxy CA` (serial `01`) into the guest trust
bundle at creation. With an upstream configured, the sandbox proxy passes TLS through by CONNECT
rather than terminating it, so the guest presents the upstream's certificate — clients inside the
sandbox observe `issuer=CN=mitmproxy`. The upstream CA is therefore not trusted by default and must
be added.

A `kit` mixin distributes it declaratively. Two constraints were established by testing:

- `setup.files` entries are written as a non-root user. Writing directly to
  `/usr/local/share/ca-certificates/` fails with `Permission denied`; the file must land in a
  writable path and be installed by a `setup.startup` command with `user: root`.
- `setup.startup` commands run on **every** container start, so the trust bundle is reconciled after
  each restart.

Working shape:

```yaml
schemaVersion: 2
name: upstream-mediation-ca
kind: mixin
setup:
  files:
    - path: /tmp/upstream-mediation-ca.crt
      content: |
        -----BEGIN CERTIFICATE-----
        ...
      mode: '0644'
  startup:
    - command:
        - sh
        - -c
        - cp /tmp/upstream-mediation-ca.crt /usr/local/share/ca-certificates/ && update-ca-certificates
      user: root
```

A sandbox created with `--kit` reaches allowlisted HTTPS destinations with no manual step.

Before the CA is trusted, the mediation layer degrades to opaque TCP forwarding
(`-> tcp -> example.com:443`) and sees no request detail. After it is trusted, the same request is
recorded as `GET https://example.com/ HTTP/2.0`. Content-level mediation depends entirely on this
step.

## Mediation contract under composition

Verified from inside a kit-provisioned sandbox, with the sandbox's own policy set to `allow-all` so
that every decision below originates from the mediation layer:

| `SL-08` capability | Result | Observed evidence |
|---|---|---|
| Hostname allowlist | Preserved | `ALLOW GET example.com/`; `DENY CONNECT ifconfig.me:443 not-allowlisted` |
| Non-allowlisted exfil destination | Denied | `DENY CONNECT pastebin.com:443 not-allowlisted` |
| Method and normalized path mediation | Preserved | `ALLOW GET …/info/refs?service=git-upload-pack` |
| GitHub read-only rule | Preserved | `DENY GET …/info/refs?service=git-receive-pack github-readonly (push)`; `DENY POST …/git-receive-pack github-readonly (push)` |
| Credential stripping | Preserved | `STRIP GET example.com/ removed authorization header`; `STRIP … removed cookie header` |
| Audit redaction | Preserved | A sentinel bearer value supplied by the client appears zero times in the audit trail |
| Policy composition | Deny is authoritative | Destinations permitted by `allow-all` were still refused by the mediation layer |

One capability was established by composition rather than by a dedicated end-to-end case: the
routing-host / claimed-authority / TLS-SNI agreement check and raw-TCP passthrough denial were not
exercised with a purpose-built spoofing case inside a sandbox. They are covered by
`mitm/test_token_isolation.py` (53 checks) and `mitm/test_port_gate.py` (5 checks), and the
composition is shown above not to alter the mediation layer's decision logic — every other rule
class produced its expected verdict unchanged. A dedicated spoofing case inside a sandbox would
close the gap if this composition is ever adopted rather than merely recorded.

Two behavioral differences are worth recording for tooling that inspects status codes:

- A request-layer `DENY` returns `403` and that status reaches the sandbox unchanged.
- A CONNECT-layer `DENY` is surfaced to the sandbox as `502`, not the `403` the mediation layer
  emitted.

## Limitation: registry traffic cannot be intercepted

Nested `docker pull` inside the sandbox fails while the upstream intercepts TLS. The mediation layer
reports:

```
Client TLS handshake failed. The client does not trust the proxy's certificate
for registry-1.docker.io (tls alert bad certificate)
```

The rejecting client here is the sandbox's own proxy, not the guest: for this traffic it terminates
and validates the upstream certificate instead of passing CONNECT through, and no setting at
`v0.38.0` supplies it a custom trust anchor. Installing the CA into the guest bundle does not help,
and neither does restarting the sandbox or its Docker daemon — the daemon runs inside the sandbox
and does read the guest bundle, but it is not the component refusing the certificate.

Nested daemon egress **is** carried to the upstream and **is** subject to allowlist decisions —
`DENY CONNECT registry-1.docker.io:443 not-allowlisted` was observed before the registry was
allowlisted — so destination-level control over nested containers is available. What is unavailable
is content-level mediation of that traffic.

The available workaround is `no_proxy.sandbox`, excluding registry hosts from the upstream. That
restores nested `docker pull` at the cost of removing those destinations from mediation, and it is a
deliberate trade rather than a fix.

## Operational cost

The composition inherits Docker Sandboxes' requirements: hardware virtualization, a Docker account
sign-in, and its supported platform matrix. It also inherits a second TLS termination point ahead of
the mediation layer. In exchange it supplies a microVM kernel boundary and a per-sandbox Docker
engine, neither of which this project provides.

Two incidental observations, recorded because they bear on other planned work rather than on this
verdict:

- The sandbox runtime logs a `gvisor endpoint` component, indicating gVisor is used internally.
- Where a TLS-inspecting corporate proxy is present on the host, the mediation layer must trust that
  proxy's CA **in addition to** the public roots. Replacing the trust store with the corporate CA
  alone breaks destinations the corporate proxy does not intercept; the working configuration
  concatenates the system bundle and the corporate CA.

## Reproduce the evidence

`scripts/probe-sbx-upstream-proxy.sh` re-establishes the interface facts this verdict depends on. It
is secret-free, makes no network connection, creates no sandbox, and fails closed when the relied-on
`sbx` surface is absent or has changed. It is safe to run without a Docker Sandboxes account, in
which case it reports the checks it could not reach rather than assuming them.

```bash
./scripts/probe-sbx-upstream-proxy.sh        # human-readable
./scripts/probe-sbx-upstream-proxy.sh --json # machine-readable
./scripts/test-probe-sbx-upstream-proxy.sh   # the probe's own tests
```

The live checks behind the mediation table above require an authenticated sandbox and are not
automated here; the commands are recorded inline in the sections above so they can be replayed
against a disposable sandbox and a disposable mediation instance.

## Reevaluation triggers

Re-run this verdict when any of the following changes:

- Docker Sandboxes exposes a setting or interface that makes its own proxy trust a custom CA, which
  would retire the registry limitation.
- The `kit` mechanism leaves EXPERIMENTAL status, changes its schema, or gains a first-class
  certificate-distribution field.
- The upstream-proxy setting keys, accepted forms, or scope semantics change.
- The sandbox proxy changes which traffic classes it terminates rather than tunnels.
