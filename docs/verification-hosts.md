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
| Any `*.ps1` | `any` for the syntax gate; `os:windows` before a release that changes launcher behaviour | **`scripts/test-powershell-syntax.sh`** |
| Firewall, proxy, allowlist, credential-injection logic | `any` | the `mitm/test_*.py` suites, `sidecar-smoketest.sh` |
| Compose structure, documentation, verification tooling | `any` | the `scripts/test-*.sh` suites |

## Reaching another machine

When a verification needs a host this one is not, use:

```bash
scripts/verify-on-host.sh --list                    # which hosts are registered
scripts/verify-on-host.sh idd -- 'docker build …'   # run it there
```

It prints the host class it actually reached, so a claim can name it:

```
host: idd (10.131.4.113) — arch:x86_64 kernel:bare Linux
host-class: arch:x86_64 kernel:bare (idd)
```

**Do not reach these machines by alias alone.** They hold DHCP leases on a network that resolves no
names, so an address is the only handle and it moves. A stale alias either fails in a way that looks
like the host being down, or connects to whatever machine inherited the lease — and a result recorded
against the wrong host class is worse than one that admits it did not run.

Resolution is therefore delegated to the maintained fleet tool, which identifies a machine by its
**SSH host key** — the one thing that does not move — and repairs the alias to match.
`scripts/verify-on-host.sh` contains no discovery logic of its own, and a test asserts that no second
implementation exists anywhere in `scripts/`. If the fleet tool is unavailable the wrapper stops and
says so; it will not fall back to a plain `ssh <alias>`, because that fallback is the failure being
removed.

Point `FIND_HOST` at the tool if it is not in one of the documented locations or on `PATH`.

## Verifying both architecture branches

The image resolves architecture-specific downloads through `case` statements on `TARGETARCH`, and
each branch carries its **own SHA-256 constant**. A wrong checksum or a rotted URL in one branch
cannot be caught by building the other — the branch that did not build was never executed.

```bash
scripts/verify-image-architectures.sh                    # both architectures
REMOTE_ARCH_HOST=idd scripts/verify-image-architectures.sh
```

It builds locally for this machine's architecture and, through `scripts/verify-on-host.sh`, on a
fleet host for the other. Each row names the host class it ran on, and an architecture that could not
be built is reported **`NOT COVERED`** — never folded into a pass, because a partial run that reads
like a complete one is worse than no check at all.

**It builds with `--no-cache`, and that is the point.** A cached layer never executes, so a
warm-cache build does not run `sha256sum` at all: deliberately corrupting an architecture's checksum
and rebuilding reported `CACHED` and *succeeded*. Only with `--no-cache` does the same corruption
fail the build — which is what `CAS-R160` actually asks for.

Two consequences follow, and both are normal rather than faults:

- **It is slow.** A clean build is tens of minutes per architecture. This is a per-release check, not
  a per-change one.
- **It is network-dependent.** A clean build re-fetches every pinned artifact, so a failure at a
  download step may be a transient network problem rather than a broken branch. One such failure was
  observed during this work — a Go module download — and a retry of the identical build succeeded.
  **Read the reported cause before treating a failure as a broken architecture.** The gate
  deliberately does not retry on your behalf: a check that retries until it passes is not a check.

## Stating the host class in a claim

A verification claim should name the host class it actually ran on, and a class that was not run is
recorded as **unverified** rather than assumed. "Verified on macOS arm64 (`kernel:vm`); `kernel:bare`
not run" is a complete and honest claim. "Verified" on its own is not.

Broad claims of cross-platform verification are not made from a single host class.

## The PowerShell gate, and what it does not cover

`scripts/test-powershell-syntax.sh` parses every tracked `*.ps1` inside a pinned container and
rejects constructs that Windows PowerShell 5.1 cannot parse. It needs **no Windows machine**, which
is the entire point: a check that needs one does not get run, and this repository ships fifteen
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

## The `os:windows` runtime pass

```sh
scripts/verify-powershell-runtime.sh [alias]     # default alias: win
```

Ships the tracked `*.ps1` files to a real Windows host and parses each one with **that runtime's own
parser**, through `scripts/verify-on-host.sh` so the machine is reached by stable identity and the
host class it reached is reported. It refuses to report a pass unless `$PSVersionTable` shows
version 5 and the `Desktop` edition, and it runs a negative control — a 7-only construct that the
runtime must reject — because a gate that cannot be shown to fail is not evidence.

**First run, 2026-08-17, `win` — `arch:AMD64 kernel:vm Windows`, PowerShell `5.1.26100.9168`
(`Desktop`).** It immediately earned its existence: **4 of 16 tracked files failed to parse** on the
runtime they target, while all 16 parse under the container gate.

The cause is not a 7-only construct. Windows PowerShell 5.1 decodes a file without a BOM using the
system code page — `Windows-1252` on this host — not UTF-8. This repository's files contain em dashes,
including inside `Write-Host` strings, and 5.1's parser treats curly quotes as string delimiters, so
the mis-decoded bytes unbalance the parse. Measured on the same file: **17 parse errors read with the
default encoding, 0 read as explicit UTF-8.**

The container gate cannot see this, and not because it was written carelessly — pwsh 7 defaults to
UTF-8, so the file it parses is not the file 5.1 reads. This is exactly the class of difference
`CAS-R162` exists to catch, and it is why "parsing is not running" is written into the table above.

If Docker or the pinned image is unavailable, or the run exceeds its timeout, the gate exits `2` and
says it could not run. It never reports success for files it did not parse.

### Why the image is built here rather than pulled

`Dockerfile.pwsh` builds the verification image from the official PowerShell release tarball, pinned
to an exact version with a distinct vendor-published SHA-256 per architecture — the same pattern used
for `ttyd`, Herdr, and the AWS CLI.

It does not use `mcr.microsoft.com/powershell`, which is published for **linux/amd64** and
**linux/arm (v7)** only, with no `linux/arm64` on any current tag. On an arm64 host Docker therefore
selects an image it has to emulate, and that emulation is not merely slow. On unchanged input it
produced, in one sitting:

- a container that hung indefinitely and had to be killed;
- a spurious `You cannot call a method on a null-valued expression` from a script with no such call;
- a QEMU assertion under `arm/v7` — `thumb_tr_translate_insn`, exit `139`; and
- a Rosetta assertion under emulated `amd64` — `BasicBlock requested for unrecognized address`,
  exit `133` — *after* the gate had already printed a correct result.

A check that fails at random teaches its operator to ignore it, which is worse than not having the
check. Building the image here removes the emulation entirely: it runs natively on both
architectures, and the gate has no host-architecture requirement at all.

The image is built automatically on first use, so the gate needs no separate setup step. That is what
makes it ordinary verification rather than something people forget to run.

### Verified on both architectures

Both checksum branches in `Dockerfile.pwsh` are exercised by real builds on real hardware, which is
what `CAS-R160` asks for — an unexercised architecture branch is exactly where a wrong checksum or a
rotted URL hides.

| Host class | Machine | Image build | Gate | Fixture suite |
|---|---|---|---|---|
| `arch:arm64`, `kernel:vm` | macOS on Apple silicon | native, 19s | PASS — 15 files, 0 failed | 10/10 |
| `arch:amd64`, `kernel:bare` | Ubuntu 26.04, kernel 7.0 | native, 29s | PASS — 15 files, 0 failed | 10/10 |

No behavioural difference between the two.
