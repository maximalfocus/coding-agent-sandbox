# Egress-admission decisions

One admission policy, five paths that construct it and two engines that decide with it. Nothing used
to compare them, so a divergence between the stacks could only be found by reading five files.

```
construct   entrypoint.sh                build_filter      -> (^|\.)domain$ into the tinyproxy filter
            mitm/entrypoint.sh           build_allowlist   -> the ALLOWLIST csv
            mitm/sidecar-entrypoint.sh   its own builder, plus a DeepSeek exclusion the others lack
            scripts/network/allow-domain.sh    hot-add, re-deriving the same anchored pattern
            scripts/network/allow-domain.ps1   the PowerShell twin of that
decide      tinyproxy.conf               FilterExtended, FilterCaseSensitive Off, FilterDefaultDeny
            mitm/filter_addon.py         _matches(), which lowercases and strips a trailing root dot
```

`scripts/check-allowlist-parity.sh` proves the cases below against those paths. It executes what can
be executed and compares the rest, and it says which it did for every row.

## What is executed, and what is compared

The two **engines** are always executed, never modelled — a check that re-implemented a regex engine
would be asserting its own opinion of `FilterExtended` rather than tinyproxy's. The default verdict
comes from tinyproxy itself running the shipped configuration; the mediation verdict comes from the
addon's own `_matches()`.

Of the five **construction** paths, two expose their builder as a function behind a `root` guard and
are executed directly: `entrypoint.sh`'s `build_filter` and `mitm/entrypoint.sh`'s `build_allowlist`.
The other three cannot be invoked in isolation — the sidecar builds its allowlist as straight-line
script, the shell hot-add refuses before a running stack, and the PowerShell twin needs a Windows
runtime. For those, the check asserts **predicate parity**: every path must carry the byte-identical
hostname validation and the same anchoring, because that predicate *is* the decision. A path that
changes how it validates therefore fails here even though its builder was never run.

## Cases

Two categories, because they ask different questions of different components. `input` asks whether a
builder admits a configuration entry into the policy at all. `runtime` asks whether an engine admits
a request host, given an allowlist containing `anthropic.com`.

An `undecided` runtime row records a real difference between the engines that no requirement settles.
`CAS-R020` does not choose between them, so the row states both verdicts rather than asserting either
is correct; it is not an expected difference until a product decision is recorded here with a reason.

```allowlist-input
# entry | verdict | why
anthropic.com | admit | ordinary multi-label hostname
api.anthropic.com | admit | subdomains are admitted as their own entry too
com | refuse | a bare TLD would admit every .com host
localhost | refuse | single label, no dot
8.8.8.8 | refuse | IP literal, which anchoring cannot make safe
169.254.169.254 | refuse | IP literal covering the cloud-metadata address
*.anthropic.com | refuse | regex metacharacter would widen the generated pattern
foo|.* | refuse | alternation would admit everything
.anthropic.com | refuse | leading dot produces an empty label
anthropic.com. | refuse | trailing dot produces an empty label
-anthropic.com | refuse | label may not begin with a hyphen
anthropic-.com | refuse | label may not end with a hyphen
```

```allowlist-runtime
# host | tinyproxy | filter_addon | status | why
anthropic.com | admit | admit | agreed | the allowlisted host itself
api.anthropic.com | admit | admit | agreed | a subdomain of it
deep.api.anthropic.com | admit | admit | agreed | nested subdomains too
ANTHROPIC.COM | admit | admit | agreed | hostnames are case-insensitive on both sides
evil-anthropic.com | refuse | refuse | agreed | suffix near-miss, the anchoring's whole purpose
notanthropic.com | refuse | refuse | agreed | the same near-miss without a hyphen
anthropic.com.evil.test | refuse | refuse | agreed | the allowlisted name as a left-hand label
xanthropic.com | refuse | refuse | agreed | one character before the allowlisted name
anthropic.com. | refuse | admit | undecided | DNS-equivalent trailing root dot; CAS-R020 does not choose, and filter_addon strips it while the generated pattern anchors on $
api.anthropic.com. | refuse | admit | undecided | the same, for a subdomain
```

## Reading a result

`PASS` means every executed verdict matched the case and every compared predicate was identical.
`DIVERGED` means an engine or a builder disagreed with its recorded verdict, or two paths that must
agree no longer carry the same predicate. `UNEVALUATED` means an engine could not be executed in this
environment — the default engine needs the built image, since tinyproxy is what ships in it — and is
never reported as a pass.

An `undecided` row is not a failure: both verdicts are recorded and both are asserted, so the row
fails if *either* engine changes its answer. Settling it means changing one engine and moving the row
to `agreed`, with the reason recorded here.
