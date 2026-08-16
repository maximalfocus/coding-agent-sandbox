# Which host class a change needs

A verification claim is only as good as the machine it ran on. Several guarantees in this repository
cannot be proven on the machine they are usually developed on, and until recently that gap was
invisible rather than recorded — not because anything was wrong, but because nobody was asked which
host a result came from.

This file exists so that question gets asked routinely. It states **host properties**, not machines:
the requirement is that each property is covered, not that any particular fleet exists.

## Host properties

| Property | What it means | Why it cannot be substituted |
|---|---|---|
| **`arch:amd64`** / **`arch:arm64`** | A real image build on hardware of that architecture | The image selects architecture-specific downloads and **distinct SHA-256 constants** through `case` statements on `TARGETARCH`. The branch that did not build was never exercised, so a wrong checksum or a rotted URL for the other architecture stays invisible. |
| **`kernel:bare`** | Docker running directly on the host's own Linux kernel | macOS and Windows both run Docker inside a Linux virtual machine. Nested-daemon privilege, cgroup and LSM interaction, and any user-space kernel runtime are properties of the real kernel. A result from a virtualized host covers the virtualized case only. |
| **`kernel:vm`** | Docker inside a Linux VM (typical macOS/Windows developer host) | Fine for most work, and it is what most changes are developed on. It simply does not stand in for `kernel:bare`. |
| **`os:windows`** | A real Windows host running Windows PowerShell 5.1 | Path translation, line endings, and launcher behaviour are Windows runtime properties. Parsing is not running. |
| **`any`** | No special property required | Shell, Python, Compose structure, documentation, and the mediation layer's own logic. |

## What each kind of change needs

| Change touches | Needs | Continuous check that runs anywhere |
|---|---|---|
| A pinned download, checksum, or `TARGETARCH` branch in `Dockerfile` | `arch:amd64` **and** `arch:arm64` | — (a build is the only proof) |
| Nested Docker (`docker-compose.dind.yml`, `mitm/dind-entrypoint.sh`) | `kernel:bare` for the privilege and confinement claims; `kernel:vm` is a partial result | `scripts/test-nested-docker.sh` (structural) |
| A gVisor / `runsc` variant | `kernel:bare` — `runsc` cannot be installed or exercised on a virtualized Docker host | — |
| Any `*.ps1` | `arch:amd64` to run the syntax gate at all; `os:windows` before a release that changes launcher behaviour | **`scripts/test-powershell-syntax.sh`** (amd64 hosts only — see below) |
| Firewall, proxy, allowlist, credential-injection logic | `any` | the `mitm/test_*.py` suites, `sidecar-smoketest.sh` |
| Compose structure, documentation, verification tooling | `any` | the `scripts/test-*.sh` suites |

## Stating the host class in a claim

A verification claim should name the host class it actually ran on, and a class that was not run is
recorded as **unverified** rather than assumed. "Verified on macOS arm64 (`kernel:vm`); `kernel:bare`
not run" is a complete and honest claim. "Verified" on its own is not.

Broad claims of cross-platform verification are not made from a single host class.

## The PowerShell gate, and what it does not cover

`scripts/test-powershell-syntax.sh` parses every tracked `*.ps1` inside a pinned container and
rejects constructs that Windows PowerShell 5.1 cannot parse. It needs **no Windows machine**, which
is the entire point: a check that needs one does not get run, and this repository ships fourteen
PowerShell files that previously had no automated check at all while the shell half had `bash -n`.

It works in two passes, because one is not enough:

1. **Parse.** A file that does not parse fails, reported with the parser's own message.
2. **Reject 7-only constructs.** The container runs PowerShell 7, which accepts a superset of 5.1
   syntax — null-coalescing, null-conditional, ternary, and pipeline chains all parse happily under 7
   and cannot parse under 5.1. Those are detected from the **parser's token stream**, not from the
   file text, because this repository's PowerShell files legitimately contain `||` inside
   single-quoted shell strings passed to `docker compose exec`. There are three such lines today and
   every one of them is a false positive for a textual scan. A token is never ambiguous that way: an
   operator inside a string literal is part of the string token.

**What it is not:** a Windows PowerShell 5.1 runtime. It parses; it never executes a script under
test. Behavioural differences, path translation, and line-ending handling are outside it, and a real
`os:windows` run is still required before a release that changes launcher behaviour. `CAS-R162` asks
for both and says plainly that neither substitutes for the other.

If Docker or the pinned image is unavailable, or the run exceeds its timeout, the gate exits `2` and
says it could not run. It never reports success for files it did not parse.

### Why the gate needs an amd64 host

Microsoft publishes `mcr.microsoft.com/powershell` for **linux/amd64** and **linux/arm (v7)** only.
There is no `linux/arm64` build on any current tag. On an arm64 host — which is what this project is
usually developed on — Docker therefore selects an image it has to emulate, and that emulation is not
merely slow. On unchanged input it produced, in one sitting:

- a container that hung indefinitely and had to be killed;
- a spurious `You cannot call a method on a null-valued expression` from a script with no such call;
- a QEMU assertion under `arm/v7` — `thumb_tr_translate_insn`, exit `139`; and
- a Rosetta assertion under emulated `amd64` — `BasicBlock requested for unrecognized address`,
  exit `133` — *after* the gate had already printed a correct result.

So the gate refuses to run under emulation and exits `2` with that reason. A check that fails at
random teaches its operator to ignore it, which is worse than not having the check — this repository
has already had to remove one such check, and will not ship another.

**What this costs:** on an arm64 developer machine the gate reports that it could not run, so
PowerShell changes made there are not parsed until they reach an amd64 host. That is a real gap in
`CAS-R162`'s "as part of ordinary verification", stated here rather than papered over. Closing it
would mean building a PowerShell image for `linux/arm64` from the official `linux-arm64` release
tarball, which adds a pinned download and an image build to this repository — a deliberate decision
that has not been taken.
