# Claude Code Sandbox

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
same on **macOS and Windows**.

> This sandboxes the *blast radius on your machine*. It does **not** hide your code from
> Anthropic — file contents you give Claude are still sent to the model. See `SECURITY.md`.

---

## Prerequisites

- **macOS:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) or
  [OrbStack](https://orbstack.dev/). (Apple Silicon works — the image builds for arm64.)
- **Windows:** Docker Desktop with the **WSL2** backend enabled.
- A Claude **Pro or Max** subscription (or Console access).

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
#  …or on Windows (PowerShell):
#  ./run.ps1
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
- Stop: `docker compose down`. Logs: `docker compose logs -f`. Rebuild after edits: `./run.sh`.

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
cd /Users/focus/ws/claude-container-sandbox
docker compose exec -u node -w /workspace claude-sandbox bash -l   # then: claude
# or run Claude Code directly:
docker compose exec -u node -w /workspace claude-sandbox claude
```

Open as many terminals as you like; they all share one container, one egress policy, one login.
(On Windows: `./shell.ps1` / `./shell.ps1 -Attach`.)

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
keeping Anthropic + npm. Anthropic endpoints and the npm registry are always on. Bare TLDs (`com`) and IP literals are rejected, but **public
suffixes are not PSL-checked** — adding `co.uk` or `github.io` would allow *all* their subdomains,
so add specific registrable domains (`yourco.co.uk`), not the suffix.

**No restart needed for a quick add.** Because only the proxy filters (the firewall just lets
the proxy out), you can hot-reload the allowlist on the running container:

```bash
./allow-domain.sh pypi.org files.pythonhosted.org   # immediate, no restart
```

That edit is **temporary** (lost on the next container (re)start). For a **permanent** rule, put
it in `EXTRA_ALLOWED_DOMAINS` in `.env` — then `docker compose up -d` (recreate, ~seconds; a
`--build` is only needed if you changed a Dockerfile). For `claude-safe`, there's no "restart":
each run reads its domains fresh, so just use `CLAUDE_SAFE_DOMAINS=...` for that invocation.

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
- **Host-spoof / domain-fronting resistant** — authorization is keyed on the real routing host
  (`request.host`), not the spoofable `Host` header; CONNECT is gated to allowlisted hosts on port
  443 and raw-TCP passthrough is disabled, so a tunnel can't reach a non-allowlisted destination.
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
