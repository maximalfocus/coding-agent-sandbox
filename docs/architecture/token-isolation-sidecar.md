# Token isolation — sidecar variant (experimental)

> **Status: experimental.** The single-container Anthropic token isolation in the mitm variant
> (`ANTHROPIC_TOKEN_ISOLATION=true`, see `SECURITY.md`) remains the supported path. This document +
> `docker-compose.sidecar.yml` take credential isolation one namespace boundary further. Run the
> real two-container checks in **Verification** for the exact image and configuration you deploy.

## Why a sidecar

The single-container isolation already moves the real OAuth login into a `tinyproxy`-only vault
(`/var/lib/sandbox/secret`, mode `0700`) and injects it per-request, so the agent (`node`) can't read
a usable token. But the vault and the agent live in the **same container**: the separation is a
`0600`/`0700` file-permission boundary between two users in one mount + network namespace. A
kernel-level container escape from the agent could still reach the vault.

The sidecar variant makes the separation a **namespace boundary**: the vault is mounted only in a
second container that the agent has no share with. The agent's only non-loopback peer is the pinned
sidecar proxy; Docker DNS and every other destination are rejected. The proxy is the only process
that ever holds the credential.

```
        ┌────────────────────────────┐         ┌────────────────────────────────────┐
        │  agent container (node)     │         │  egress sidecar (tinyproxy)         │
        │  - claude / tools           │         │  - mitmdump + filter_addon.py       │
        │  - workspace mount          │ HTTPS_  │  - VAULT  (claude-secret volume) ◄──┼── real tokens live ONLY here
        │  - claude-config (rw)       │ PROXY   │  - OAuth refresh loop               │
        │  - NO internet route        │ ──────► │  - claude-config (rw, for claim)    │
        │  - inert DeepSeek key       │ :8888   │  - deepseek-secret (sidecar only)   │
        │  - NO secret-volume mounts  │         │  - firewall: only it egresses       │
        └─────────────┬──────────────┘         └──────────────────┬─────────────────┘
                      │  internal network (internal: true;                │ egress network
                      │  mandatory firewall blocks DNS/direct egress)     ▼  (internet)
                      └────────────────────────────────────────►  api.anthropic.com
```

## How it maps onto the existing pieces

The credential paths share the same proxy boundary but keep separate storage and lifecycle rules:

- **`mitm/filter_addon.py`** runs in the sidecar. `ANTHROPIC_TOKEN_ISOLATION=true` is forced on, so it
  injects the Anthropic vault token and owns the refresh. When the separate DeepSeek gate is on, it
  reads the static key from its dedicated volume for each exact-host request and overwrites the
  agent placeholder.
- **`mitm/claim-token`** runs in the sidecar. It first **validates the login with the OAuth server
  (refresh-token grant)** — a fake or unreachable login fails closed (the candidate is not vaulted;
  any prior vault stays unchanged) — then
  atomically installs the placeholder in `claude-config` before making the validated token live in
  the sidecar-only `claude-secret` vault. If the vault write fails, it attempts to restore the node
  login and reports a critical error if rollback is also blocked. Each replacement is atomic and
  never follows a symlink (issue #44). The agent
  never mounts `claude-secret`, so post-claim the only thing in any volume the agent can read is the
  inert placeholder.
- **`mitm/sidecar-entrypoint.sh`** (new) is the mitm entrypoint minus the node hand-off: set up the
  vault, reconcile claim-token, export the intercept CA to a shared volume, install a sidecar firewall,
  and run `mitmdump` in the foreground (the agent container, not this one, runs `claude`/ttyd).
- **`mitm/agent-entrypoint.sh`** (new) trusts the shared CA, resolves and pins the sidecar in
  `/etc/hosts`, installs a mandatory fail-closed agent firewall, then hands off to the **stock**
  `entrypoint.sh` as `node` — reusing all the existing
  node-side setup (git/gh, tmux, ttyd). Because it's exec'd as `node`, the root half of
  `entrypoint.sh` (which would start tinyproxy) is skipped: the agent runs no proxy of its own.

## The two networks (the actual containment)

- `internal` is declared `internal: true`, so Docker does not provide normal internet routing. Docker's
  embedded DNS can still forward external queries through the host, however, so the network flag is
  not an egress boundary by itself. The mandatory agent firewall below closes that channel.
- `egress` is a normal bridge with internet access. **Only the sidecar** joins it.
- `HTTPS_PROXY`/`HTTP_PROXY` in the agent point at `http://claude-sandbox-egress:8888` (overriding the
  image's `127.0.0.1:8888`). At startup the agent resolves that one name, verifies the result is
  directly attached, and pins it in `/etc/hosts`; general DNS is blocked before agent code starts.

## Firewalls (defense-in-depth on top of the network split)

- **Sidecar** reuses the existing fail-closed model: only the `tinyproxy` UID may egress; DNS only via
  `127.0.0.11`; private ranges, public DNS, and IPv6 are rejected. The one addition vs. the
  single-container firewall is an `INPUT` rule accepting `:8888` **only on the internal interface**
  identified by an alias assigned only on the Compose `internal` network. Startup requires that
  alias to resolve to exactly one IPv4 owned by exactly one local interface, and requires that
  interface to differ from the sole default-route interface; otherwise the sidecar refuses to start.
  The proxy port is therefore never accepted on the egress side because of interface ordering.
- **Agent** (mandatory, fail-closed): default-DROP `OUTPUT` permits loopback and established traffic,
  plus new TCP connections only to the pinned sidecar IPv4 on `:8888` over the directly attached
  internal interface. Docker DNS (`127.0.0.11`), public DNS, IPv6, other private/gateway targets,
  other sidecar ports, and every other destination are rejected. Failure to resolve/pin the sidecar or
  install the firewall prevents the agent container from starting.

## The CLI's own refresh is answered locally

The vault owns the OAuth refresh. That was always the design, but half of it was missing: the **agent
CLI also refreshes**, and nothing was answering it.

The placeholder carries a far-future `expiresAt` so the CLI believes it is logged in. Against Claude
Code `2.1.233` that is no longer enough — it refreshes anyway, presenting the placeholder as its
refresh token. The provider correctly refuses a credential the sandbox fabricated, and the CLI treats
that refusal as a dead session and **erases its own login**. The result was a variant that served
exactly one invocation per claim (issue #86).

So `mitm/filter_addon.py` answers that specific request itself, returning another placeholder with a
fresh far-future expiry. The CLI stays logged in indefinitely and never receives anything usable.

The trigger is deliberately narrow, and everything outside it reaches the provider untouched:

| Condition | Required |
|---|---|
| Token isolation on | yes — otherwise no placeholder exists |
| Routing host and normalized path | the pinned token endpoint |
| `refresh_token` in the body | **exactly** the placeholder |

A refresh carrying a **real** credential is never intercepted. That is what keeps `CAS-R172` intact:
`claim-token`'s validation and the vault's own refresh both still reach the provider, so a retired
client registration or a moved endpoint still surfaces the provider's own error — which is exactly how
the 2026-08-14 drift was found.

The answer is logged as `STUB` in the audit trail and carries `X-Sandbox-Filter: stub`, so it is never
mistaken for a provider response. Its body contains only placeholders, never vault material.

Verified live on 2026-08-16: claim, then three consecutive real model calls, placeholder intact after
each, three `STUB` events, nine `INJECT` events, and **zero** non-placeholder credentials seen by the
proxy.

## Health reporting

Both containers report a health status that means something in *this* variant.

The egress sidecar keeps the MITM image's healthcheck (mitmdump alive and filtering). The agent
cannot: the base image's healthcheck asserts an in-container `tinyproxy`, and this variant runs the
proxy in the sidecar by design, so that check could never pass — the agent reported `unhealthy`
permanently on a perfectly working stack (issue #70). `docker-compose.sidecar.yml` therefore
overrides it with `mitm/agent-healthcheck.sh`, which asserts what is actually true here:

1. the mandatory agent firewall is installed — default-deny `OUTPUT`, the pinned proxy `ACCEPT`
   rule, and the catch-all `REJECT`; and
2. the pinned sidecar proxy is reachable.

It only reads. It runs no `iptables` mutation, opens no egress, and sends nothing through the proxy —
reachability is a bare TCP connect to a peer the firewall already permits. Resolving the sidecar name
is itself part of the assertion: DNS is rejected by that firewall, so the name can only resolve from
the `/etc/hosts` pin the entrypoint installed. Each failure names the condition that was not met, so
`docker inspect` shows a cause rather than a bare exit code.

A supported variant that always reports `unhealthy` teaches its operator to ignore the health column,
which is why this is a real check rather than a disabled one. Note that the healthcheck script is
bind-mounted like `agent-entrypoint.sh`, so editing it on the host requires recreating the container
before the change takes effect.

## What this buys vs. the single-container version

| Threat | single-container (0700 file) | sidecar (separate container) |
|---|---|---|
| Agent reads the token via the filesystem | blocked (file perms) | blocked (volume not mounted at all) |
| Agent exfiltrates a usable/refresh token | blocked | blocked |
| **Kernel/container escape from the agent reaches the vault** | **possible** | **blocked** (different namespace, no shared mount) |
| Compromise of the proxy process itself | has the vault | has the vault (but tiny attack surface: no agent code, no workspace, no model — only parses HTTP from the agent) |

This is the form that actually approaches Anthropic's sealed-VM property for the credential: the
secret lives behind a boundary the agent's container never shares.

## DeepSeek static-key isolation

`ALLOW_DEEPSEEK` is a dedicated sidecar-only gate and defaults to `false` in `.env.example`, Compose,
and the runtime parser. Empty, false-like, and unknown values are off. A true-like value is accepted
only if `/usr/local/bin/deepseek-key validate` confirms the sidecar secret directory is a real,
tinyproxy-owned `0700` directory and `api-key` is a real, tinyproxy-owned `0600` file containing one
non-placeholder line. Startup fails closed before the exact destination is exported if validation
fails.

DeepSeek is intentionally not added to the suffix allowlist. The addon uses separate exact-host
allow/auth sets, normalizes DNS case and a trailing dot, and permits only `api.deepseek.com:443`.
Parent domains, subdomains, suffix lookalikes, alternate Host headers/SNI, and other ports are
denied. `EXTRA_ALLOWED_DOMAINS` ignores every DeepSeek domain so it cannot bypass the dedicated gate.
For the accepted host, the proxy removes agent-controlled bearer/API-key/cookie/proxy credentials
and installs `Authorization: Bearer <sidecar key>`. Other providers never inherit the key.

The agent service mounts no DeepSeek volume or path and gets only
`DEEPSEEK_API_KEY=sandbox-placeholder-do-not-use`, which lets Pi select its built-in DeepSeek
provider without holding a usable credential. Provision and lifecycle commands pass the key over
stdin to a profile-only, networkless key-manager container that mounts no other volume. Build the
sidecar image once before the first command:

```bash
docker compose -f docker-compose.sidecar.yml build deepseek-key-manager
./scripts/auth/deepseek-key.sh provision  # create; input hidden
./scripts/auth/deepseek-key.sh rotate     # atomic replace; next request uses it
./scripts/auth/deepseek-key.sh status     # readiness + short non-secret fingerprint
./scripts/auth/deepseek-key.sh revoke     # remove only the key file
```

PowerShell uses the same actions through `scripts/auth/deepseek-key.ps1`. The key is never a command
argument or Compose environment value. Audit decisions contain only `INJECT`/redacted failure
events; never capture environment dumps, proxy headers, key files, Pi auth state, or the volume in
acceptance evidence.

## Codex subscription isolation: NO-GO at 0.140.0

The sidecar intentionally has no OpenAI capability gate, Codex state mount, or OpenAI/ChatGPT route.
Codex `0.140.0` does not expose a supported credential-only subscription broker. Managed login
keeps reusable auth in the Codex process; the host-managed App Server token mode is explicitly
unstable/OpenAI-internal, carries replacement access tokens through its client protocol, and belongs
to a full command/filesystem execution server. Moving that server into this container would violate
the defining sidecar property shown above: the credential holder runs no agent code and mounts no
workspace.

The evidence and reevaluation condition are recorded in
[`docs/codex-subscription-broker-feasibility.md`](../codex-subscription-broker-feasibility.md).
Do not add OpenAI routes, copy `auth.json`, parse its private fields, or fall back to API-key billing
to work around this boundary.

## Verification record — 2026-08-16

The first end-to-end run of this variant with a real subscription. Recorded here because issue #58
required it; nothing below contains credential material.

| | |
|---|---|
| Tested tree | the change that landed as squash `8f7a67b` on `main` |
| Images | built from that tree — agent from `Dockerfile`, egress from `Dockerfile.mitm` |
| Claude Code | `2.1.233` |
| Host class | `arch:arm64`, `kernel:vm` (macOS, Docker in a VM) |
| Stack | isolated Compose project with issue-specific containers, networks and volumes; no operator credential volume mounted; torn down afterwards |
| Gates | `ENABLE_NESTED_DOCKER` unset, `ALLOW_DEEPSEEK=false`, no registry-auth exemption — i.e. the additions since this variant was written were all default-off |

**Sequence and result**

| Step | Observed |
|---|---|
| Before login | no credential file |
| After interactive `/login` | real token, `expiresAt` +8.0 h |
| After `claim-token` | placeholder (len 30), `expiresAt` +10 years; vault `0700`/`0600`, `tinyproxy`-owned |
| Model call ×3 | all succeeded; placeholder intact after **every** one |
| Direct non-proxied egress | blocked |
| Vault visible to agent | no |

**Proxy audit for the run:** 3 × `STUB`, 9 × `INJECT`, 43 × `ALLOW`, 21 × `DENY`, and **0**
non-placeholder credentials presented by the agent. No credential-shaped material in the trail.

**Smoke test: 11 passed, 0 failed, 0 skipped** — 10 structural checks plus the login-dependent
placeholder check, which passed here for the first time. The count is stated because the structural
inventory has grown since #58 was written.

**What this does not establish.** Refresh beyond the access-token lifetime is still unexercised, which
is why the variant remains **experimental** and why `SL-09` is not promoted. A separate run spanning
the token TTL is required for that.

## Verification record — 2026-08-17: refresh beyond the access-token TTL

`CAS-R081`'s second condition, and the last thing between this variant and promotion. The 2026-08-16
record above proved inference; every call in it used a token still inside its first eight hours.
Recorded here because issue #101 required it; nothing below contains credential material.

| | |
|---|---|
| Tested tree | squash `975b810` on `main` |
| Claude Code | `2.1.233` |
| Host class | `arch:arm64`, `kernel:vm` (macOS, Docker in a VM) |
| Stack | isolated Compose project, all five volumes scoped; no operator volume mounted; torn down afterwards |
| Refresh skew | the default `600` s — not raised for this run |

**The refresh is demand-driven, not scheduled.** `TokenVault.token()` refreshes when a request needs
a token, so an idle stack does not refresh on a timer. That is the correct design — a timer would
renew credentials nobody is using — and it shapes what "beyond the TTL" means here: the token is
allowed to expire, and the next request is what must still succeed.

| Time (UTC) | Observed |
|---|---|
| 01:53 | baseline recorded: access token expiring 09:49, i.e. **8.0 h** ahead; 4 refreshes in the audit log |
| 09:39 | the skew window opens — nothing happens, because the stack is idle |
| 13:47 | vault unchanged, same token shas, `expiresAt` **3.97 h in the past**; refresh count still 4 |
| 13:47 | one model call — **succeeded** |
| | the proxy refreshed on that call: audit records `REFRESH … rotated ok`, count 4 → 5 |
| | both tokens rotated — access `fe101c117a` → `ac9dc6d0d0`, refresh `0c7f0d0a95` → `2813ca3439` |
| | new expiry **+8.00 h** |
| | a second model call on the refreshed token — succeeded |
| | agent credential state `placeholder` throughout; proxy recorded **0** non-placeholder credentials |
| | `sidecar-smoketest.sh`: **12 passed, 0 failed, 0 skipped** |

The token shas are recorded as truncated SHA-256 of the values, never the values, so rotation is
evidenced without exposing anything.

**This run could not have passed before 2026-08-17.** The refresh had never worked: unidentified, it
was rejected by Cloudflare on the client's fingerprint (`error code: 1010`) before reaching the OAuth
endpoint, and `TokenVault` fails closed by continuing to serve the still-valid token — so the variant
would simply have stopped serving about eight hours after every claim. Found by attempting this
verification, fixed in issue #102, and the reason the fast path (forcing a refresh) was run before
the slow one.

## Verification (REQUIRED before this is trusted / merged)

**One-command path:** `./sidecar-smoketest.sh --up` brings the stack up and runs the structural
checks (3a–d below), the DNS canary, pinned-proxy policy, and Docker host-gateway rejection
automatically, plus the placeholder check once you've claimed. It does NOT do the
interactive `/login` or a billed model call. The manual walk-through below covers the same ground:

### Pointing the smoke test at an isolated stack

Validation work needs issue-specific containers, networks, and volumes that must not touch an
operator's credential volumes. Every name the smoke test addresses is selectable through the
environment:

| Variable | Selects |
|---|---|
| `SIDECAR_COMPOSE_PROJECT` | the Compose project (`-p`) that every `ps` and `exec` addresses |
| `SIDECAR_AGENT_CONTAINER_NAME` | the agent container name used by `docker inspect` |
| `SIDECAR_EGRESS_CONTAINER_NAME` | the egress container name used by `docker inspect` |
| `SIDECAR_COMPOSE_OVERRIDE` | an extra `-f` overlay, e.g. `docker-compose.dind.yml` |

```bash
SIDECAR_COMPOSE_PROJECT=issue-69 \
  SIDECAR_AGENT_CONTAINER_NAME=issue-69-agent \
  SIDECAR_EGRESS_CONTAINER_NAME=issue-69-egress \
  ./sidecar-smoketest.sh
```

The project variable is load-bearing, not a convenience. The container-name variables steer only
`docker inspect`; without project scope the script would inspect the isolated stack while running
`ps` and `exec` against the **default** project — the operator's own stack (issue #69).

One note on reading a failure: the interface-binding check asserts entirely from state read at check
time — current Docker network metadata, the container's current addresses and routes, and the live
`iptables` rules. It deliberately reads nothing from `docker logs`. Requiring a retained log line
made a correct boundary report failure 7 times in 20 measured runs, because that read races with the
log driver rather than reflecting the state being asserted. Each condition now names itself, so a
failure says which one was not met rather than only stating the conclusion.

Run on a host with a real Docker engine (e.g. Colima):

```bash
# 1. Build images (base + mitm) and bring up the two-container stack.
docker compose build
docker compose -f docker-compose.sidecar.yml up -d --build

# 2. Log in from the AGENT container, then claim the token into the sidecar vault.
docker compose -f docker-compose.sidecar.yml exec -u node claude-sandbox-node claude   # /login
./scripts/auth/claim-token.sh                                                                        # auto-detects sidecar

# 3. CONFIRM the guarantees:
#  a) Claude still works (injection path): run a prompt in the agent container — it should reach the API.
#  b) Agent cannot read the real token: the config volume holds only the placeholder.
docker compose -f docker-compose.sidecar.yml exec -u node claude-sandbox-node \
    cat /home/node/.claude/.credentials.json        # expect accessToken == placeholder
#  c) Agent cannot reach the vault at all (different container, not mounted):
docker compose -f docker-compose.sidecar.yml exec -u node claude-sandbox-node \
    ls /var/lib/sandbox/secret                       # expect: No such file or directory
#  d) Agent has no direct internet (only-via-proxy): a non-proxied curl must fail.
docker compose -f docker-compose.sidecar.yml exec -u node claude-sandbox-node \
    env -u HTTPS_PROXY -u HTTP_PROXY curl -s --max-time 5 https://api.anthropic.com/   # expect failure
#  e) Agent cannot query Docker DNS (the sidecar name still resolves from its pinned /etc/hosts entry).
docker compose -f docker-compose.sidecar.yml exec -u node claude-sandbox-node \
    dig +time=2 +tries=1 dns-canary.invalid @127.0.0.11       # expect failure
#  f) Refresh works over time: leave it running past the access-token TTL and confirm calls keep
#     working (the sidecar refreshes; watch ./audit.sh --mitm for REFRESH lines).
```

For DeepSeek acceptance, use a disposable Compose project and dedicated volume name, provision the
key without printing it, enable `ALLOW_DEEPSEEK=true`, and run one minimal Pi inference. Also prove
that the agent sees the placeholder but cannot list `/var/lib/sandbox/deepseek`, a direct non-proxy
request fails, a near-miss host is denied, and the audit contains an `INJECT` event without secret
material. Record only image IDs, container/volume names, HTTP/result status, and redacted decisions;
then tear down that exact project and volume. All checks must hold for each trusted run.
