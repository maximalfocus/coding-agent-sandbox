# Coding Agent Sandbox

*Run AI coding agents (Claude Code + Codex) locked inside a hardened, network-restricted Docker
container — one-command setup on macOS, Linux, and Windows.*

Run the **real Claude Code CLI** — on your **Claude subscription**, with the same terminal
experience you have now — but locked inside a Docker container that can only:

- **see/edit one folder** you choose (everything else on your machine is invisible), and
- **reach the network only where it's allowed**, filtered by **hostname** (Anthropic + npm,
  GitHub when `ALLOW_GITHUB` is on, + domains you add). All egress is forced through an in-container allowlist proxy, and the
  kernel firewall drops any attempt to go around it (direct IPs, DNS, IPv6, private ranges) — so a
  confused or prompt-injected agent **can't beacon to an arbitrary server or quietly phone home**.
  (It can still reach the *allowlisted* hosts, so those remain trust boundaries — see `SECURITY.md`.)

You drive it from a **browser tab** (a web terminal), so "the browser is the sandbox surface":
open `http://127.0.0.1:7681`, and you're in a terminal inside the locked-down box. Works the
same on **macOS, Linux, and Windows**.

> This sandboxes the *blast radius on your machine*. It does **not** hide your code from
> Anthropic — file contents you give Claude are still sent to the model. See `SECURITY.md`.

---

## Prerequisites

- **macOS:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) or
  [OrbStack](https://orbstack.dev/). (Apple Silicon works — the image builds for arm64.) No engine
  yet? `./setup.sh` offers to install Homebrew and OrbStack for you. On the newest Apple Silicon,
  if OrbStack reports "virtualization not available", use [Colima](https://github.com/abiosoft/colima)
  instead (`brew install colima && colima start --vm-type qemu`) — setup.sh accepts any running daemon.
- **Windows:** Docker Desktop with the **WSL2** backend enabled.
- A Claude **Pro or Max** subscription (or Console access).
- **Optional:** [iTerm2](https://iterm2.com/) (recommended over Terminal.app for the 2×2 tmux grid in
  sandbox sessions) — `./setup.sh` offers to install it on macOS.

> **On a managed laptop behind Cloudflare WARP / Zscaler** (TLS inspection)? Read
> [Behind a corporate TLS-inspecting proxy](#behind-a-corporate-tls-inspecting-proxy-cloudflare-warp--zscaler)
> first — the build will fail until you add your root CA to `certs/`.

## Easiest macOS / Linux setup

Make sure Docker is installed and running (Docker Desktop or OrbStack), then run once:

```bash
./setup.sh
```

It does the first-run work for you:

- checks Docker is installed and running (on macOS, offers to install Homebrew if missing, then `brew install --cask orbstack`)
- optionally installs iTerm2 (recommended for the 2×2 tmux grid)
- creates `.env` from `.env.example`
- asks which folder the sandbox may edit (defaults to `~/work`)
- generates a web-terminal password
- builds, scans the image (Trivy), and starts the sandbox
- opens `http://127.0.0.1:7681` (macOS)

After setup, start it again any time with `./run.sh`.

> Setting up by hand, or `setup.sh` isn't an option? See
> **[docs/MANUAL_SETUP.md](docs/MANUAL_SETUP.md)** — a single linear runbook covering
> the Docker-context gotcha, both login paths (interactive and rebuild-proof headless
> token), verification commands, and troubleshooting.

## Easiest Windows setup

On a new Windows machine, copy or extract this folder onto the machine. No Git setup is needed
first.

Run once:

```text
setup-windows.cmd
```

If Windows asks for permission, allow it. If WSL2 asks for a restart, restart and run
`setup-windows.cmd` again. For PowerShell-only environments, this is the equivalent command:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -InstallPrereqs
```

The script does the first-run work for you:

- enables WSL2 if Windows has not done it yet
- installs Git with `winget` if it is missing
- installs Docker Desktop with `winget` if it is missing
- creates `.env` from `.env.example`
- creates `C:\Users\<you>\projects` if missing, or reuses it if it already exists
- asks which folder Claude may edit, defaulting to that `projects` folder
- generates a web-terminal password
- starts Docker Desktop and the sandbox
- opens `http://127.0.0.1:7681`

After setup, everyone starts the sandbox the same way:

```text
start-sandbox.cmd
```

That starts the container and opens the browser terminal. In the browser terminal, run `claude`.
On the first use only, run `/login` inside Claude Code and paste back the browser login code.

## Quick start

```bash
cp .env.example .env          # then edit it (see below)
```

In `.env` set at least:
- `WORKSPACE_DIR` → absolute path to the project you want to code on
- `TTYD_PASS` → a real password for the web terminal

Then:

```bash
./run.sh           # macOS / Linux
#  ...or on Windows:
#  start-sandbox.cmd
```

Open **http://127.0.0.1:7681**, log in with `TTYD_USER` / `TTYD_PASS`, and you're in the
sandbox terminal.

## First-time login (uses your subscription, not an API key)

In the web terminal:

```bash
claude          # starts Claude Code
/login          # choose "Claude account / subscription"
```

A URL appears. Open it in your **normal browser**, approve, and **paste the code back** into
the terminal (the manual paste step is expected — the container can't catch the localhost
redirect). You're now coding on your subscription.

Login is saved to a Docker volume, so it **persists across restarts** — you only do this once.

> Headless alternative: run `claude setup-token` once to mint a long-lived token and set it as
> `CLAUDE_CODE_OAUTH_TOKEN` in `.env` (add it to the `environment:` list in `docker-compose.yml`).

## Day-to-day

- Code exactly as you do now — `claude`, `/`-commands, editing, running tests — all inside
  `/workspace`, which **is** your `WORKSPACE_DIR` on the host. Changes appear on your real files.
- The terminal runs inside `tmux` (session `claude`), so closing the tab doesn't kill your
  session — reopen the URL to reattach.
- Clipboard works in both directions in macOS Chrome (the verified browser): paste from the host
  normally; drag across text in a tmux pane to copy it back through OSC 52. The browser may ask once
  for clipboard permission. Pane applications cannot write the host clipboard directly. On other
  browsers, or for wrapped output, `Ctrl-b y` toggles a zoomed browser-selection fallback.
- Stop: `docker compose down`. Logs: `docker compose logs -f`. Rebuild after edits: `./run.sh`.
- Uninstall: `./uninstall.sh` removes all sandbox containers/images/volumes/network and this repo
  directory, and — only if this sandbox installed it — the Docker engine, leaving your host
  personal/work trees (`PERSONAL_DIR` / `WORK_DIR`) and `~/.docker` login untouched. Pass
  `--remove-docker-engine` to also remove a pre-existing engine, `--keep-docker-engine` to keep it,
  or `--keep-dir` to keep the repo. Reinstall with `git clone … && ./setup.sh`.
  - On **Windows**, use `uninstall.cmd` (same teardown; flags `-Yes`, `-KeepDir`, `-KeepImages`,
    `-KeepDockerEngine`, `-RemoveDockerEngine`, `-SkipDocker`). It removes Docker Desktop only if
    `setup-windows.ps1 -InstallPrereqs` installed it, and **never** unregisters a WSL distro — that
    would also destroy your SSH keys and logins. Reinstall with `git clone … && .\setup-windows.cmd`.

## Workspace: `personal` vs `work` (and keep this repo outside both)

The sandbox mounts **two separate project trees** so you can keep different kinds of work apart in
one session — see the [system-design diagram](docs/architecture/system-design.md):

| Inside the sandbox | Host folder (`.env`) | For |
|---|---|---|
| `/workspace/personal` | `PERSONAL_DIR` (e.g. `C:/Users/you/personal`) | your personal projects — also where `skills-setup` clones skill repos |
| `/workspace/work` | `WORK_DIR` (e.g. `C:/Users/you/work`) | your work / enterprise projects |

These are **live bind mounts**, not copies: whatever the agent edits in `/workspace/personal` **is**
the file in your host `personal/` folder, instantly. So you and the agent share one source of
truth — review changes in **VS Code**, inspect or `git diff` them from a host terminal, or open them
in **Explorer/Finder**. Keeping personal and work as distinct trees means a `work` task never has
your `personal` code in scope (and vice-versa) — set only the tree(s) you need, leave the other
unset.

> **Security: keep `coding-agent-sandbox/` OUTSIDE `personal/` and `work/`.** This repo is the
> sandbox's **control plane** — it holds `.env` (the web-terminal password and any `GITHUB_TOKEN`),
> the egress allowlist (`init-firewall.sh`, `tinyproxy.conf`, `EXTRA_ALLOWED_DOMAINS`), the
> `docker-compose.yml` capability drops, and the trusted CA. The agent can only ever see
> `/workspace`. If the repo lived **inside** a mounted tree, the agent could read those secrets and
> **rewrite its own guard rails** (which then take effect on the next rebuild/restart) — defeating
> the containment. Put the repo somewhere neither `PERSONAL_DIR` nor `WORK_DIR` contains (e.g.
> `C:/Users/you/coding-agent-sandbox`, with projects under `C:/Users/you/personal` and `…/work`).
> `run.sh` / `run.ps1` also refuse to mount `$HOME` or sensitive dirs (`.ssh`, `.aws`, …) for the
> same reason.

## Sharing this sandbox with colleagues

Each install is self-configuring — paths come from `$HOME` / `%USERPROFILE%` / setup prompts, so
there's nothing machine-specific to edit. The cleanest way to share is to have colleagues
**`git clone` this repo** and run setup themselves (`./setup.sh`, `setup-windows.cmd`, or — for WSL
behind a TLS-inspecting proxy — `./setup-wsl.sh`; see [`docs/wsl-warp.md`](docs/wsl-warp.md)).

- **Don't hand over your folder copy / zip.** Your `.env` (mount paths + the web-terminal password),
  `certs/*.crt`, and `.git/config` (your git identity) are local-only and **git-ignored**, so a fresh
  clone never carries them — but a zip of your working tree would. Clone instead, or strip those first.
- **Skill repos are per-user.** `SKILL_REPOS` lives only in each person's `.env`. If your skill repos
  are private, colleagues need their own access (or their own forks) — set their `SKILL_REPOS` to repos
  they can reach, then `./scripts/skills/skills-setup.sh`.

## Use a local terminal instead of the browser

The browser/ttyd is just one entry point — the sandbox is the container. To code from your normal
terminal with the **same isolation** (egress proxy, `/workspace` scope, your login), exec in:

```bash
chmod +x shell.sh                 # first time
./shell.sh                        # a fresh shell in /workspace — then run `claude`
./shell.sh --attach               # share the SAME session the browser tab shows
```

Equivalent raw commands (no wrapper):

```bash
cd /path/to/coding-agent-sandbox
docker compose exec -u node -w /workspace claude-sandbox bash -l   # then: claude
# or run Claude Code directly:
docker compose exec -u node -w /workspace claude-sandbox claude
```

Open as many terminals as you like; they all share one container, one egress policy, one login.
(On Windows: `./shell.ps1` / `./shell.ps1 -Attach`. These work whether Docker is Docker Desktop or
runs inside WSL via [`./setup-wsl.sh`](setup-wsl.sh) — when `docker` isn't on the Windows PATH they
proxy through `wsl -d <distro> -- docker` automatically; set `$env:SANDBOX_WSL_DISTRO` if the daemon
isn't in your default distro.)

### `claude-safe` — run it from anywhere, on the current folder

For the most natural workflow (`cd` into any project and run safe Claude there), add a shell
function. It launches a one-off sandbox that mounts **your current directory** as `/workspace`,
locked to the same hostname allowlist, reusing your saved subscription login. The canonical,
up-to-date copy is installed in your `~/.zshrc` (`claude-safe`); it includes the mount guards,
the session lock, resource limits, `no-new-privileges`, the minimal capability set, and the
audit-volume mount — full parity with the compose path. It runs on a dedicated user-defined Docker
network (`claude-safe-net`, created on first use) so the in-container firewall's "DNS only via
`127.0.0.11`" rule holds — a bare `docker run` on the default bridge can't resolve through the
locked-down proxy. Use it as:

Then, from any project:

```bash
cd ~/code/my-app
claude-safe                  # interactive Claude, sandboxed to ~/code/my-app
claude-safe -p "fix tests"   # args pass straight to claude
claude-safe --shell          # a shell inside the sandbox instead
CLAUDE_SAFE_DOMAINS=pypi.org,mycorp.com claude-safe   # allow extra hosts for this run
CLAUDE_SAFE_GITHUB=false claude-safe                  # drop GitHub egress for untrusted work
CLAUDE_SAFE_RUNTIME=runsc claude-safe                 # gVisor boundary (if installed)
```

Each invocation is its own throwaway container scoped to that folder; they all share one saved
login. It refuses to mount `/`, your home, a dir that contains your home, or known credential
dirs (`~/.ssh`, `~/.aws`, …). It builds on the image from this project, so run `docker compose
build` here once before first use. Sessions are **serialized** (an atomic lock) because they share
one login/config volume — a second `claude-safe` asks you to finish the first; override with
`CLAUDE_SAFE_NOLOCK=1` if you know the writes won't collide.

## Letting Claude reach another site

Add **domains** (not IPs) to `EXTRA_ALLOWED_DOMAINS` in `.env` (comma-separated), then restart.
A parent domain also covers its subdomains — `mycorp.com` allows `docs.mycorp.com`, `api.mycorp.com`, etc.

```bash
EXTRA_ALLOWED_DOMAINS=pypi.org,files.pythonhosted.org,mycorp.com
docker compose up -d --build
```

Anything not on the allowlist is refused by the proxy (`403 Filtered`); anything trying to
skip the proxy is dropped by the firewall. Note: git/npm must use **HTTPS** remotes (SSH
egress on port 22 is not opened).

**GitHub is a deliberate capability, not a default destination.** `github.com` /
`githubusercontent.com` are a general bidirectional channel (pull a payload in, push or gist data
out), so they're governed by their own switch — `ALLOW_GITHUB` (default `true`). For
analysis-only or untrusted-workspace runs, set `ALLOW_GITHUB=false` in `.env` to drop GitHub while
keeping the always-on base hosts. Anthropic, npm, and the bundled Herdr/OpenCode/Pi first-party
hosts (`herdr.dev`, `opencode.ai`, `pi.dev`) are always on. Bare TLDs (`com`) and IP literals are rejected, but **public
suffixes are not PSL-checked** — adding `co.uk` or `github.io` would allow *all* their subdomains,
so add specific registrable domains (`yourco.co.uk`), not the suffix.

**No restart needed for a quick add.** Because only the proxy filters (the firewall just lets
the proxy out), you can hot-reload the allowlist on the running container:

```bash
./scripts/network/allow-domain.sh pypi.org files.pythonhosted.org   # immediate, no restart
```

That edit is **temporary** (lost on the next container (re)start). For a **permanent** rule, put
it in `EXTRA_ALLOWED_DOMAINS` in `.env` — then `docker compose up -d` (recreate, ~seconds; a
`--build` is only needed if you changed a Dockerfile). For `claude-safe`, there's no "restart":
each run reads its domains fresh, so just use `CLAUDE_SAFE_DOMAINS=...` for that invocation.

## GitHub access (clone / pull / push)

SSH (port 22) is firewalled off, so GitHub works over **HTTPS with a token**. Set in `.env`:

```bash
GITHUB_TOKEN=github_pat_...     # a PAT with access to your repos (fine-grained, Contents: read+write is enough)
GIT_USER_NAME=you               # commit identity used inside the sandbox
GIT_USER_EMAIL=you@example.com
```

On each start the sandbox wires git to authenticate with the token and **rewrites
`git@github.com:` / `ssh://git@github.com/` remotes to HTTPS** — so `git clone`, `pull`, and
**`push`** all work, including on repos that already have SSH remotes. Needs `ALLOW_GITHUB=true`
(the default). The token is readable by the agent inside the sandbox (the unavoidable cost of giving
it push) — scope it narrowly to the repos you need, and revoke it if it ever leaks.

## Codex (cross-vendor peer review)

The image also bundles the **Codex CLI** (OpenAI), so you can run a Claude/Codex peer-review loop
inside the same sandbox — Codex is just as contained (workspace-only, egress allowlist, kernel
firewall) as Claude. Two steps to enable it:

1. **Allow OpenAI egress.** It's off by default (another vendor your code can flow to). Set in `.env`:

   ```bash
   ALLOW_OPENAI=true
   ```

2. **Sign in with your ChatGPT/OpenAI subscription** (once — it persists in the `coding-agent-sandbox-codex` volume):

   ```bash
   ./scripts/auth/codex-login.sh
   ```

   This uses Codex's **device-auth** flow (the right one for a container — no `localhost` callback).
   It prints a URL and a short code: open the URL in any browser, enter the code, and sign in with
   your ChatGPT subscription. Codex polls OpenAI through the egress proxy to finish, and the login
   is saved in the persisted `coding-agent-sandbox-codex` volume (one-time).

Then drive Codex from the web terminal like Claude: type `codex`. Same trust caveat as any
allowlisted host — your code is sent to OpenAI for inference once `ALLOW_OPENAI` is on.

## Other bundled coding tools

The image also installs pinned versions of:

- **Herdr** (`herdr`) — agent multiplexer; `herdr.dev` is allowlisted for update metadata/docs.
- **OpenCode** (`opencode`) — coding agent; `opencode.ai` and its subdomains are allowlisted.
- **Pi** (`pi`) — coding-agent harness; `pi.dev` and its subdomains are allowlisted.

Their first-party hosts are trust grants and are always enabled. Model-provider egress is separate:
Anthropic is available by default, OpenAI requires `ALLOW_OPENAI=true`, and any other provider must
be added narrowly to `EXTRA_ALLOWED_DOMAINS`. Rebuild the image to upgrade a bundled CLI; versions
are pinned in `Dockerfile` for reproducibility.

### Pushing repos with GitHub Actions workflows (the `workflow` scope)

A plain `GITHUB_TOKEN` (classic `repo` or fine-grained Contents) pushes everything **except**
`.github/workflows/*` — GitHub rejects workflow-file pushes without the `workflow` scope
(*"refusing to allow … without `workflow` scope"*), and a classic PAT's scopes are **fixed at
creation**, so you can't fix it from inside the sandbox. CDD implementation repos ship a CI
workflow, so this bites the first time you `git push` a new impl repo.

**Permanent fix — log in the bundled GitHub CLI once** (its token carries `workflow`; the login
persists in the `coding-agent-sandbox-gh` volume, and the entrypoint wires git to use it on every
start, preferred over `GITHUB_TOKEN`):

```bash
./scripts/auth/gh-login.sh
```

Device flow, same as `scripts/auth/codex-login.sh`: it prints a URL + one-time code, you approve in any browser
(the consent screen includes **workflow**), and you never hit the workflow-scope wall again. The
entrypoint prints `✅ git authenticated via gh …` on start when the login is present, and warns at
start if a `GITHUB_TOKEN` fallback lacks `workflow`.

### Bringing your own skills / slash-commands into the sandbox

Claude in the sandbox reads skills from `/home/node/.claude/skills` (a persisted volume). **Set
`SKILL_REPOS` in `.env` and the sandbox links them automatically on every start** — no manual step,
and the links are rebuilt each boot so they survive a volume reset:

```bash
# .env:  SKILL_REPOS=https://github.com/you/cdd-skills.git https://github.com/you/peerreview-skills.git
```

On boot the entrypoint runs `sandbox-link-skills`, which symlinks every skill from the listed repos
(already cloned under `/workspace/personal`) into the skills dir, and — when a GitHub credential and
egress are present — clones any repo not yet on disk. There are then two ways to *populate* the
clones, picked by whether you want to *evolve* the skills:

**Clone — recommended for skill repos you develop/evolve (`scripts/skills/skills-setup.sh`).** Clones your skill
repos into the sandbox as live git working copies (then delegates linking to the same
`sandbox-link-skills` helper the entrypoint uses), so the commands work **and** their `*-evolve`
variants can `git commit` + `git push` to GitHub. Run it any time to clone/`git pull` and re-link:

```bash
./scripts/skills/skills-setup.sh          # clone (or git pull) each from SKILL_REPOS, then re-link; re-run to update
```

The clones live in **`/workspace/personal`** inside the sandbox — i.e. your `PERSONAL_DIR` host
folder (`/workspace/personal/cdd-skills`, `/workspace/personal/peerreview-skills`), so they're
visible and editable on the host **and** self-evolve/commit/push works in the sandbox. Identical on
macOS and Windows (`scripts/skills/skills-setup.cmd`). Pushing needs a GitHub credential
(`./scripts/auth/gh-login.sh`, or a `GITHUB_TOKEN` with write access).

> **First-run reminder.** Until the manual bits are done (e.g. a GitHub credential for `*-evolve`),
> the sandbox shows a self-clearing `~/.sandbox-todo` checklist in every terminal; it disappears once
> the conditions are met. Linking is **non-destructive** — it tracks only the symlinks it creates (a
> `.managed-by-sandbox` manifest) and never overwrites copied skills from `sync-skills.sh` or your own
> directories; on a skill-name collision the first repo (sorted) wins and the rest are reported.

**One evolver across environments.** `peerreview` self-evolves + pushes `peerreview-skills` after
*every* run; if more than one environment (this sandbox + your host) does that, the clones race on
git. Pick ONE evolver and set `PEERREVIEW_EVOLVE=off` in `.env` on the others (they log-only, no
push). `cdd-evolve` and the updated `peerreview` also `git pull --rebase` before pushing and
union-merge their append-only `evolution/` logs, so an accidental dual-push self-heals.

**Copy — for read-only use of skills you won't change (`scripts/skills/sync-skills.sh`).** Copies skill *content*
(no `.git`) from your host `~/.claude/skills` + matching `~/.claude/commands/*.md` into the volume:

```bash
./scripts/skills/sync-skills.sh                      # default: cdd* and peerreview/peer-review*
```

Restart `claude` inside the sandbox to pick up newly linked skills (the linking itself is automatic
on each container start). (Skills that call `codex` — like peer-review — need `ALLOW_OPENAI=true` and
a one-time `./scripts/auth/codex-login.sh`.)

### UI acceptance tests & cdd tooling (bundled)

The image bundles **Playwright + Chromium** (pinned, with system libraries) and **bun**, so cdd's
testing and tools work with no extra install:

- `npx playwright test --project=chromium` launches **headless Chromium** for `cdd-acceptance`.
- `/cdd` and `/cdd-evolve`'s `bun run` tools (metrics-baseline, golden-lint, coverage-review, …) run directly.

(If a project pins a *different* Playwright version than the bundled one, it re-downloads its browser
at runtime — add `cdn.playwright.dev` to `EXTRA_ALLOWED_DOMAINS` so that download is allowed.)

### Full cdd / peerreview setup (one-time per machine)

Putting the pieces together for the agentic dev workflow, in order:

1. **Configure `.env`** — `WORKSPACE_DIR`, `TTYD_PASS`, `ALLOW_OPENAI=true`, `GITHUB_TOKEN` (+ `GIT_USER_NAME`/`EMAIL`),
   `SKILL_REPOS=<your cdd-skills + peerreview-skills HTTPS URLs>`, and `PEERREVIEW_EVOLVE=off` on every
   machine that should **not** be the evolver (leave it unset on your one primary evolver).
2. **Start** — `./run.sh` (macOS/Linux) or `start-sandbox.cmd` (Windows).
3. **Log in** — in the web terminal `claude` → `/login`; then `./scripts/auth/codex-login.sh` (Codex device-auth, one-time); and `./scripts/auth/gh-login.sh` if you'll push repos with GitHub Actions workflows (one-time, for the `workflow` scope).
4. **Load skills** — `./scripts/skills/skills-setup.sh` (clones your skill repos into `/workspace/personal`, symlinks them; re-run to update).
5. **Use** — restart `claude`, then `/cdd`, `/cdd-plan`, `/peerreview`, …; `*-evolve` commands commit + push to GitHub.

## Configuration reference (`.env`)

Every knob, with its default. Copy `.env.example` → `.env` and set what you need.

| Variable | Default | What it does |
|---|---|---|
| `WORKSPACE_DIR` | *(inert umbrella volume)* | Optional host folder for the `/workspace` **root**. Leave blank to make `/workspace` an inert umbrella that just holds the `work` + `personal` mount points below. |
| `WORK_DIR` | *(isolated volume)* | Your **work** project tree, mounted at `/workspace/work`. Set an absolute host path (e.g. `/Users/you/work`). _(formerly `PROJECTS_DIR`, still honored.)_ |
| `PERSONAL_DIR` | *(isolated volume)* | Your **personal** project tree, mounted at `/workspace/personal`. This is also where `scripts/skills/skills-setup.sh` clones skill repos and symlinks them into the skills dir. Guarded like `WORK_DIR`. ⚠️ Every mounted tree's code is sent to Anthropic when read — see `SECURITY.md`. _(formerly `WS_DIR`, still honored.)_ |
| `TTYD_USER` / `TTYD_PASS` | `coder` / — | Web-terminal login. Must set a real `TTYD_PASS` (it refuses defaults). |
| `TTYD_PORT` | `7681` | Local port for the browser terminal. |
| `EXTRA_ALLOWED_DOMAINS` | — | Extra egress hostnames, comma-separated (parent domain covers subdomains). |
| `ALLOW_GITHUB` | `true` | github.com / githubusercontent.com egress on/off. |
| `ALLOW_OPENAI` | `false` | OpenAI egress (openai.com + chatgpt.com) — needed for Codex / peer-review. |
| `GITHUB_TOKEN` | — | PAT for git clone/pull/**push** over HTTPS (see *GitHub access*). |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | — | Commit identity used inside the sandbox. |
| `SKILL_REPOS` | — | Space-separated HTTPS skill-repo URLs that `scripts/skills/skills-setup.sh` clones into `/workspace/personal`. |
| `PEERREVIEW_EVOLVE` | *(unset = evolve)* | Set `off` to make peerreview log-only (skip self-evolve/push) — designate **one** evolver. |
| `MEM_LIMIT` / `PIDS_LIMIT` | `6g` / `4096` | Container resource ceilings. |
| `AUDIT_LOG_MAX_BYTES` / `AUDIT_LOG_KEEP` / `AUDIT_ROTATE_INTERVAL` | `20971520` / `5` / `3600` | Egress-log rotation (size, files kept, seconds). |
| `TRIVY_STRICT` / `TRIVY_SEVERITY` / `SKIP_TRIVY` | — / `HIGH,CRITICAL` / — | Image scan: advisory by default; `TRIVY_STRICT=1` blocks on findings, `SKIP_TRIVY=1` skips it. |

Most are runtime env, so a change takes effect on `docker compose up -d` (recreate, seconds) — no
rebuild needed unless you changed a `Dockerfile`. The **mitm** variant adds `GITHUB_READONLY`,
`ANTHROPIC_BLOCK_PATHS`, `ANTHROPIC_SINGLE_CRED`, `ANTHROPIC_PIN_TOKEN` (see below).

## Behind a corporate TLS-inspecting proxy (Cloudflare WARP / Zscaler)

On a managed laptop where **Cloudflare WARP / Zero Trust** (or Zscaler, etc.) inspects TLS, every
HTTPS connection presents the proxy's own root CA. Without trusting it the **image build itself
fails** — the `Dockerfile` runs `npm install` and the ttyd download with *direct* egress, so they
hit `self-signed certificate in chain` before the sandbox ever starts. The same interception hits
`claude`, `codex`, and `git` at runtime.

Fix: get your organisation's **root CA** into [`certs/`](certs/README.md) and rebuild.

**SEED laptops** — zero-touch (downloads + SHA-256-verifies the WARP CA):

```bash
./certs/fetch-warp-ca.sh
./run.sh
```

Other orgs — drop the cert in by hand:

```bash
cp /path/to/your-root-ca.crt certs/        # PEM, filename must end in .crt
./run.sh                                    # or: docker compose build
```

The CA is trusted **before** the build's network steps (system trust store + Node's OpenSSL store
via `--use-openssl-ca`) and persists to runtime. An empty `certs/` is a no-op, so this is safe to
leave in place on non-corporate machines; `*.crt`/`*.pem` there are git-ignored.

- **Where's the cert?** It's the root CA your IT pushed to the OS trust store (Cloudflare's is
  titled *"Gateway CA - Cloudflare Managed G1 …"*). Export it from the OS trust store, or grab it
  from your IT portal.
- **WSL SEED laptop?** The Windows/WSL host also needs prep (WSL2 `metadata` mount so git works on
  `C:`, `systemd` for Docker, IPv4 preference for WARP's dead IPv6) — see
  [`docs/wsl-warp.md`](docs/wsl-warp.md).
- Egress is still hostname-filtered, so the proxy must allow the sandbox's destinations (npm,
  github, anthropic, openai); add anything it blocks via `EXTRA_ALLOWED_DOMAINS`.

## Content-mediation mode (opt-in, mitmproxy)

The default proxy filters by **hostname only** — it can't tell `git clone` from `git push`, or stop
data leaving through an *allowed* host (see `SECURITY.md`). For stronger, content-aware control there's
an opt-in variant that swaps `tinyproxy` for a **TLS-intercepting** proxy (mitmproxy). Because it
terminates TLS it can mediate on request *content*:

- **GitHub read-only** — clone/fetch allowed (incl. the `git-upload-pack` POST), `git push`
  (`git-receive-pack`) and other write methods blocked, closing GitHub's obvious write/exfil paths
  while it stays allowlisted. Toggle with `GITHUB_READONLY` (default `true`).
- **Anthropic API hardening** — on `api.anthropic.com`, upload/exfil endpoints are blocked on the
  normalized path (`ANTHROPIC_BLOCK_PATHS`, default the Files API `/v1/files` — the channel the
  write-up's red team abused), any `x-api-key` is stripped (the subscription path uses an OAuth
  bearer, so an injected key would route data to a different account — `ANTHROPIC_SINGLE_CRED`), and
  you can optionally **pin** the call to one token's sha256 (`ANTHROPIC_PIN_TOKEN`, e.g. a
  `claude setup-token` value).
- **Credential containment** — `Authorization`/`Cookie`/`x-api-key` headers are stripped from any host
  outside the first-party + GitHub set, so a sanctioned extra domain can't harvest tokens.
- **Host-spoof / domain-fronting resistant** — the routing host (`request.host`), the claimed vhost
  (`Host`/`:authority`), AND the TLS SNI must all be allowlisted, so none of header- or SNI-based
  fronting gets through; CONNECT is gated to allowlisted hosts on port 443 and raw-TCP passthrough is
  disabled, so a tunnel can't reach a non-allowlisted destination. (Limitation: WebSocket frames to
  allowlisted hosts other than GitHub — where WS is denied — are tunnelled, not content-inspected.)
- **Request logging** — every decision (`ALLOW`/`DENY`/`STRIP`) is persisted to the audit trail:
  `./audit.sh --mitm` (live), `--mitm --refused` (only blocked/stripped), `--mitm --dump`.

```bash
docker compose build                                   # base image first (once)
docker compose -f docker-compose.mitm.yml up -d --build # start the mediated variant
```

It shares your saved login volume, so log in once and use either stack. It's heavier (pulls Python +
mitmproxy) and intentionally a **prototype** — the rules live in `mitm/filter_addon.py`, meant to be
extended further. The default stack is unchanged; run whichever fits the task. Verified end-to-end: a
real subscription `/login` and `claude -p` inference round-trip both succeed through the intercepting
proxy (Node trusts the generated CA via `--use-openssl-ca`), with every call visible in `audit.sh --mitm`.

## Audit trail & resource limits

Every host the proxy was asked to reach (allowed *and* refused) is logged to a persisted volume:

For the mitm variant, add `--mitm` to read its richer per-request decision log instead
(`./audit.sh --mitm`, `--mitm --refused`, `--mitm --dump`).

```bash
./audit.sh            # follow live
./audit.sh --refused  # only blocked attempts
./audit.sh --dump     # print everything
```

Resource ceilings (so a runaway build can't exhaust your machine) default to `6g` memory and
`4096` pids — tune `MEM_LIMIT` / `PIDS_LIMIT` in `.env`, or `CLAUDE_SAFE_MEM` / `CLAUDE_SAFE_PIDS`
for `claude-safe`.

## Switching projects

Point `WORKSPACE_DIR` at a different path and `docker compose up -d --build`. One sandbox at a
time; for parallel projects, copy this folder and change `container_name` + `TTYD_PORT`.

## Prefer VS Code?

Use VS Code's terminal and run `./shell.sh` (or `claude-safe`) to drop into the sandbox — same
verified firewall/proxy as every other entry point. (A `.devcontainer` is intentionally not
shipped: making "Reopen in Container" run the full proxy+firewall bootstrap couldn't be verified
here, and a half-applied firewall is worse than none.)

## How it works (one diagram)

```
your browser ──http://127.0.0.1:7681 (ttyd, password)──▶ ┌──────────── container ─────────────────┐
                                                          │ tmux → bash → `claude` (as node)       │
your project dir ──bind mount──────────────────────────▶ │ /workspace  (only files it sees)       │
                                                          │ ~/.claude   (subscription token)       │
                                                          │ all egress ─▶ tinyproxy (by hostname): │
                                                          │   allow Anthropic·GitHub·npm·extras    │
                                                          │ firewall: only the proxy may go out;   │
                                                          │   everything else is dropped           │
                                                          └────────────────────────────────────────┘
```

See `SECURITY.md` for the threat model and its limits.

## Repo layout

A one-glance map. Three things live here: the **container build** (the shared core — all the logic
and the security model, running *inside the Linux container, identically on every OS*), the
**entrypoints you type** (in the repo root), and **grouped helper scripts** under `scripts/`. The
macOS/Linux and Windows scripts are **1:1 parallel pairs** (`run.sh` ↔ `run.ps1`) and are meant to
behave the same — change one and you almost always change its twin.

```
coding-agent-sandbox/
│
├─ Container build — the shared core (runs in the container; same on every OS)
│   Dockerfile, Dockerfile.mitm      image build (default + content-mediation variant)
│   docker-compose.yml, *.mitm.yml,  services, named volumes, capabilities, resource limits
│     *.sidecar.yml                  (sidecar.yml = experimental token-isolation variant)
│   entrypoint.sh                    build allowlist → start proxy → install firewall → drop to
│                                    node → launch the ttyd/tmux web terminal (2x2 grid, mouse on)
│   init-firewall.sh                 fail-closed iptables egress rules
│   tinyproxy.conf                   hostname-filtering proxy config
│   tmux-grid.sh                     the in-container 2x2 tmux layout
│   mitm/                            TLS-intercepting proxy addon (opt-in mitm variant)
│   certs/                           extra root CAs (corporate TLS-inspecting proxies)
│
├─ Entrypoints — the commands you actually type (kept in root on purpose)
│   setup.sh / setup-windows.ps1·.cmd / setup-wsl.sh   first run: .env → build → scan → start
│   run.sh   · run.ps1                                 build → scan → start
│   shell.sh · shell.ps1                               exec a shell / attach the tmux session
│   scan.sh  · scan.ps1                                Trivy image scan (TRIVY_STRICT=1 to gate)
│   audit.sh                                           read the egress audit trail
│   uninstall.sh · uninstall.cmd · uninstall-windows.ps1   remove containers/volumes/images
│   start-sandbox.cmd                                  Windows: start (calls run.ps1)
│
├─ scripts/                  grouped helpers (each is a thin `docker compose exec` wrapper)
│   ├─ auth/                 sign-ins
│   │    gh-login.*          GitHub CLI device sign-in (workflow-scope token for pushing workflows)
│   │    codex-login.*       Codex device-auth sign-in
│   │    claim-token.*       move the Anthropic OAuth token into the tinyproxy vault (mitm/sidecar)
│   ├─ network/              egress allowlist management
│   │    allow-domain.*      hot-add host(s) to the running allowlist
│   │    watch-egress.*      alert on / auto-assess refused hosts (--auto, --llm, --wait)
│   │    install-egress-watcher.sh  macOS LaunchAgent: keep watch-egress running (autostart)
│   └─ skills/               bring your skills into the sandbox
│        skills-setup.*      clone your skill repos into /workspace/personal (live, evolvable)
│        sync-skills.sh      copy host skills in (read-only use)
│
└─ Config & docs
    .env.example      every knob, with defaults (copy to .env)
    .gitattributes    forces LF on container scripts so a Windows `git clone` can't break the build
    README.md · SECURITY.md · CONTRIBUTING.md · docs/  (docs/architecture/ = diagrams)
```

`.*` = the cross-platform set (`.sh` for macOS/Linux, `.ps1`/`.cmd` for Windows). Helpers run from
the repo root — e.g. `./scripts/network/allow-domain.sh pypi.org` — and self-locate, so they work
regardless of where you invoke them.

Rule of thumb: **logic belongs in the container build / shared core; a launcher only translates a
`docker compose` invocation for its OS.** This is why the project isn't split into separate
Windows/macOS trees — keeping the pairs side by side is what keeps them from drifting.

## Contributing

Issues and pull requests are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). To report a
security issue privately, see the policy in [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) © maximalfocus. This project runs third-party tools (Claude Code, Codex,
mitmproxy, tinyproxy, ttyd, and others) that are licensed separately by their respective authors.
