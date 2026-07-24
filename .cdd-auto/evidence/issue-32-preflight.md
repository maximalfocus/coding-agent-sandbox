# Issue 32 preflight evidence — 2026-07-24

Environment: Docker Engine/Desktop 29.4.0 on macOS/arm64; `coding-agent-sandbox:latest`; Codex CLI 0.140.0. These are diagnostic measurements, not the portable acceptance gate.

## Codex with no `bwrap` on PATH

Inside the live default service as `node`:

```sh
command -v bwrap                    # no output, exit 1
codex exec --ephemeral -s workspace-write --skip-git-repo-check \
  -C /tmp/bwrap-probe 'Run pwd with the shell tool exactly once, then answer only DONE.'
```

Observed before any package installation:

```text
warning: Codex could not find bubblewrap on PATH. ... Codex will use the bundled bubblewrap in the meantime.
bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.
```

The model completed, but its shell command exited 1; therefore the session response itself is not evidence that sandbox command execution worked.

## Debian bubblewrap on PATH

Debian `bubblewrap 0.8.0` was temporarily installed in the running disposable container only. It was not added to the image or repository.

```sh
bwrap --ro-bind / / --proc /proc --dev /dev true
codex exec --ephemeral -s workspace-write --skip-git-repo-check \
  -C /tmp/bwrap-probe-path 'Run pwd with the shell tool exactly once, then answer only DONE.'
```

Both direct bwrap and the Codex shell command failed namespace creation. The PATH warning disappeared. This proves warning removal is not functional improvement.

## Control-isolation matrix

Every row executed the bundled Codex bwrap binary operationally as `node`:

```sh
bwrap --ro-bind / / --proc /proc --dev /dev /bin/true
```

| Docker controls | Result |
|---|---|
| Shipped minimal caps + `no-new-privileges:true` + Docker built-in seccomp | namespace creation denied |
| Same, remove only `no-new-privileges` | namespace creation denied |
| Same, retain NNP but set `seccomp=unconfined` for the disposable diagnostic container | success |
| Same, remove NNP and set `seccomp=unconfined` | success |
| Privileged diagnostic container | success |

Inside the shipped default service, `/proc/self/status` showed `NoNewPrivs: 1`, `Seccomp: 2`, no effective capabilities for `node`, and the Docker engine reported `seccomp,profile=builtin`. `user.max_user_namespaces` was nonzero (48185); `kernel.unprivileged_userns_clone` was not exposed by this Docker Desktop VM.

Conclusion for this measured runtime: Docker's built-in seccomp profile is the differentiating blocker; NNP and the existing capability set are not. This does not claim every host kernel supports user namespaces—the delivered verifier must classify host/runtime restrictions independently and fail closed on unknown errors.

## Variant operation probes

The same operational bundled-bwrap command was launched through each Compose service definition:

| Variant/service | Result |
|---|---|
| `docker-compose.yml` / `claude-sandbox` | namespace creation denied |
| `docker-compose.mitm.yml` / `claude-sandbox-mitm` | namespace creation denied |
| `docker-compose.sidecar.yml` / `claude-sandbox-node` | namespace creation denied |

The sidecar egress service was not treated as a Codex execution variant: it runs only the proxy/vault entrypoint and has no agent workspace or Codex configuration surface. Its static controls were still inspected. All three agent execution services specify the same `cap_drop: ALL`, minimal added caps, and `no-new-privileges:true`; neither the agent services nor the egress service ships a seccomp override, `SYS_ADMIN`, host namespace sharing, or privileged mode.

## Nested sandbox functional diagnostic

Only in a disposable diagnostic container with `seccomp=unconfined`—not a proposed or shipped configuration—this real command succeeded:

```sh
codex sandbox -P :workspace -C /workspace bash -c '<probe>'
```

Observed: workspace write `0`; protected outside write nonzero; network attempt nonzero. This proves `codex sandbox` can exercise the required functional smoke when the runtime permits user namespaces, while confirming why `bwrap --version` is insufficient.
