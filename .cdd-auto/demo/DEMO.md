# Issue 28 acceptance demo

The rebuilt image exposes the remediation through one fail-closed command:

```sh
set -euo pipefail
docker compose build claude-sandbox
./scripts/verify-npm-bundle.sh
TRIVY_SEVERITY=CRITICAL TRIVY_STRICT=1 ./scan.sh
TRIVY_SEVERITY=HIGH,CRITICAL ./scan.sh > /tmp/sandbox-trivy.txt
if grep -E 'CVE-2026-(59873|59874|13149|33671|48815)' /tmp/sandbox-trivy.txt; then
  echo 'issue-28 CVEs remain' >&2; exit 1
else
  rc=$?; [ "$rc" -eq 1 ] || exit "$rc"
fi
```

The bundle verifier prints the installed npm-internal package versions and then starts npm, Claude Code, Codex, OpenCode, Pi, Bun, and Playwright. Any vulnerable package occurrence, version mismatch, missing CLI, or failed startup exits nonzero.

Verified on 2026-07-24 against `coding-agent-sandbox:latest`:

```text
tar: 7.5.19
brace-expansion: 5.0.7
picomatch: 4.0.4
sigstore: 4.1.1
npm: 11.18.0
```

The strict CRITICAL scan reported zero CRITICAL findings; none of the five issue-28 CVEs appeared in the HIGH/CRITICAL report.
