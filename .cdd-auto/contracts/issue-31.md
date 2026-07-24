# Issue 31 acceptance contract — Maven sample-credential layer cleanup

Source of truth: https://github.com/maximalfocus/coding-agent-sandbox/issues/31

## Reproduction

Build the current Dockerfile and run Trivy's secret scanner against `coding-agent-sandbox:latest`. The scan reports three HIGH Maven sample-credential findings attributed to the apt-install layer that provides `/etc/maven/settings.xml`: one sample passphrase and two sample passwords. The final filesystem is not affected because the later project-owned `COPY maven-settings.xml` replaces that file.

## Scenario 1 — package example credentials never enter a committed image layer

**Given** the Dockerfile layer that installs the Debian `maven` package
**When** that `RUN` instruction completes
**Then** `/etc/maven/settings.xml` supplied by the package has been deleted in that same `RUN` instruction before the layer is committed.

## Scenario 2 — Maven secret findings are absent

**Given** a successful Trivy secret scan of the freshly rebuilt `coding-agent-sandbox:latest` image
**When** findings targeting Maven settings are inspected
**Then** no password or passphrase finding exists for `/etc/maven/settings.xml`
**And** missing, empty, malformed, failed, or non-container scan evidence cannot pass as absence.

## Scenario 3 — final Maven settings remain project-owned

**Given** the freshly rebuilt image
**When** `/etc/maven/settings.xml` is inspected in the final filesystem
**Then** it is byte-identical to the repository's `maven-settings.xml`
**And** it contains the sandbox proxy configuration
**And** it contains no password or passphrase elements.

## Scenario 4 — Maven proxy resolution still works

**Given** a running sandbox created from the rebuilt image with the standard proxy/firewall configuration
**When** Maven resolves a dependency as the unprivileged `node` user through the sandbox proxy
**Then** resolution succeeds
**And** the proxy remains the configured Maven path.

## Scenario 5 — suppression remains narrow by being absent

**Given** the remediation
**When** repository scanner configuration and invocation are inspected
**Then** no broad secret-scanner suppression or ignore rule is added.

## Scope

Delete the package-provided Maven settings file in the existing apt-install `RUN` instruction, add deterministic fail-closed regression verification, and refresh the acceptance demo/charter. Changes to Maven versions, proxy policy, firewall behavior, credentials, or unrelated scanner findings are non-goals.
