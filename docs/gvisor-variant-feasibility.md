# gVisor variant — feasibility verdict

**Verdict: NO-GO at `runsc release-20260810.0`.**

A gVisor-backed variant of this sandbox cannot preserve both of the security contracts it would have
to preserve. gVisor requires `CAP_NET_RAW` inside the container for in-sandbox `iptables`; this
project's capability baseline deliberately withholds it. You can have the mandatory firewall or the
capability baseline under gVisor, not both — and the way to "have both" would be to hand the agent a
packet-crafting primitive the default stack denies it, in the name of hardening.

So this stops at a documented result rather than shipping a variant that weakens the boundary it
claims to strengthen — the same discipline as the [Codex subscription broker
verdict](codex-subscription-broker-feasibility.md) and the [upstream-proxy
verdict](sbx-upstream-proxy-feasibility.md).

The immediate consequence for operators is in `SECURITY.md`, which used to recommend uncommenting
`runtime: runsc` in `docker-compose.yml`. That advice was never exercised and does not work: the
container restart-loops. It has been corrected.

## What was established, and how

Performed 2026-08-16 on a **bare-kernel Linux host** (`kernel:bare`) — Ubuntu 26.04 LTS, kernel
`7.0.0-29-generic`, x86_64, Docker 29.7.2, `/dev/kvm` present. gVisor cannot be exercised on macOS or
Windows, where Docker runs inside a Linux virtual machine; see [`verification-hosts.md`](verification-hosts.md).

`runsc release-20260810.0` (spec 1.2.1) was installed from the vendor's release channel with its
published SHA-512 verified, and registered as a Docker runtime with `runsc install`.

### gVisor itself works

It is genuinely interposing — this is not a case of the runtime silently doing nothing:

| Runtime | Kernel the container reports |
|---|---|
| `runsc` | `Linux 4.19.0-gvisor #1 SMP … x86_64` |
| `runc` | `Linux 7.0.0-29-generic` |

`dmesg` inside the sandbox shows `Starting gVisor…` and `Synthesizing system calls…`.

### The blocking finding

The sandbox's mandatory firewall (`CAS-R021`) needs `iptables` inside the container. Under gVisor it
fails, and the reason is capability-shaped rather than backend-shaped:

| Runtime | Capability set | `iptables` |
|---|---|---|
| `runsc` (`--net-raw=true`) | the `CAS-R002` baseline — `cap_drop: ALL` plus `NET_ADMIN`, `SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE` | **fails** |
| `runsc` (`--net-raw=true`) | that baseline **plus `NET_RAW`** | works |
| `runc` | the `CAS-R002` baseline | works |

Two separate obstacles were found on the way, and both are recorded because each is independently
true:

1. **Backend.** The image's `iptables` uses Debian's nftables backend, which gVisor does not
   implement — `iptables: Failed to initialize nft: Protocol not supported`. Reproduced on a minimal
   Alpine image, so this is gVisor's behaviour and not something about this image.
2. **Capability.** Switching to `iptables-legacy` gets past that and hits the real wall:
   `can't initialize iptables table 'filter': Table does not exist`. That resolves only when the
   container holds `CAP_NET_RAW`, which the baseline forbids.

**Both conditions are required, and neither alone is enough.** The runtime must be registered with
`--net-raw=true` *and* the container must actually be granted `NET_RAW`. The flag only stops gVisor
stripping the capability — with `cap_drop: ALL` in force, Docker removes it anyway; and the
capability alone is useless on a runtime that strips it. This is why the probe reports the second
half as `UNVERIFIED` on a host with no `--net-raw` runtime registered, rather than treating its
absence as a change.

Granting `NET_RAW` is not a neutral workaround. gVisor's own flag documentation describes raw sockets
as something that "allow malicious containers to craft packets and potentially attack the network".
A hardening variant that quietly adds that capability would trade a real, enforced boundary for a
theoretical one.

### `CAS-R142` — the combination with nested container builds (`SL-14`)

**Unsupported**, with the same root cause. The nested Docker daemon refuses to start under gVisor:

```
failed to start daemon: Error initializing network controller: … failed to register "bridge" driver:
failed to create NAT chain DOCKER: iptables failed: iptables --wait -t nat -N DOCKER:
iptables: Failed to initialize nft: Protocol not supported
```

`runsc` does accept `--privileged` containers, so the obstacle is specifically netfilter, not
privilege. This is recorded as a determined result rather than an assumption, which is what
`CAS-R142` asks for.

## What this does not say

- **Not** that gVisor is a weak boundary. It is a user-space kernel that meaningfully reduces host
  kernel attack surface, and it is not a VM or hypervisor boundary either. Both halves of that
  remain true and neither is what blocked this.
- **Not** that gVisor cannot run containers here. It runs them fine. The incompatibility is
  specifically with a container that installs its own netfilter rules while holding a minimal
  capability set — which is exactly what this project's agent container is.
- **Not** a permanent verdict. It is pinned to `runsc release-20260810.0` and to the requirement text
  as it stands.

## Reevaluation triggers

Re-run `scripts/probe-gvisor-support.sh` and revisit this document when any of these becomes true:

1. gVisor implements the nftables protocol, or supports the legacy `filter` table without requiring
   `CAP_NET_RAW` in the container.
2. A gVisor release documents an option that grants in-sandbox netfilter without raw sockets.
3. `CAS-R002`'s capability baseline changes for an unrelated reason that already includes `NET_RAW` —
   in which case the trade being refused here no longer exists, and the question is worth reopening
   on its own merits rather than as a side effect.
4. The nested-daemon obstacle in `CAS-R142` is resolved upstream, independently of the above.

The probe reports `CHANGED` when a fact this verdict rests on no longer holds, and `UNVERIFIED` —
never a pass — for anything it cannot evaluate on the host it is run on.

## What was deliberately not built

No overlay, no launcher flag, no prerequisite-detection path, and no capability-set change. A
`NO-GO` adds no adapter and no configuration grant, exactly as the `SL-13` verdict did. The only
product change accompanying this document is the removal of the incorrect hardening advice.
