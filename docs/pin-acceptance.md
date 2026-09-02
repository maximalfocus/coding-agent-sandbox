# Pin acceptance inventory

Every version, digest, source commit, and checksum this image bakes in is a pin. Moving one is a
rebuild and a revalidation, and the second half is the part that goes missing: the pin moves, every
automated check stays green, and some verification that rested on the old component's *runtime
behaviour* quietly stops being true of the shipped image.

That is not hypothetical. [#137](https://github.com/maximalfocus/coding-agent-sandbox/issues/137)
moved Herdr `0.7.5` → `0.8.2` in
[#138](https://github.com/maximalfocus/coding-agent-sandbox/pull/138). The `0.8.0` release in
between changed pane clipboard writes, copy-on-select, and mouse handling — which is what
[#129](https://github.com/maximalfocus/coding-agent-sandbox/issues/129)'s clipboard work rests on.
`scripts/test-osc52-boundary.sh` stayed green, correctly: it proves the host-side gate behaves once
an OSC 52 sequence *arrives*. Whether Herdr still *emits* one on a real drag-select was only ever
established by a person at a real terminal, and nothing told anyone that half had lapsed.

The same commit found the mirror image by accident. `mitm/filter_addon.py`'s `REFRESH_USER_AGENT`
says in its own comment that it tracks the pinned CLI, and it still claimed `claude-cli/2.1.233`
while the image shipped `2.1.252`. `scripts/check-provider-contracts.sh` compares each pin to its
own source file, so two pins that must move together can drift apart while every check passes.

This inventory records, for each pin, **what verification rests on that component behaving the way
it did when the pin was set**, and whether re-running that verification needs a person.

## Running the check

```bash
scripts/check-pin-acceptance.sh          # human-readable
scripts/check-pin-acceptance.sh --json   # machine-readable
```

It reads no credential, makes no network call, and starts no container.

### What the three outcomes mean

| Outcome | Meaning |
|---|---|
| `PASS` | The pin is where this inventory says it lives, and the verification resting on it is one a repository check can re-run. |
| `DRIFTED` | Either a pin baked into `Dockerfile` has no row here, or a row's recorded pin is no longer in the file it names. Fail-closed: this is an error exit. |
| `UNEVALUATED` | The pin is intact, but the verification resting on it needs an operator or hardware this check does not have. Never reported as a pass. |

`DRIFTED` covers both directions deliberately. A pin with no row is the failure this inventory
exists to prevent — someone edited `Dockerfile` by hand and no one recorded the cost. A row whose
pin has moved is this file rotting behind the code, which is how the sibling inventory in
[`provider-contracts.md`](provider-contracts.md) would fail too.

### What is recorded here

Verification that depends on the component's **runtime behaviour** — what the shipped binary does,
not that a string is present. A check that merely asserts the pin *is* the pinned value proves
nothing about a bump and is deliberately excluded; listing it would turn this into a grep index.

`verification` may be `none`, and then `note` must say why nothing depends on that component's
behaviour. "Nothing depends on this" and "nobody looked" must not be indistinguishable.

An entry prefixed `operator:` names a check no automated run can produce. An entry prefixed
`host:` names one that *is* automated but needs a host class this machine is not — the distinction
[`verification-hosts.md`](verification-hosts.md) already draws. Both mean "not re-runnable here",
and collapsing them would lose the part that says how to get it run.

## The pins that carry an operator-only check

**Herdr** carries `operator:herdr-selection-copy` — a human drag-select in a Herdr pane through
`./shell.sh`, landing on the host clipboard. `scripts/test-osc52-boundary.sh` covers everything
downstream of the sequence arriving; it cannot drive a mouse. **This check has not been re-run at
`0.8.2`.**

**ttyd and its vendored client** carry `operator:browser-clipboard` — select-and-paste in the
browser terminal. The behavior remains operator-only, but the artifact is also covered by
`verify-ttyd-client-reproducibility.sh`: two independent builds from the source, lock, patch, and
toolchain record in [`../ttyd/reproducibility.env`](../ttyd/reproducibility.env) must match the
committed bytes. `check-ttyd-client-drift.sh` separately reports live upstream and advisory drift.

**Claude Code** carries `operator:live-refresh` — a live token refresh through the sidecar. The pin
is coupled: `mitm/filter_addon.py`'s refresh `User-Agent` must move with it, and the value was
derived empirically in [#102](https://github.com/maximalfocus/coding-agent-sandbox/issues/102)
against a provider that rejects unfamiliar client fingerprints. It was last exercised at `2.1.233`.

**Per-architecture checksums** carry `host:verify-image-architectures.sh`. That script is fully
automated, but it needs a real build on hardware of each architecture; on one machine it reports the
other as not covered rather than passing it. It is not an operator judgement — it is a machine this
checkout does not have.

## Machine-readable pins

Fields are `|`-separated; surrounding whitespace is ignored. Notes must not contain `|`.

- `files` — repository-relative paths that must contain `pin`, comma-separated.
- `pin` — the exact literal expected in each of those files.
- `verification` — comma-separated check names, or `none`. An `operator:` prefix marks a check no
  automated run can produce; a `host:` prefix marks one that needs another host class.
- `rerun` — `repo`, `host`, or `operator` when every listed check is of that one class, `mixed` when
  more than one class appears, `none` alongside `verification=none`. The check derives the expected
  value from the entries and refuses a row that declares a different one.
- `note` — `-`, or free text. Required when `verification` is `none`.

```pin-acceptance
# id | component | files | pin | verification | rerun | note
base.golang | Go builder base image | Dockerfile | FROM golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651 AS go-cli-builder | verify-cli-security.sh | repo | -
base.node | Runtime base image | Dockerfile | FROM node:22-bookworm@sha256:5647be709086c696ff32edaaf1c70cd26d1da6ab2b39c32f3c7b4c4a31957e37 | verify-debian-security.sh | repo | -
gh.source-commit | GitHub CLI built from source | Dockerfile | ARG GH_SOURCE_COMMIT=01b79dd983af0859e4e3d7454961ad3f08cf88b4 | verify-cli-security.sh | repo | -
buildx.source-commit | Docker Buildx built from source | Dockerfile | ARG BUILDX_SOURCE_COMMIT=05a1121b29302f90e5b8457de21a1c0ce6ccecba | verify-cli-security.sh | repo | -
compose.source-commit | Docker Compose built from source | Dockerfile | ARG COMPOSE_SOURCE_COMMIT=37dea37d6751d0a98640c2b4c27066ace2688399 | verify-cli-security.sh | repo | -
aws-cli.version | AWS CLI | Dockerfile | ARG AWS_CLI_VERSION=2.36.7 | test-aws-sso-support.sh | repo | -
aws-cli.sha256.amd64 | AWS CLI amd64 artifact | Dockerfile | ARG AWS_CLI_SHA256_AMD64=d641283d37f1a2168457a9f26a20d4e29167652e9ab1719b37114ef1ebe859f4 | host:verify-image-architectures.sh | host | needs a real build on amd64 hardware
aws-cli.sha256.arm64 | AWS CLI arm64 artifact | Dockerfile | ARG AWS_CLI_SHA256_ARM64=85826b67912b44bb45d1e46c6e66f383c14405ee0b2f4686f73bdf949c93bd61 | host:verify-image-architectures.sh | host | needs a real build on arm64 hardware
docker-cli.version | Docker CLI apt package | Dockerfile | ARG DOCKER_CLI_VERSION=5:29.6.2-1~debian.12~bookworm | verify-cli-security.sh | repo | -
docker-buildx.version | Docker Buildx apt package | Dockerfile | ARG DOCKER_BUILDX_VERSION=0.35.0-1~debian.12~bookworm | verify-cli-security.sh | repo | -
docker-compose.version | Docker Compose apt package | Dockerfile | ARG DOCKER_COMPOSE_VERSION=5.3.1-1~debian.12~bookworm | verify-cli-security.sh | repo | -
ttyd.version | Browser terminal server | Dockerfile | ARG TTYD_VERSION=1.7.7 | operator:browser-clipboard | operator | only a person at a browser can show select-and-paste
ttyd.sha256.amd64 | ttyd amd64 artifact | Dockerfile | ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 | host:verify-image-architectures.sh | host | needs a real build on amd64 hardware
ttyd.sha256.arm64 | ttyd arm64 artifact | Dockerfile | ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 | host:verify-image-architectures.sh | host | needs a real build on arm64 hardware
ttyd.client-bundle | Vendored xterm.js web client | Dockerfile | 85baf6f288791e6012feec6257a8dd3665a449891692e7142debffbe24f99003 | verify-ttyd-client-reproducibility.sh,operator:browser-clipboard | mixed | two clean builds cover bytes; browser select-and-paste remains operator-only
npm.version | npm | Dockerfile | ARG NPM_VERSION=11.18.0 | verify-npm-bundle.sh | repo | -
claude-code.version | Claude Code CLI | Dockerfile | ARG CLAUDE_CODE_VERSION=2.1.252 | verify-npm-bundle.sh,check-provider-contracts.sh,operator:live-refresh | mixed | refresh User-Agent in mitm/filter_addon.py must move with it
codex.version | Codex CLI | Dockerfile | ARG CODEX_VERSION=0.140.0 | verify-npm-bundle.sh,verify-codex-sandbox.sh | repo | also anchors a recorded feasibility verdict
pi.version | Pi CLI | Dockerfile | ARG PI_VERSION=0.84.4 | verify-npm-bundle.sh | repo | -
herdr.version | Terminal multiplexer | Dockerfile | ARG HERDR_VERSION=0.8.2 | test-osc52-boundary.sh,operator:herdr-selection-copy | mixed | operator half not re-run at this pin
herdr.sha256.amd64 | Herdr amd64 artifact | Dockerfile | ARG HERDR_SHA256_AMD64=976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4 | host:verify-image-architectures.sh | host | needs a real build on amd64 hardware
herdr.sha256.arm64 | Herdr arm64 artifact | Dockerfile | ARG HERDR_SHA256_ARM64=f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d | host:verify-image-architectures.sh | host | needs a real build on arm64 hardware
bun.version | Bun | Dockerfile | ARG BUN_VERSION=1.3.11 | verify-npm-bundle.sh | repo | -
playwright.version | Playwright | Dockerfile | ARG PLAYWRIGHT_VERSION=1.58.2 | verify-npm-bundle.sh | repo | -
```
