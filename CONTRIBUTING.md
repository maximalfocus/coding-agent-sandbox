# Contributing

Thanks for your interest in improving Coding Agent Sandbox. This is a security tool, so changes are
reviewed with the threat model in `SECURITY.md` in mind — please read it before proposing changes
to the proxy, firewall, or entrypoint.

## Ground rules

- **Don't weaken containment by default.** New egress (domains, ports) or new capabilities should
  be opt-in and fail-closed, matching the existing `ALLOW_GITHUB` / `ALLOW_OPENAI` pattern.
- **Pin what you add.** Base images, downloaded binaries, and CLIs are pinned (digest or version)
  so builds are reproducible — keep it that way.
- **Never commit secrets.** `.env` is gitignored; keep real tokens, passwords, and hostnames out of
  the repo and out of examples (`.env.example` holds placeholders only).

## Development

The launchers and helpers are plain shell / PowerShell — there's no build system to learn.

```bash
# macOS / Linux
cp .env.example .env      # set WORKSPACE_DIR + TTYD_PASS
./run.sh                  # builds, scans (Trivy), and starts the sandbox
```

```powershell
# Windows
setup-windows.cmd         # first run: installs prereqs, writes .env, builds + starts
start-sandbox.cmd         # day-to-day
```

Before opening a PR:

- `bash -n` your shell scripts; keep PowerShell to **Windows PowerShell 5.1**-compatible syntax.
- Run `docker compose config` to confirm compose still parses.
- Run `./scan.sh` (Trivy) against the built image — don't introduce fixed HIGH/CRITICAL CVEs.
- Keep macOS/Linux (`run.sh`, `scan.sh`, `*.sh`) and Windows (`run.ps1`, `scan.ps1`, `*.ps1`)
  paths at parity when you touch one.

## Pull requests

Keep PRs focused, explain the security reasoning for any change to egress/isolation, and update
`README.md` / `SECURITY.md` when behavior or guarantees change.
