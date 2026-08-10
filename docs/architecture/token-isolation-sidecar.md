# Token isolation — sidecar variant (experimental)

> **Status: experimental scaffold, NOT yet verified end-to-end.** The single-container token
> isolation in the mitm variant (`ANTHROPIC_TOKEN_ISOLATION=true`, see `SECURITY.md`) is the
> supported path. This document + `docker-compose.sidecar.yml` take the *same* mechanism one boundary
> further — into a separate container — and need a real two-container run to confirm the Docker
> networking before merge. See **Verification** below.

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
        │  - NO claude-secret mount   │ :8888   │  - firewall: only it egresses       │
        └─────────────┬──────────────┘         └──────────────────┬─────────────────┘
                      │  internal network (internal: true;                │ egress network
                      │  mandatory firewall blocks DNS/direct egress)     ▼  (internet)
                      └────────────────────────────────────────►  api.anthropic.com
```

## How it maps onto the existing pieces

Nothing in the addon or the claim logic changes — both are already env-driven:

- **`mitm/filter_addon.py`** runs unchanged in the sidecar. `ANTHROPIC_TOKEN_ISOLATION=true` is forced
  on (the sidecar's whole reason to exist), so it injects the vault token and owns the refresh.
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

## What this buys vs. the single-container version

| Threat | single-container (0700 file) | sidecar (separate container) |
|---|---|---|
| Agent reads the token via the filesystem | blocked (file perms) | blocked (volume not mounted at all) |
| Agent exfiltrates a usable/refresh token | blocked | blocked |
| **Kernel/container escape from the agent reaches the vault** | **possible** | **blocked** (different namespace, no shared mount) |
| Compromise of the proxy process itself | has the vault | has the vault (but tiny attack surface: no agent code, no workspace, no model — only parses HTTP from the agent) |

This is the form that actually approaches Anthropic's sealed-VM property for the credential: the
secret lives behind a boundary the agent's container never shares.

## Verification (REQUIRED before this is trusted / merged)

**One-command path:** `./sidecar-smoketest.sh --up` brings the stack up and runs the structural
checks (3a–d below), the DNS canary, pinned-proxy policy, and Docker host-gateway rejection
automatically, plus the placeholder check once you've claimed. It does NOT do the
interactive `/login` or a billed model call. The manual walk-through below covers the same ground:

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

All six must hold. Until they're confirmed on real Docker, treat this as a design + scaffold only.
