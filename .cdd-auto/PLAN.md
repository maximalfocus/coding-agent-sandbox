# PLAN — GitHub issue 28

Source: `.cdd-auto/contracts/issue-28.md` (frozen)

1. **Conformance first:** add `scripts/verify-npm-bundle.sh`, which fails unless the built image contains npm 12.0.1, every occurrence of the four named npm-internal packages meets the issue's fixed floor, and npm plus all npm-installed CLIs start.
2. **Implementation:** add an exact `NPM_VERSION` build argument immediately before the global CLI installs and upgrade npm as a distribution (`npm install -g npm@…`), never by editing npm's transitive tree.
3. **Acceptance:** rebuild `coding-agent-sandbox:latest`; run the bundle verifier; run the strict CRITICAL Trivy gate; run a HIGH/CRITICAL report and prove all five named CVEs are absent.
4. **Review and delivery:** run the cross-vendor peer probe/review policy, create a PR whose body says `Closes #28`, merge only after green verification, confirm issue 28 closed, and delete both dedicated issue branches.

## Non-goals

- Changing the Node base-image digest.
- Remediating unrelated Debian or third-party CLI findings.
- Changing runtime egress, isolation, or capabilities.
