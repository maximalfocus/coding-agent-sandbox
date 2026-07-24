# /cdd-auto run issue-28-20260724-095605

- Started: 2026-07-24T09:56:35Z
- Change type: bug
- Brownfield: no (no existing CDD goldens)
- Branch: cdd-auto/issue-28-20260724-095605
- Contract path + SHA: .cdd-auto/contracts/issue-28.md@b48f34f55260fd381df2e6965a0e8399d1a477d46b3f8fe726b641e4b913f1e2
- Budget: 2h / 200k / 5-iter (N cap: none)
- GitHub issue: https://github.com/maximalfocus/coding-agent-sandbox/issues/28
- Delivery: dedicated issue branch → peer-reviewed PR → merge with closing link → delete local and remote branch

## Acceptance contract (frozen)

Four scenarios require an exact Node-compatible npm upgrade, fixed npm-internal versions for the five reported findings, a green strict CRITICAL Trivy scan, and successful startup of npm plus every bundled coding-agent CLI. Full frozen text: `.cdd-auto/contracts/issue-28.md`.

## Wave log
| Wave | Subagent | Iter | Result | Duration | Checkpoint SHA | Notes |
|---|---|---:|---|---|---|---|
| Contract | host | 0 | frozen | 1m | `83a0cb3` | Derived from issue 28; SHA remained unchanged |
| A | plan | 0 | green | 1m | `db8f497` | Issue-driven remediation and PR delivery plan |
| B | conformance | 0 | red as required | 1m | `4aa93c6` | New verifier failed against npm 10.9.8 |
| C | implementation | 1 | green | 7m | `2def99e` | npm 12 first exposed blocked lifecycle scripts; selected compatible npm 11.18.0 and explicit trusted script allowlists |
| D | acceptance/demo | 0 | green | 4m | `a0df5f5` | Build, CLI smoke, strict CRITICAL scan, named-CVE absence, demo and charter |
| Review fixes | peer review | 2 | green | 20m | `38b4ccf` | Advisory-specific semver, node-user smoke, and fail-closed report checks |

## Budget consumed (running tally — re-seeded on resume, Step 6/8)
- Directed-loop tokens: host runtime did not expose a token counter; 1 directed implementation retry / 5-iteration cap
- Fan-out + review tokens: ~520k reported by three same-vendor fallback verdict calls; Claude peer usage not exposed (recorded only, not capped)
- Wall clock: 34m / 2h
- Iterations: A:0 B:0 C:1 D:0 (per-wave; cap 5 each)
- Review rounds: final-artifact fallback:3, final-artifact cross-vendor:1 (cap 5 each)
- Consecutive-no-progress: 0 / 3

## Peer review
| After wave | Target repo | Verdict | Rounds | Vendor | Notes |
|---|---|---|---:|---|---|
| Final artifact set | coding-agent-sandbox | CONVERGED via fallback | 3 | Codex CLI (same vendor) | Claude executable absent on host; rounds found and fixed four Medium gate defects |
| Final artifact set | coding-agent-sandbox | CONVERGED | 1 | Claude Code 2.1.158 (cross-vendor, authenticated sandbox) | Independent review covered frozen contract, Dockerfile, verifier, demo, runtime user, scanner and Compose context |

## Conformance edits
| Path | Add/Modify | Iter | Justification |
|---|---|---:|---|
| `.cdd-auto/contracts/issue-28.md` | Add | 0 | Frozen regression/acceptance contract derived from issue 28 |
| `scripts/verify-npm-bundle.sh` | Add | 0 | Red gate for vulnerable npm base distribution and CLI startup |
| `scripts/verify-npm-bundle.sh` | Modify | 1 | Select compatible npm 11.18.0 after npm 12 blocked required lifecycle scripts |
| `scripts/verify-npm-bundle.sh` | Modify | 2 | Peer review proved naive floors and root smoke could false-pass; use advisory semver and production user |

## Out-of-scope edits
| Path | Reason |
|---|---|
| None | No edits outside issue 28 remediation, verification, demo, charter, and audit artifacts |

## Flags
| Type | Wave | Detail |
|---|---|---|
| peer-adapter | Review | Host lacked `claude`; authenticated Claude 2.1.158 in the project sandbox supplied the required cross-vendor round |

## Final
- Status: green — cross-vendor converged; approved for PR merge
- Verification: all shell syntax and Compose variants green; npm bundle verifier green as user `node`; strict CRITICAL Trivy green; five issue-28 CVEs absent
- Repos: https://github.com/maximalfocus/coding-agent-sandbox (`cdd-auto/issue-28-20260724-095605`)
