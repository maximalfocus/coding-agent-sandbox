# Clipboard-enabled ttyd client

`index.html` is a reproducible, locally modified build of ttyd's inlined web client. The complete
machine-readable record is [`reproducibility.env`](reproducibility.env): immutable repository
commit and tree, `package.json` and Yarn lock hashes, local patch hash, exact Node container digest
and platform, Node/Corepack/Yarn versions, build invocation, and committed output checksum.

The source is `tsl0922/ttyd` commit
`647d55ad865f5ad85ad89ba5e1b28d9b6ac8fd55`. Unlike ttyd 1.7.7's embedded client, it loads
xterm.js's `ClipboardAddon`, which handles OSC 52 clipboard sequences. The checked-in
[`apply-clipboard-patch.mjs`](apply-clipboard-patch.mjs) makes two local changes:

- an empty OSC 52 selection (`OSC 52 ; ; data ST`) is treated like selection `c`, because tmux emits
  the empty-selector form; and
- when `navigator.clipboard.writeText()` is denied, a temporary hidden textarea plus
  `document.execCommand("copy")` is used, then removed and the terminal is refocused.

The patch also preserves the optimizer-equivalent guard and generated source-map reference present
in the originally committed artifact. Both normalizations assert their exact input shape and fail
if upstream or toolchain output changes; they do not apply a fuzzy edit to unfamiliar bytes.

## Verify reproducibility

Run from a clean checkout on a host with Git and Docker:

```bash
./scripts/verify-ttyd-client-reproducibility.sh
```

The verifier creates two independent source checkouts, verifies the commit/tree and dependency
hashes, installs with Yarn `--immutable` inside the recorded digest-pinned Node image, applies the
local patch, runs `yarn inline`, and compares both candidates byte-for-byte with each other,
`ttyd/index.html`, `reproducibility.env`, and the Dockerfile checksum. A missing or changed input
fails under a named `INPUT`, `SOURCE`, `DEPENDENCY`, `TOOLCHAIN`, `PATCH`, `BUILD`, `ARTIFACT`, or
`REPRODUCIBILITY` stage. The command never changes a tracked file.

## Observe upstream drift

```bash
./scripts/check-ttyd-client-drift.sh
```

This host-run report names and queries the GitHub REST API for commit identity, commits, releases,
and current dependency files, then the npm advisory bulk API for every npm resolution in the
recorded lock. The manifest records the count and stable fingerprint of the observed advisory set,
so later additions or removals are reported as changes rather than treating every known advisory
as newly discovered. Exit `0` means no drift was observed, `10` means reviewable drift was
observed, and `2` means at least one required source is `UNEVALUATED`. None means "safe". Network,
rate-limit, schema, and classification failures are never described as current. The report writes
nothing and never updates the artifact.

## Explicit rebuild

Preview a candidate and its checksum first:

```bash
./scripts/ttyd-client-build.sh /tmp/ttyd-index.candidate.html
shasum -a 256 /tmp/ttyd-index.candidate.html
```

After deliberately updating and reviewing recorded inputs, replacement still requires the literal
apply flag and the reviewed candidate checksum. The command independently builds twice again and
refuses a mismatch before writing:

```bash
./scripts/rebuild-ttyd-client.sh --apply REVIEWED_64_HEX_SHA256
```

For a changed artifact, separately review and update `TTYD_ARTIFACT_SHA256` and the Dockerfile pin,
then run the verifier. Nothing performs a self-update.
