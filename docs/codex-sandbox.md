# Codex Linux sandbox inside the agent container

Codex 0.140.0 uses bubblewrap (`bwrap`) for its Linux `workspace-write` sandbox. In the shipped Docker profiles, Docker's outer seccomp boundary blocks the nested user-namespace operation bubblewrap needs. This is intentional: the project keeps its primary container boundary rather than broadly relaxing seccomp to add a second inner boundary.

## What you will see

With no `bwrap` on `PATH`, Codex reports:

```text
warning: Codex could not find bubblewrap on PATH. ... Codex will use the bundled bubblewrap in the meantime.
bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.
```

Installing Debian bubblewrap on PATH removes the warning but does **not** fix namespace creation in these profiles. It is therefore not installed in the image merely to silence a warning. A functional test must run a namespace command or `codex sandbox`; `bwrap --version` is not evidence of sandboxing.

## Measured control matrix

Measured on Docker Desktop/Engine 29.4.0, macOS arm64, with Codex 0.140.0. Other hosts can additionally prohibit unprivileged user namespaces; the verifier classifies only known namespace failures and fails closed on anything else.

| Controls varied in a disposable diagnostic container | Operational result |
|---|---|
| Shipped minimal caps + `no-new-privileges:true` + Docker built-in seccomp | namespace creation denied |
| Same, remove only `no-new-privileges` | namespace creation denied |
| Same, retain NNP but set `seccomp=unconfined` | namespace creation succeeds |
| Same, remove NNP and set `seccomp=unconfined` | namespace creation succeeds |
| Privileged diagnostic container | namespace creation succeeds |

The differentiating control on that runtime was Docker's built-in seccomp profile—not `no-new-privileges` and not the agent's effective capabilities. `seccomp=unconfined`, `SYS_ADMIN`, privileged mode, and host namespace sharing are not shipped or recommended: they weaken the outer host-kernel boundary that protects every agent command, while nested bubblewrap protects only Codex tool commands.

Debian bubblewrap on PATH was also run operationally with `--ro-bind / / --proc /proc --dev /dev /bin/true`; it failed exactly as the bundled binary did.

## Shipped variants

| Compose file | Codex execution surface | Shipped nested bubblewrap | Supported behavior |
|---|---|---|---|
| `docker-compose.yml` | `claude-sandbox` | blocked by Docker built-in seccomp | outer-container fallback |
| `docker-compose.mitm.yml` | `claude-sandbox-mitm` | blocked by Docker built-in seccomp | outer-container fallback |
| `docker-compose.sidecar.yml` | `claude-sandbox-node` | blocked by Docker built-in seccomp | outer-container fallback |

`claude-sandbox-egress` is only the sidecar proxy/vault, not an agent execution surface. It retains the same static least-privilege controls but does not run Codex against a workspace.

Nested bubblewrap is not a supported shipped profile on Docker's built-in seccomp policy. A runtime with a separately reviewed seccomp policy that permits the required user-namespace syscalls may run the nested profile, and the verifier will test it, but this project does not ship or endorse `seccomp=unconfined` or a forked full Docker profile.

## Safe fallback

The agent already runs as unprivileged `node` inside a container that exposes only configured workspace mounts and forces egress through the allowlist proxy/firewall. When the known namespace failure appears, run Codex with its sandbox disabled **only inside this outer sandbox**:

```bash
codex -s danger-full-access
```

For non-interactive commands:

```bash
codex exec -s danger-full-access -C /workspace 'your prompt'
```

Do not use this fallback directly on an untrusted host. `danger-full-access` means Codex adds no inner filesystem/network restriction; protection comes from Docker's mount scope, unprivileged user, capability drop, seccomp, `no-new-privileges`, and egress firewall.

## Functional smoke

With the desired variant running, execute:

```bash
./scripts/verify-codex-sandbox.sh --variant default
# or: --variant mitm / --variant sidecar
```

The verifier:

1. inspects the live container and refuses privileged, `SYS_ADMIN`, missing capability-drop/NNP, or unconfined-seccomp configurations;
2. runs a real command through `codex sandbox -P :workspace`;
3. if nested sandboxing works, proves workspace write, outside-write denial, and network denial;
4. if and only if the exact known namespace failure occurs, runs `codex sandbox -P :danger-full-access` and proves the outer protected-filesystem, proxy-filter, and direct-IP restrictions;
5. fails on missing Codex, unknown errors, malformed output, or an open restriction.

The local `codex sandbox` command does not require OpenAI authentication or model inference.
