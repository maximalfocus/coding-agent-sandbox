# Issue 28 acceptance contract — patched bundled npm dependencies

Source of truth: https://github.com/maximalfocus/coding-agent-sandbox/issues/28

## Scenario 1 — npm distribution is deliberately upgraded

**Given** the pinned `node:22-bookworm` base image bundles npm with vulnerable transitive dependencies  
**When** the sandbox image is built  
**Then** the Dockerfile installs one exact, Node-compatible patched npm release rather than individually mutating npm's internal dependency tree.

## Scenario 2 — reported npm dependency vulnerabilities are removed

**Given** the rebuilt `coding-agent-sandbox:latest` image  
**When** its npm installation under `/usr/local/lib/node_modules/npm` is inspected  
**Then** `tar` is at least 7.5.19, `brace-expansion` is not vulnerable to CVE-2026-13149, `picomatch` is at least 4.0.4, and `sigstore` is at least 4.1.1  
**And** the five findings named in issue 28 do not appear in `./scan.sh`.

## Scenario 3 — strict critical scan passes

**Given** the rebuilt image  
**When** `TRIVY_SEVERITY=CRITICAL TRIVY_STRICT=1 ./scan.sh` runs  
**Then** it exits successfully.

## Scenario 4 — bundled agent CLIs still start

**Given** the rebuilt image  
**When** npm, Claude Code, Codex, OpenCode, Pi, Bun, and Playwright are invoked with non-interactive version/help commands  
**Then** each command starts and exits successfully.

## Scope

Only the npm distribution bundled by the Node base image and deterministic verification/documentation needed for this remediation are in scope. Other Debian or third-party CLI vulnerability findings are non-goals.
