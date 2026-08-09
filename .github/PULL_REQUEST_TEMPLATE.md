## What this changes

Brief description of the change and why.

## Security impact

- [ ] No change to egress, isolation, or capabilities
- [ ] Changes egress/isolation/capabilities — explained below, and kept **opt-in + fail-closed**

<!-- If the box above applies, explain the threat-model reasoning here. -->

## Checklist

- [ ] Shell scripts pass `bash -n`; PowerShell stays Windows PowerShell 5.1-compatible
- [ ] `docker compose config` parses
- [ ] Reviewed the `./scan.sh` (Trivy) report; no new avoidable CVEs introduced
- [ ] macOS/Linux and Windows paths kept at parity (if one was touched)
- [ ] No secrets/tokens/real hostnames committed; docs updated if behavior changed
