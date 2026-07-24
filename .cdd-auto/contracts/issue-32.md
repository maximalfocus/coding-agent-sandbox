# Frozen acceptance contract — GitHub issue 32

Source: https://github.com/maximalfocus/coding-agent-sandbox/issues/32

## Scenario 1 — Reproduce both current Codex/bubblewrap behaviors

Given the shipped image and each agent execution variant (default, MITM, and sidecar agent),
when Codex executes a shell command with its `workspace-write` Linux sandbox,
then evidence records that no `bwrap` is on `PATH`, Codex selects its bundled binary, and namespace creation fails.

When Debian's `bubblewrap` package is temporarily installed on `PATH`,
then the warning disappears but the same functional namespace failure remains; warning removal alone is not success.

## Scenario 2 — Attribute the blocker without weakening containment

Given controlled probes that independently vary Docker seccomp, `no-new-privileges`, and the existing capability set,
when nested bubblewrap is tested,
then the evidence identifies the blocking control(s) for all three variants and distinguishes them from non-blocking controls and host/runtime restrictions.

No delivered configuration may add privileged mode, host namespace sharing, `SYS_ADMIN`, or an unconfined/broadly relaxed security profile merely to enable bubblewrap.

## Scenario 3 — Select and document the safe behavior

Given the root-cause and `SECURITY.md` threat model,
when enabling nested bubblewrap would materially weaken the outer Docker boundary,
then the shipped least-privilege profiles stay unchanged, Codex's bundled fallback remains available for compatible runtimes, and documentation states that the shipped Docker profiles rely on the outer container boundary.

Documentation names supported and unsupported host/runtime combinations, the exact fallback invocation, and the security trade-off. Debian bubblewrap is not installed merely to suppress the warning.

## Scenario 4 — Prove restrictions with real Codex sandbox commands

Given a running sandbox service,
when the smoke verifier invokes `codex sandbox` with the built-in workspace profile on a namespace-capable runtime,
then an actual command can write inside the workspace, cannot write outside it, and cannot use the network.

When the shipped Docker seccomp blocks nested namespaces,
then the verifier classifies that expected failure explicitly and invokes an actual command through Codex's documented externally-sandboxed fallback profile to prove the outer boundary still permits workspace writes while denying protected filesystem writes, non-allowlisted proxy egress, and direct-IP egress.

The verifier fails closed on unexpected outcomes, missing Codex, missing proxy/firewall behavior, or a nested-sandbox failure other than the documented namespace restriction.

## Scenario 5 — Keep CDD run artifacts out of the delivered tree

Given `.cdd-auto/` contains workflow-only contracts, traces, plans, and demo evidence from prior autonomous runs,
when issue 32 is delivered,
then `.cdd-auto/` is removed from the repository tip and `.gitignore` excludes the directory from future version control.

The current run may use tracked `.cdd-auto/` checkpoints while the autonomous audit is active, as required by the CDD trust boundary; its final state is committed before a final cleanup commit removes the directory, so the merged PR history retains the audit without exposing workflow artifacts in the delivered tree.

## Review rule

If the preferred Claude peer CLI is unavailable, the run may use a probed OpenCode peer backed by a non-OpenAI model for mandatory independent review. The review trace must name the actual model/vendor and may not describe an unrun Claude review as converged.

## Non-goals

- Enabling nested user namespaces by privileged mode, host namespace sharing, `SYS_ADMIN`, or `seccomp=unconfined`.
- Claiming that Docker containers are equivalent to VMs.
- Changing the existing egress allowlist, token model, or host-Docker opt-in boundary.
- Treating `bwrap --version` or disappearance of a warning as functional verification.
